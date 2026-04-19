package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadOrCreateServerIDPersistsValue(t *testing.T) {
	storagePath := t.TempDir()

	firstID, err := LoadOrCreateServerID(storagePath)
	if err != nil {
		t.Fatalf("first LoadOrCreateServerID() error: %v", err)
	}
	if firstID == "" {
		t.Fatal("expected non-empty server_id")
	}

	secondID, err := LoadOrCreateServerID(storagePath)
	if err != nil {
		t.Fatalf("second LoadOrCreateServerID() error: %v", err)
	}
	if secondID != firstID {
		t.Fatalf("expected persisted server_id %q, got %q", firstID, secondID)
	}
}

func TestLoadOrCreateServerIDUsesExistingFile(t *testing.T) {
	storagePath := t.TempDir()
	serverIDPath := filepath.Join(storagePath, "server_id")
	expected := "existing-server-id"

	if err := os.WriteFile(serverIDPath, []byte(expected+"\n"), 0644); err != nil {
		t.Fatalf("write server_id: %v", err)
	}

	got, err := LoadOrCreateServerID(storagePath)
	if err != nil {
		t.Fatalf("LoadOrCreateServerID() error: %v", err)
	}
	if got != expected {
		t.Fatalf("expected existing server_id %q, got %q", expected, got)
	}
}
