package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRootEndpoint(t *testing.T) {
	handler := NewHandler("1.0.0")

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, rec.Code)
	}

	expected := "Hello, DevOps! version=1.0.0"

	if !strings.Contains(rec.Body.String(), expected) {
		t.Fatalf(
			"expected response to contain %q, got %q",
			expected,
			rec.Body.String(),
		)
	}
}

func TestHealthEndpoint(t *testing.T) {
	handler := NewHandler("abc123")

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, rec.Code)
	}

	expected := `"status":"ok"`

	if !strings.Contains(rec.Body.String(), expected) {
		t.Fatalf(
			"expected response to contain %q, got %q",
			expected,
			rec.Body.String(),
		)
	}

	expectedVersion := `"version":"abc123"`

	if !strings.Contains(rec.Body.String(), expectedVersion) {
		t.Fatalf(
			"expected response to contain %q, got %q",
			expectedVersion,
			rec.Body.String(),
		)
	}
}
