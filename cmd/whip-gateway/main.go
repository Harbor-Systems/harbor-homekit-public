package main

import (
	"context"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

const maxSDPBytes = 1 << 20

type gateway struct {
	token      string
	streams    map[string]struct{}
	sourceIP   net.IP
	upstream   *url.URL
	statusFile string
	httpClient *http.Client
	onPublish  func(string)
	preload    func(string)
	preloadMu  sync.Mutex
	preloading map[string]bool
}

// main validates configuration and serves the restricted WHIP endpoint.
func main() {
	cfg, err := configFromEnvironment()
	if err != nil {
		log.Fatal(err)
	}

	handler := &gateway{
		token:      cfg.token,
		streams:    cfg.streams,
		sourceIP:   cfg.sourceIP,
		upstream:   cfg.upstream,
		statusFile: cfg.statusFile,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
	handler.preload = handler.preloadH264
	handler.onPublish = handler.startPreload
	server := &http.Server{
		Addr:              cfg.listen,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	log.Printf("Harbor WHIP gateway listening on %s for %d configured stream(s)", cfg.listen, len(cfg.streams))
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// config contains the gateway's validated runtime settings.
type config struct {
	listen     string
	token      string
	streams    map[string]struct{}
	sourceIP   net.IP
	upstream   *url.URL
	statusFile string
}

// configFromEnvironment loads secrets and network settings without logging them.
func configFromEnvironment() (*config, error) {
	tokenFile := os.Getenv("HARBOR_WHIP_TOKEN_FILE")
	if tokenFile == "" {
		return nil, errors.New("HARBOR_WHIP_TOKEN_FILE is required")
	}
	tokenBytes, err := os.ReadFile(tokenFile)
	if err != nil {
		return nil, fmt.Errorf("read WHIP token: %w", err)
	}
	token := strings.TrimSpace(string(tokenBytes))
	if err := validateToken(token); err != nil {
		return nil, err
	}

	streamsText := os.Getenv("HARBOR_WHIP_STREAMS")
	if streamsText == "" {
		streamsText = os.Getenv("HARBOR_WHIP_STREAM")
	}
	streams := make(map[string]struct{})
	for _, stream := range strings.Split(streamsText, ",") {
		stream = strings.TrimSpace(stream)
		if stream != "" {
			streams[stream] = struct{}{}
		}
	}
	if len(streams) == 0 {
		return nil, errors.New("HARBOR_WHIP_STREAMS is required")
	}

	upstreamText := os.Getenv("HARBOR_GO2RTC_URL")
	if upstreamText == "" {
		upstreamText = "http://127.0.0.1:1985"
	}
	upstream, err := url.Parse(upstreamText)
	if err != nil || upstream.Scheme != "http" || upstream.Hostname() != "127.0.0.1" {
		return nil, errors.New("HARBOR_GO2RTC_URL must be an http://127.0.0.1 address")
	}

	var sourceIP net.IP
	if sourceText := os.Getenv("HARBOR_WHIP_SOURCE_IP"); sourceText != "" {
		sourceIP = net.ParseIP(sourceText)
		if sourceIP == nil {
			return nil, errors.New("HARBOR_WHIP_SOURCE_IP must be a valid IP address")
		}
	}

	listen := os.Getenv("HARBOR_WHIP_LISTEN")
	if listen == "" {
		listen = ":1984"
	}
	return &config{
		listen: listen, token: token, streams: streams,
		sourceIP: sourceIP, upstream: upstream,
		statusFile: os.Getenv("HARBOR_WHIP_STATUS_FILE"),
	}, nil
}

// validateToken enforces the generator's canonical 256-bit hexadecimal format.
func validateToken(token string) error {
	if len(token) != 64 {
		return errors.New("WHIP token must be 64 hexadecimal characters")
	}
	decoded, err := hex.DecodeString(token)
	if err != nil || len(decoded) != 32 {
		return errors.New("WHIP token must encode exactly 32 bytes")
	}
	return nil
}

// ServeHTTP rejects every request outside the authenticated WHIP surface.
func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")

	if r.URL.Path != "/api/webrtc" {
		http.NotFound(w, r)
		return
	}
	if g.sourceIP != nil && !g.sourceAllowed(r.RemoteAddr) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if !g.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	switch r.Method {
	case http.MethodPost:
		g.handlePublish(w, r)
	case http.MethodDelete:
		g.handleDelete(w, r)
	default:
		w.Header().Set("Allow", "POST, DELETE")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// authorized compares a query or Bearer credential in constant time.
func (g *gateway) authorized(r *http.Request) bool {
	provided := r.URL.Query().Get("token")
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
		provided = strings.TrimPrefix(auth, "Bearer ")
	}
	return len(provided) == len(g.token) &&
		subtle.ConstantTimeCompare([]byte(provided), []byte(g.token)) == 1
}

// sourceAllowed optionally restricts publishing to one configured IP address.
func (g *gateway) sourceAllowed(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return false
	}
	return g.sourceIP.Equal(net.ParseIP(host))
}

// handlePublish validates a publish request before forwarding its SDP.
func (g *gateway) handlePublish(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	stream := query.Get("dst")
	if _, allowed := g.streams[stream]; !allowed || hasUnexpectedQuery(query, "dst", "token") {
		http.Error(w, "invalid destination", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxSDPBytes)
	g.proxy(w, r, url.Values{"dst": []string{stream}}, stream)
}

// handleDelete validates cleanup for an established WHIP session.
func (g *gateway) handleDelete(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	id := query.Get("id")
	if id == "" || strings.ContainsAny(id, "/\\") || hasUnexpectedQuery(query, "id", "token") {
		http.Error(w, "invalid session", http.StatusBadRequest)
		return
	}
	g.proxy(w, r, url.Values{"id": []string{id}}, "")
}

// hasUnexpectedQuery rejects duplicated and non-allowlisted query parameters.
func hasUnexpectedQuery(values url.Values, allowed ...string) bool {
	set := make(map[string]bool, len(allowed))
	for _, key := range allowed {
		set[key] = true
	}
	for key, entries := range values {
		if !set[key] || len(entries) != 1 {
			return true
		}
	}
	return false
}

// proxy forwards only the sanitized request and rewrites session locations.
func (g *gateway) proxy(w http.ResponseWriter, incoming *http.Request, query url.Values, stream string) {
	target := *g.upstream
	target.Path = "/api/webrtc"
	target.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(
		incoming.Context(), incoming.Method, target.String(), incoming.Body,
	)
	if err != nil {
		http.Error(w, "gateway error", http.StatusBadGateway)
		return
	}
	request.Header.Set("Content-Type", incoming.Header.Get("Content-Type"))
	request.Header.Set("User-Agent", incoming.UserAgent())

	response, err := g.httpClient.Do(request)
	if err != nil {
		log.Printf("WHIP upstream request failed: %v", err)
		http.Error(w, "upstream unavailable", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()

	for _, header := range []string{"Content-Type", "Accept-Patch", "Link"} {
		if value := response.Header.Get(header); value != "" {
			w.Header().Set(header, value)
		}
	}
	if location := response.Header.Get("Location"); location != "" {
		locationURL, err := url.Parse(location)
		if err != nil || locationURL == nil {
			http.Error(w, "invalid upstream session", http.StatusBadGateway)
			return
		}
		id := locationURL.Query().Get("id")
		if id == "" || strings.ContainsAny(id, "/\\") {
			http.Error(w, "invalid upstream session", http.StatusBadGateway)
			return
		}
		w.Header().Set("Location", "/api/webrtc?id="+url.QueryEscape(id)+"&token="+url.QueryEscape(g.token))
	}

	w.WriteHeader(response.StatusCode)
	if incoming.Method == http.MethodPost && response.StatusCode >= 200 && response.StatusCode < 300 && g.statusFile != "" {
		statusFile := g.statusFile + "." + stream
		if err := os.WriteFile(statusFile, []byte(time.Now().UTC().Format(time.RFC3339)+"\n"), 0o600); err != nil {
			log.Printf("WHIP status update failed: %v", err)
		}
	}
	if incoming.Method == http.MethodPost && response.StatusCode >= 200 && response.StatusCode < 300 && g.onPublish != nil {
		go g.onPublish(stream)
	}
	if _, err := io.Copy(w, io.LimitReader(response.Body, maxSDPBytes)); err != nil {
		log.Printf("WHIP response copy failed: %v", err)
	}
}

// preloadH264 keeps the HomeKit-compatible transcoder warm after the camera
// completes WHIP publishing. A cold decoder's first frame can be gray, while a
// warm producer supplies each Apple snapshot request with a fresh keyframe.
func (g *gateway) preloadH264(stream string) {
	for attempt := 0; attempt < 15; attempt++ {
		target := *g.upstream
		target.Path = "/api/preload"
		query := url.Values{"src": []string{stream}, "video": []string{"h264"}}
		target.RawQuery = query.Encode()

		request, err := http.NewRequestWithContext(context.Background(), http.MethodPut, target.String(), nil)
		if err == nil {
			response, requestErr := g.httpClient.Do(request)
			if requestErr == nil {
				_, _ = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
				if response.StatusCode >= 200 && response.StatusCode < 300 {
					return
				}
			}
		}
		time.Sleep(time.Second)
	}
	log.Printf("HomeKit H264 preview pipeline could not be preloaded")
}

// startPreload bounds warmup work to one retry loop per configured stream.
func (g *gateway) startPreload(stream string) {
	g.preloadMu.Lock()
	if g.preloading == nil {
		g.preloading = make(map[string]bool)
	}
	if g.preloading[stream] {
		g.preloadMu.Unlock()
		return
	}
	g.preloading[stream] = true
	g.preloadMu.Unlock()

	go func() {
		defer func() {
			g.preloadMu.Lock()
			delete(g.preloading, stream)
			g.preloadMu.Unlock()
		}()
		if g.preload != nil {
			g.preload(stream)
		}
	}()
}
