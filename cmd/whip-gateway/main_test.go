package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// testGateway creates an isolated gateway and fake loopback upstream.
func testGateway(t *testing.T, upstream http.Handler) (*gateway, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(upstream)
	target, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	return &gateway{
		token: testToken, streams: map[string]struct{}{"CAM123": {}, "CAM456": {}}, upstream: target,
		httpClient: server.Client(),
	}, server
}

// TestSuccessfulPublishWritesPrivateStatusMarker gives the setup UI a local,
// non-network signal that the Harbor camera completed a WHIP handshake.
func TestSuccessfulPublishWritesPrivateStatusMarker(t *testing.T) {
	upstream := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
	})
	gateway, server := testGateway(t, upstream)
	defer server.Close()
	gateway.statusFile = t.TempDir() + "/connected"

	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, httptest.NewRequest(
		http.MethodPost, "/api/webrtc?dst=CAM123&token="+testToken,
		strings.NewReader("offer"),
	))
	info, err := os.Stat(gateway.statusFile + ".CAM123")
	if err != nil {
		t.Fatalf("status marker was not written: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("status marker permissions = %o, want 600", info.Mode().Perm())
	}
}

func TestPreloadH264UsesLoopbackAPI(t *testing.T) {
	called := false
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		if r.Method != http.MethodPut || r.URL.Path != "/api/preload" ||
			r.URL.Query().Get("src") != "CAM123" || r.URL.Query().Get("video") != "h264" {
			t.Fatalf("unexpected preload request: %s %s", r.Method, r.URL.String())
		}
		w.WriteHeader(http.StatusOK)
	})
	gateway, server := testGateway(t, upstream)
	defer server.Close()

	gateway.preloadH264("CAM123")
	if !called {
		t.Fatal("preload endpoint was not called")
	}
}

func TestStartPreloadDeduplicatesConcurrentWorkPerStream(t *testing.T) {
	gateway, server := testGateway(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer server.Close()

	var calls atomic.Int32
	started := make(chan struct{}, 2)
	release := make(chan struct{})
	gateway.preload = func(string) {
		calls.Add(1)
		started <- struct{}{}
		<-release
	}

	gateway.startPreload("CAM123")
	gateway.startPreload("CAM123")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("preload did not start")
	}
	time.Sleep(20 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("concurrent preload calls = %d, want 1", got)
	}

	close(release)
	deadline := time.Now().Add(time.Second)
	for {
		gateway.preloadMu.Lock()
		active := gateway.preloading["CAM123"]
		gateway.preloadMu.Unlock()
		if !active {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("completed preload remained active")
		}
		time.Sleep(time.Millisecond)
	}
}

// TestPublishForwardsOnlyExpectedRequest verifies sanitized WHIP forwarding.
func TestPublishForwardsOnlyExpectedRequest(t *testing.T) {
	var gotMethod, gotQuery, gotBody string
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotQuery = r.Method, r.URL.RawQuery
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)
		w.Header().Set("Content-Type", "application/sdp")
		w.Header().Set("Location", "webrtc?id=session-1")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte("answer"))
	})
	gateway, server := testGateway(t, upstream)
	defer server.Close()

	request := httptest.NewRequest(
		http.MethodPost,
		"/api/webrtc?dst=CAM123&token="+testToken,
		strings.NewReader("offer"),
	)
	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, request)

	if response.Code != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if gotMethod != http.MethodPost || gotQuery != "dst=CAM123" || gotBody != "offer" {
		t.Fatalf("unexpected upstream request: method=%q query=%q body=%q", gotMethod, gotQuery, gotBody)
	}
	wantLocation := "/api/webrtc?id=session-1&token=" + testToken
	if got := response.Header().Get("Location"); got != wantLocation {
		t.Fatalf("Location = %q, want %q", got, wantLocation)
	}
}

// TestRejectsUnauthenticatedAndExcessSurface verifies the default-deny boundary.
func TestRejectsUnauthenticatedAndExcessSurface(t *testing.T) {
	gateway, server := testGateway(t, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("rejected request reached upstream")
	}))
	defer server.Close()

	tests := []struct {
		name   string
		method string
		target string
		status int
	}{
		{"missing token", http.MethodPost, "/api/webrtc?dst=CAM123", http.StatusUnauthorized},
		{"wrong token", http.MethodPost, "/api/webrtc?dst=CAM123&token=wrong", http.StatusUnauthorized},
		{"wrong stream", http.MethodPost, "/api/webrtc?dst=OTHER&token=" + testToken, http.StatusForbidden},
		{"extra query", http.MethodPost, "/api/webrtc?dst=CAM123&src=x&token=" + testToken, http.StatusForbidden},
		{"dashboard", http.MethodGet, "/?token=" + testToken, http.StatusNotFound},
		{"stream list", http.MethodGet, "/api/streams?token=" + testToken, http.StatusNotFound},
		{"read method", http.MethodGet, "/api/webrtc?dst=CAM123&token=" + testToken, http.StatusMethodNotAllowed},
		{"patch method", http.MethodPatch, "/api/webrtc?dst=CAM123&token=" + testToken, http.StatusMethodNotAllowed},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			gateway.ServeHTTP(response, httptest.NewRequest(test.method, test.target, nil))
			if response.Code != test.status {
				t.Fatalf("status = %d, want %d", response.Code, test.status)
			}
		})
	}
}

func TestAllowsEveryConfiguredStream(t *testing.T) {
	gateway, server := testGateway(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("dst") != "CAM456" {
			t.Fatalf("unexpected destination: %s", r.URL.RawQuery)
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer server.Close()

	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, httptest.NewRequest(
		http.MethodPost, "/api/webrtc?dst=CAM456&token="+testToken,
		strings.NewReader("offer"),
	))
	if response.Code != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
}

// TestDeleteUsesAuthenticatedSession verifies safe session cleanup forwarding.
func TestDeleteUsesAuthenticatedSession(t *testing.T) {
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete || r.URL.RawQuery != "id=session-1" {
			t.Fatalf("unexpected upstream delete: %s %s", r.Method, r.URL.String())
		}
		w.WriteHeader(http.StatusNoContent)
	})
	gateway, server := testGateway(t, upstream)
	defer server.Close()

	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, httptest.NewRequest(
		http.MethodDelete, "/api/webrtc?id=session-1&token="+testToken, nil,
	))
	if response.Code != http.StatusNoContent {
		t.Fatalf("status = %d", response.Code)
	}
}

// TestTokenFormat rejects credentials outside the generated canonical format.
func TestTokenFormat(t *testing.T) {
	tests := []struct {
		name  string
		token string
		valid bool
	}{
		{"generated format", testToken, true},
		{"predictable short text", strings.Repeat("a", 32), false},
		{"non hexadecimal", strings.Repeat("g", 64), false},
		{"too long", testToken + "00", false},
		{"empty", "", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if valid := validateToken(test.token) == nil; valid != test.valid {
				t.Fatalf("valid = %t, want %t", valid, test.valid)
			}
		})
	}
}
