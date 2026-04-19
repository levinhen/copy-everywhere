package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/copy-everywhere/server/config"
	"github.com/copy-everywhere/server/db"
	"github.com/gin-gonic/gin"
)

func TestHealthHandlerIncludesServerID(t *testing.T) {
	storagePath := t.TempDir()
	database, err := db.Open(storagePath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })

	cfg := &config.Config{AuthEnabled: true}
	serverID := "test-server-id"

	r := gin.New()
	r.GET("/health", healthHandler(cfg, database, serverID))
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}

	if got, ok := resp["server_id"].(string); !ok || got != serverID {
		t.Fatalf("expected server_id %q, got %#v", serverID, resp["server_id"])
	}
	if got, ok := resp["auth"].(bool); !ok || !got {
		t.Fatalf("expected auth=true, got %#v", resp["auth"])
	}
}
