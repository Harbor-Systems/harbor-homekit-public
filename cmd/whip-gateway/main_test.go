package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func testGateway(t *testing.T, upstream http.Handler) (*gateway, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(upstream)
	target, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	return &gateway{
		token: testToken, stream: "CAM123", upstream: target,
		httpClient: server.Client(),
	}, server
}

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
