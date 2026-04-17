package db

import (
	"fmt"
	"os"
	"testing"
	"time"
)

func setupTestDB(t *testing.T) *DB {
	t.Helper()
	dir := t.TempDir()
	d, err := Open(dir)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func TestGenerateID(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 1000; i++ {
		id, err := GenerateID()
		if err != nil {
			t.Fatalf("generate id: %v", err)
		}
		if len(id) != 6 {
			t.Fatalf("expected 6 chars, got %d: %s", len(id), id)
		}
		for _, c := range id {
			if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
				t.Fatalf("invalid char %c in id %s", c, id)
			}
		}
		if seen[id] {
			t.Fatalf("duplicate id: %s", id)
		}
		seen[id] = true
	}
}

func TestCreateAndGetClip(t *testing.T) {
	d := setupTestDB(t)

	filename := "test.txt"
	clip := &Clip{
		Type:        "text",
		Filename:    &filename,
		SizeBytes:   42,
		Status:      "ready",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/test",
	}

	if err := d.CreateClip(clip); err != nil {
		t.Fatalf("create clip: %v", err)
	}

	if clip.ID == "" {
		t.Fatal("expected ID to be set")
	}
	if len(clip.ID) != 6 {
		t.Fatalf("expected 6-char ID, got %d", len(clip.ID))
	}

	got, err := d.GetClipByID(clip.ID)
	if err != nil {
		t.Fatalf("get clip: %v", err)
	}
	if got == nil {
		t.Fatal("expected clip, got nil")
	}
	if got.Type != "text" {
		t.Fatalf("expected type text, got %s", got.Type)
	}
	if got.Filename == nil || *got.Filename != "test.txt" {
		t.Fatalf("expected filename test.txt, got %v", got.Filename)
	}
	if got.SizeBytes != 42 {
		t.Fatalf("expected 42 bytes, got %d", got.SizeBytes)
	}
}

func TestGetClipByID_NotFound(t *testing.T) {
	d := setupTestDB(t)

	got, err := d.GetClipByID("nope00")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Fatal("expected nil for non-existent clip")
	}
}

func TestGetLatestClip(t *testing.T) {
	d := setupTestDB(t)

	// No clips yet
	got, err := d.GetLatestClip()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Fatal("expected nil when no clips")
	}

	// Create an expired clip
	expired := &Clip{
		Type:        "text",
		SizeBytes:   10,
		Status:      "ready",
		CreatedAt:   time.Now().UTC().Add(-2 * time.Hour),
		ExpiresAt:   time.Now().UTC().Add(-1 * time.Hour),
		StoragePath: "/tmp/old",
	}
	if err := d.CreateClip(expired); err != nil {
		t.Fatalf("create expired clip: %v", err)
	}

	// Should still be nil (expired)
	got, err = d.GetLatestClip()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Fatal("expected nil for expired clip")
	}

	// Create a valid clip
	valid := &Clip{
		Type:        "file",
		SizeBytes:   100,
		Status:      "ready",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/new",
	}
	if err := d.CreateClip(valid); err != nil {
		t.Fatalf("create valid clip: %v", err)
	}

	got, err = d.GetLatestClip()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil {
		t.Fatal("expected latest clip")
	}
	if got.ID != valid.ID {
		t.Fatalf("expected ID %s, got %s", valid.ID, got.ID)
	}
}

func TestGetLatestClip_SkipsUploading(t *testing.T) {
	d := setupTestDB(t)

	uploading := &Clip{
		Type:        "file",
		SizeBytes:   100,
		Status:      "uploading",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/uploading",
	}
	if err := d.CreateClip(uploading); err != nil {
		t.Fatalf("create clip: %v", err)
	}

	got, err := d.GetLatestClip()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Fatal("expected nil for uploading clip")
	}
}

