package cleanup

import (
	"testing"
	"time"

	"github.com/copy-everywhere/server/db"
)

func setupTestDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { database.Close() })
	return database
}

func TestRunFallsBackStaleTargetedClips(t *testing.T) {
	database := setupTestDB(t)
	now := time.Now().UTC()
	target := "dev_a"
	stalePendingAt := now.Add(-2 * time.Minute)
	freshPendingAt := now.Add(-10 * time.Second)

	if err := database.CreateClip(&db.Clip{
		ID:                "fbclp1",
		Type:              "text",
		SizeBytes:         5,
		Status:            db.ClipStatusTargetedPending,
		CreatedAt:         now.Add(-3 * time.Minute),
		ExpiresAt:         now.Add(time.Hour),
		TargetDeviceID:    &target,
		TargetedPendingAt: &stalePendingAt,
	}); err != nil {
		t.Fatalf("create stale targeted clip: %v", err)
	}

	if err := database.CreateClip(&db.Clip{
		ID:                "fbclp2",
		Type:              "text",
		SizeBytes:         5,
		Status:            db.ClipStatusTargetedPending,
		CreatedAt:         now.Add(-30 * time.Second),
		ExpiresAt:         now.Add(time.Hour),
		TargetDeviceID:    &target,
		TargetedPendingAt: &freshPendingAt,
	}); err != nil {
		t.Fatalf("create fresh targeted clip: %v", err)
	}

	run(database, t.TempDir(), 30*time.Second)

	stale, err := database.GetClipByID("fbclp1")
	if err != nil {
		t.Fatalf("get stale targeted clip: %v", err)
	}
	if stale.Status != db.ClipStatusTargetedFallback {
		t.Fatalf("expected stale clip status %q, got %q", db.ClipStatusTargetedFallback, stale.Status)
	}

	fresh, err := database.GetClipByID("fbclp2")
	if err != nil {
		t.Fatalf("get fresh targeted clip: %v", err)
	}
	if fresh.Status != db.ClipStatusTargetedPending {
		t.Fatalf("expected fresh clip status %q, got %q", db.ClipStatusTargetedPending, fresh.Status)
	}
}
