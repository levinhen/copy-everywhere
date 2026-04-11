package db

import (
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
		Status:         "ready",
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