func TestListClips(t *testing.T) {
	d := setupTestDB(t)

	for i := 0; i < 3; i++ {
		clip := &Clip{
			Type:        "text",
			SizeBytes:   int64(i * 10),
			Status:      "ready",
			ExpiresAt:   time.Now().UTC().Add(time.Hour),
			StoragePath: "/tmp/list",
		}
		if err := d.CreateClip(clip); err != nil {
			t.Fatalf("create clip %d: %v", i, err)
		}
	}

	clips, err := d.ListClips()
	if err != nil {
		t.Fatalf("list clips: %v", err)
	}
	if len(clips) != 3 {
		t.Fatalf("expected 3 clips, got %d", len(clips))
	}
}

func TestDeleteClip(t *testing.T) {
	d := setupTestDB(t)

	clip := &Clip{
		Type:        "text",
		SizeBytes:   10,
		Status:      "ready",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/del",
	}
	if err := d.CreateClip(clip); err != nil {
		t.Fatalf("create clip: %v", err)
	}

	if err := d.DeleteClip(clip.ID); err != nil {
		t.Fatalf("delete clip: %v", err)
	}

	got, err := d.GetClipByID(clip.ID)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != nil {
		t.Fatal("expected nil after delete")
	}
}

func TestCreateClipNullFilename(t *testing.T) {
	d := setupTestDB(t)

	clip := &Clip{
		Type:        "text",
		SizeBytes:   10,
		Status:      "ready",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/null",
	}
	if err := d.CreateClip(clip); err != nil {
		t.Fatalf("create clip: %v", err)
	}

	got, err := d.GetClipByID(clip.ID)
	if err != nil {
		t.Fatalf("get clip: %v", err)
	}
	if got.Filename != nil {
		t.Fatalf("expected nil filename, got %v", got.Filename)
	}
}

func TestGetExpiredClips(t *testing.T) {
	d := setupTestDB(t)

	// Create expired clip
	expired := &Clip{
		Type:        "text",
		SizeBytes:   10,
		Status:      "ready",
		CreatedAt:   time.Now().UTC().Add(-2 * time.Hour),
		ExpiresAt:   time.Now().UTC().Add(-1 * time.Hour),
		StoragePath: "/tmp/expired",
	}
	if err := d.CreateClip(expired); err != nil {
		t.Fatalf("create expired clip: %v", err)
	}

	// Create expired uploading clip
	expiredUploading := &Clip{
		Type:        "file",
		SizeBytes:   0,
		Status:      "uploading",
		CreatedAt:   time.Now().UTC().Add(-2 * time.Hour),
		ExpiresAt:   time.Now().UTC().Add(-1 * time.Hour),
		StoragePath: "",
	}
	if err := d.CreateClip(expiredUploading); err != nil {
		t.Fatalf("create expired uploading clip: %v", err)
	}

	// Create valid clip
	valid := &Clip{
		Type:        "text",
		SizeBytes:   20,
		Status:      "ready",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/valid",
	}
	if err := d.CreateClip(valid); err != nil {
		t.Fatalf("create valid clip: %v", err)
	}

	got, err := d.GetExpiredClips()
	if err != nil {
		t.Fatalf("get expired clips: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 expired clips, got %d", len(got))
	}
}

func TestGetStorageStats(t *testing.T) {
	d := setupTestDB(t)

	// Empty DB
	stats, err := d.GetStorageStats()
	if err != nil {
		t.Fatalf("get stats: %v", err)
	}
	if stats.ClipCount != 0 || stats.StorageUsedBytes != 0 {
		t.Fatalf("expected 0/0, got %d/%d", stats.ClipCount, stats.StorageUsedBytes)
	}

	// Add clips
	for i := 0; i < 3; i++ {
		clip := &Clip{
			Type:        "text",
			SizeBytes:   int64(100 * (i + 1)),
			Status:      "ready",
			ExpiresAt:   time.Now().UTC().Add(time.Hour),
			StoragePath: "/tmp/stats",
		}
		if err := d.CreateClip(clip); err != nil {
			t.Fatalf("create clip: %v", err)
		}
	}

	stats, err = d.GetStorageStats()
	if err != nil {
		t.Fatalf("get stats: %v", err)
	}
	if stats.ClipCount != 3 {
		t.Fatalf("expected 3 clips, got %d", stats.ClipCount)
	}
	if stats.StorageUsedBytes != 600 { // 100 + 200 + 300
		t.Fatalf("expected 600 bytes, got %d", stats.StorageUsedBytes)
	}
}

func TestGenerateDeviceID(t *testing.T) {
	id, err := GenerateDeviceID()
	if err != nil {
		t.Fatalf("generate device id: %v", err)
	}
	if len(id) != 8 {
		t.Fatalf("expected 8 chars, got %d: %s", len(id), id)
	}
	for _, c := range id {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			t.Fatalf("invalid char %c in id %s", c, id)
		}
	}
}

func TestRegisterDevice(t *testing.T) {
	d := setupTestDB(t)

	dev, err := d.RegisterDevice("Mac", "macos")
	if err != nil {
		t.Fatalf("register device: %v", err)
	}
	if len(dev.ID) != 8 {
		t.Fatalf("expected 8-char id, got %d", len(dev.ID))
	}
	if dev.Name != "Mac" {
		t.Fatalf("expected name Mac, got %s", dev.Name)
	}
	if dev.Platform != "macos" {
		t.Fatalf("expected platform macos, got %s", dev.Platform)
	}
}

func TestRegisterDeviceIdempotent(t *testing.T) {
	d := setupTestDB(t)

	dev1, err := d.RegisterDevice("Mac", "macos")
	if err != nil {
		t.Fatalf("register device: %v", err)
	}

	dev2, err := d.RegisterDevice("Mac", "macos")
	if err != nil {
		t.Fatalf("re-register device: %v", err)
	}

	if dev1.ID != dev2.ID {
		t.Fatalf("expected same id on re-register, got %s vs %s", dev1.ID, dev2.ID)
	}
}

func TestRegisterDeviceDifferentPlatform(t *testing.T) {
	d := setupTestDB(t)

	dev1, _ := d.RegisterDevice("MyPC", "macos")
	dev2, _ := d.RegisterDevice("MyPC", "windows")

	if dev1.ID == dev2.ID {
		t.Fatal("expected different ids for different platforms")
	}
}

func TestListDevices(t *testing.T) {
	d := setupTestDB(t)

	devices, err := d.ListDevices()
	if err != nil {
		t.Fatalf("list devices: %v", err)
	}
	if len(devices) != 0 {
		t.Fatalf("expected 0 devices, got %d", len(devices))
	}

	d.RegisterDevice("Mac", "macos")
	d.RegisterDevice("PC", "windows")

	devices, err = d.ListDevices()
	if err != nil {
		t.Fatalf("list devices: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(devices))
	}
}

func TestCreateClipWithDeviceIDs(t *testing.T) {
	d := setupTestDB(t)

	target := "dev12345"
	sender := "dev67890"
	clip := &Clip{
		Type:           "text",
		SizeBytes:      10,
		Status:         ClipStatusTargetedPending,
		ExpiresAt:      time.Now().UTC().Add(time.Hour),
		StoragePath:    "/tmp/dev",
		TargetDeviceID: &target,
		SenderDeviceID: &sender,
	}
	if err := d.CreateClip(clip); err != nil {
		t.Fatalf("create clip: %v", err)
	}

	got, err := d.GetClipByID(clip.ID)
	if err != nil {
		t.Fatalf("get clip: %v", err)
	}
	if got.TargetDeviceID == nil || *got.TargetDeviceID != target {
		t.Fatalf("expected target_device_id=%s, got %v", target, got.TargetDeviceID)
	}
	if got.SenderDeviceID == nil || *got.SenderDeviceID != sender {
		t.Fatalf("expected sender_device_id=%s, got %v", sender, got.SenderDeviceID)
	}
	if got.ConsumedAt != nil {
		t.Fatalf("expected consumed_at=nil, got %v", got.ConsumedAt)
	}
}

func TestCreateClipTargetedLifecycleStatuses(t *testing.T) {
	d := setupTestDB(t)

	target := "dev12345"
	statuses := []string{
		ClipStatusTargetedPending,
		ClipStatusTargetedDelivered,
		ClipStatusTargetedFallback,
		ClipStatusFailed,
	}

	for i, status := range statuses {
		clip := &Clip{
			ID:             fmt.Sprintf("st%04d", i+1),
			Type:           "text",
			SizeBytes:      10,
			Status:         status,
			ExpiresAt:      time.Now().UTC().Add(time.Hour),
			StoragePath:    "/tmp/status",
			TargetDeviceID: &target,
		}
		if err := d.CreateClip(clip); err != nil {
			t.Fatalf("create clip with status %s: %v", status, err)
		}

		got, err := d.GetClipByID(clip.ID)
		if err != nil {
			t.Fatalf("get clip with status %s: %v", status, err)
		}
		if got.Status != status {
			t.Fatalf("expected status %s, got %s", status, got.Status)
		}
	}
}

func TestCreateClipNullDeviceIDs(t *testing.T) {
	d := setupTestDB(t)

	clip := &Clip{
		Type:        "text",
		SizeBytes:   10,
		Status:      "ready",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/null",
	}
	if err := d.CreateClip(clip); err != nil {
		t.Fatalf("create clip: %v", err)
	}

	got, err := d.GetClipByID(clip.ID)
	if err != nil {
		t.Fatalf("get clip: %v", err)
	}
	if got.TargetDeviceID != nil {
		t.Fatalf("expected nil target_device_id, got %v", got.TargetDeviceID)
	}
	if got.SenderDeviceID != nil {
		t.Fatalf("expected nil sender_device_id, got %v", got.SenderDeviceID)
	}
	if got.ConsumedAt != nil {
		t.Fatalf("expected nil consumed_at, got %v", got.ConsumedAt)
	}
}

func TestListQueueClips(t *testing.T) {
	d := setupTestDB(t)
	now := time.Now().UTC()

	// Untargeted, unconsumed
	d.CreateClip(&Clip{ID: "lq0001", Type: "text", SizeBytes: 5, Status: ClipStatusReady, CreatedAt: now.Add(-2 * time.Minute), ExpiresAt: now.Add(time.Hour)})
	// Targeted fallback to dev_a
	targetA := "dev_a"
	d.CreateClip(&Clip{ID: "lq0002", Type: "text", SizeBytes: 5, Status: ClipStatusTargetedFallback, CreatedAt: now.Add(-1 * time.Minute), ExpiresAt: now.Add(time.Hour), TargetDeviceID: &targetA})
	// Targeted fallback to dev_b — not visible to dev_a
	targetB := "dev_b"
	d.CreateClip(&Clip{ID: "lq0003", Type: "text", SizeBytes: 5, Status: ClipStatusTargetedFallback, CreatedAt: now, ExpiresAt: now.Add(time.Hour), TargetDeviceID: &targetB})
	// Targeted pending should not yet be visible in queue
	d.CreateClip(&Clip{ID: "lq0007", Type: "text", SizeBytes: 5, Status: ClipStatusTargetedPending, CreatedAt: now, ExpiresAt: now.Add(time.Hour), TargetDeviceID: &targetA})
	// Already consumed
	consumed := now
	d.CreateClip(&Clip{ID: "lq0004", Type: "text", SizeBytes: 5, Status: "ready", CreatedAt: now, ExpiresAt: now.Add(time.Hour), ConsumedAt: &consumed})
	// Status uploading
	d.CreateClip(&Clip{ID: "lq0005", Type: "file", SizeBytes: 0, Status: "uploading", CreatedAt: now, ExpiresAt: now.Add(time.Hour)})
	// Expired
	d.CreateClip(&Clip{ID: "lq0006", Type: "text", SizeBytes: 5, Status: "ready", CreatedAt: now.Add(-2 * time.Hour), ExpiresAt: now.Add(-1 * time.Hour)})

	clips, err := d.ListQueueClips("dev_a")
	if err != nil {
		t.Fatalf("list queue: %v", err)
	}
	if len(clips) != 2 {
		t.Fatalf("expected 2 clips, got %d", len(clips))
	}
	// Newest first
	if clips[0].ID != "lq0002" {
		t.Errorf("expected lq0002 first, got %s", clips[0].ID)
	}
	if clips[1].ID != "lq0001" {
		t.Errorf("expected lq0001 second, got %s", clips[1].ID)
	}
}

func TestConsumeClip(t *testing.T) {
	d := setupTestDB(t)

	d.CreateClip(&Clip{
		ID: "csm001", Type: "text", SizeBytes: 5, Status: "ready",
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	})

	// First consume should succeed
	ok, err := d.ConsumeClip("csm001")
	if err != nil {
		t.Fatalf("consume: %v", err)
	}
	if !ok {
		t.Fatal("expected first consume to succeed")
	}

	// Second consume should fail
	ok, err = d.ConsumeClip("csm001")
	if err != nil {
		t.Fatalf("second consume: %v", err)
	}
	if ok {
		t.Fatal("expected second consume to fail")
	}

	// Verify consumed_at is set
	clip, _ := d.GetClipByID("csm001")
	if clip.ConsumedAt == nil {
		t.Fatal("expected consumed_at to be set")
	}
}

func TestConsumeTargetedClip(t *testing.T) {
	d := setupTestDB(t)

	target := "device_a"
	d.CreateClip(&Clip{
		ID:             "tcm001",
		Type:           "text",
		SizeBytes:      5,
		Status:         ClipStatusTargetedPending,
		ExpiresAt:      time.Now().UTC().Add(time.Hour),
		TargetDeviceID: &target,
	})

	ok, err := d.ConsumeTargetedClip("tcm001", target)
	if err != nil {
		t.Fatalf("consume targeted: %v", err)
	}
	if !ok {
		t.Fatal("expected targeted consume to succeed")
	}

	clip, err := d.GetClipByID("tcm001")
	if err != nil {
		t.Fatalf("get targeted clip: %v", err)
	}
	if clip == nil {
		t.Fatal("expected targeted clip to still exist")
	}
	if clip.ConsumedAt == nil {
		t.Fatal("expected targeted consumed_at to be set")
	}
	if clip.Status != ClipStatusTargetedDelivered {
		t.Fatalf("expected targeted clip status %q, got %q", ClipStatusTargetedDelivered, clip.Status)
	}
	if clip.TargetedPendingAt != nil {
		t.Fatal("expected targeted_pending_at to be cleared after delivery")
	}

	ok, err = d.ConsumeTargetedClip("tcm001", target)
	if err != nil {
		t.Fatalf("second targeted consume: %v", err)
	}
	if ok {
		t.Fatal("expected second targeted consume to fail")
	}
}

func TestConsumeTargetedClipWrongDevice(t *testing.T) {
	d := setupTestDB(t)

	target := "device_a"
	d.CreateClip(&Clip{
		ID:             "tcm002",
		Type:           "text",
		SizeBytes:      5,
		Status:         ClipStatusTargetedPending,
		ExpiresAt:      time.Now().UTC().Add(time.Hour),
		TargetDeviceID: &target,
	})

	ok, err := d.ConsumeTargetedClip("tcm002", "device_b")
	if err != nil {
		t.Fatalf("wrong-device targeted consume: %v", err)
	}
	if ok {
		t.Fatal("expected wrong-device targeted consume to fail")
	}

	clip, err := d.GetClipByID("tcm002")
	if err != nil {
		t.Fatalf("get targeted clip after wrong-device attempt: %v", err)
	}
	if clip == nil {
		t.Fatal("expected targeted clip to still exist")
	}
	if clip.ConsumedAt != nil {
		t.Fatal("expected targeted clip to remain unconsumed")
	}
	if clip.Status != ClipStatusTargetedPending {
		t.Fatalf("expected targeted clip status %q, got %q", ClipStatusTargetedPending, clip.Status)
	}
}

func TestFallbackTargetedClips(t *testing.T) {
	d := setupTestDB(t)
	now := time.Now().UTC()
	target := "device_a"
	stalePendingAt := now.Add(-2 * time.Minute)
	freshPendingAt := now.Add(-10 * time.Second)

	if err := d.CreateClip(&Clip{
		ID:                "fb0001",
		Type:              "text",
		SizeBytes:         5,
		Status:            ClipStatusTargetedPending,
		CreatedAt:         now.Add(-3 * time.Minute),
		ExpiresAt:         now.Add(time.Hour),
		TargetDeviceID:    &target,
		TargetedPendingAt: &stalePendingAt,
	}); err != nil {
		t.Fatalf("create stale targeted pending clip: %v", err)
	}

	if err := d.CreateClip(&Clip{
		ID:                "fb0002",
		Type:              "text",
		SizeBytes:         5,
		Status:            ClipStatusTargetedPending,
		CreatedAt:         now.Add(-1 * time.Minute),
		ExpiresAt:         now.Add(time.Hour),
		TargetDeviceID:    &target,
		TargetedPendingAt: &freshPendingAt,
	}); err != nil {
		t.Fatalf("create fresh targeted pending clip: %v", err)
	}

	rows, err := d.FallbackTargetedClips(30 * time.Second)
	if err != nil {
		t.Fatalf("fallback targeted clips: %v", err)
	}
	if rows != 1 {
		t.Fatalf("expected 1 targeted clip to fall back, got %d", rows)
	}

	stale, err := d.GetClipByID("fb0001")
	if err != nil {
		t.Fatalf("get stale targeted clip: %v", err)
	}
	if stale.Status != ClipStatusTargetedFallback {
		t.Fatalf("expected stale clip status %q, got %q", ClipStatusTargetedFallback, stale.Status)
	}
	if stale.TargetedPendingAt != nil {
		t.Fatal("expected stale clip targeted_pending_at to be cleared")
	}

	fresh, err := d.GetClipByID("fb0002")
	if err != nil {
		t.Fatalf("get fresh targeted clip: %v", err)
	}
	if fresh.Status != ClipStatusTargetedPending {
		t.Fatalf("expected fresh clip status %q, got %q", ClipStatusTargetedPending, fresh.Status)
	}
}

func TestConsumeClipNotFound(t *testing.T) {
	d := setupTestDB(t)

	ok, err := d.ConsumeClip("nonexist")
	if err != nil {
		t.Fatalf("consume nonexistent: %v", err)
	}
	if ok {
		t.Fatal("expected consume of nonexistent clip to return false")
	}
}

func TestGetConsumedClips(t *testing.T) {
	d := setupTestDB(t)
	now := time.Now().UTC()

	// Consumed clip older than threshold (consumed 2 minutes ago)
	consumedOld := now.Add(-2 * time.Minute)
	d.CreateClip(&Clip{
		ID: "gc0001", Type: "text", SizeBytes: 5, Status: "ready",
		ExpiresAt: now.Add(time.Hour), ConsumedAt: &consumedOld,
	})

	// Consumed clip newer than threshold (consumed just now)
	consumedNew := now
	d.CreateClip(&Clip{
		ID: "gc0002", Type: "text", SizeBytes: 5, Status: "ready",
		ExpiresAt: now.Add(time.Hour), ConsumedAt: &consumedNew,
	})

	// Unconsumed clip
	d.CreateClip(&Clip{
		ID: "gc0003", Type: "text", SizeBytes: 5, Status: "ready",
		ExpiresAt: now.Add(time.Hour),
	})

	// With 60s threshold, only gc0001 should be returned
	clips, err := d.GetConsumedClips(60 * time.Second)
	if err != nil {
		t.Fatalf("get consumed clips: %v", err)
	}
	if len(clips) != 1 {
		t.Fatalf("expected 1 consumed clip, got %d", len(clips))
	}
	if clips[0].ID != "gc0001" {
		t.Fatalf("expected gc0001, got %s", clips[0].ID)
	}
}

func TestGetConsumedClipsEmpty(t *testing.T) {
	d := setupTestDB(t)

	clips, err := d.GetConsumedClips(60 * time.Second)
	if err != nil {
		t.Fatalf("get consumed clips: %v", err)
	}
	if len(clips) != 0 {
		t.Fatalf("expected 0 consumed clips, got %d", len(clips))
	}
}

func TestDatabaseCreatedAtStoragePath(t *testing.T) {
	dir := t.TempDir()
	d, err := Open(dir)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	d.Close()

	dbPath := dir + "/copy_everywhere.db"
	if _, err := os.Stat(dbPath); os.IsNotExist(err) {
		t.Fatal("expected database file to exist at storage path")
	}
}
