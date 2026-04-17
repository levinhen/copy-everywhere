package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/copy-everywhere/server/db"
	"github.com/gin-gonic/gin"
)

func init() {
	gin.SetMode(gin.TestMode)
}

func setupTestHandler(t *testing.T) (*ClipHandler, *gin.Engine) {
	t.Helper()
	tmpDir := t.TempDir()

	database, err := db.Open(tmpDir)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { database.Close() })

	h := &ClipHandler{
		DB:            database,
		StoragePath:   tmpDir,
		MaxClipSizeMB: 1, // 1MB for tests
		TTLHours:      1,
	}

	r := gin.New()
	api := r.Group("/api/v1")
	api.POST("/clips", h.Upload)
	api.GET("/clips", h.ListQueue)
	api.GET("/clips/latest", h.GetLatest)
	api.GET("/clips/:id", h.GetByID)
	api.GET("/clips/:id/raw", h.GetRaw)

	return h, r
}

func createMultipartRequest(t *testing.T, clipType, filename, content string) *http.Request {
	t.Helper()
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)

	if err := writer.WriteField("type", clipType); err != nil {
		t.Fatal(err)
	}

	part, err := writer.CreateFormFile("content", filename)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(part, content); err != nil {
		t.Fatal(err)
	}
	writer.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/v1/clips", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	return req
}

func TestUploadTextClip(t *testing.T) {
	_, r := setupTestHandler(t)

	req := createMultipartRequest(t, "text", "clipboard.txt", "Hello, World!")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", w.Code, w.Body.String())
	}

	var resp clipResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}

	if len(resp.ID) != 6 {
		t.Errorf("expected 6-char ID, got %q", resp.ID)
	}
	if resp.Type != "text" {
		t.Errorf("expected type=text, got %q", resp.Type)
	}
	if resp.SizeBytes != 13 {
		t.Errorf("expected size 13, got %d", resp.SizeBytes)
	}
	if resp.ExpiresAt.Before(resp.CreatedAt) {
		t.Error("expires_at should be after created_at")
	}
}

func TestUploadMissingType(t *testing.T) {
	_, r := setupTestHandler(t)

	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, _ := writer.CreateFormFile("content", "test.txt")
	io.WriteString(part, "data")
	writer.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/v1/clips", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestUploadExceedsMaxSize(t *testing.T) {
	_, r := setupTestHandler(t) // max 1MB

	// Create content larger than 1MB
	bigContent := make([]byte, 2*1024*1024)
	for i := range bigContent {
		bigContent[i] = 'A'
	}

	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	writer.WriteField("type", "file")
	part, _ := writer.CreateFormFile("content", "big.bin")
	part.Write(bigContent)
	writer.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/v1/clips", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d: %s", w.Code, w.Body.String())
	}
}

func TestGetClipByID(t *testing.T) {
	h, r := setupTestHandler(t)

	// Create a clip directly in DB
	clip := &db.Clip{
		ID:          "abc123",
		Type:        "text",
		SizeBytes:   5,
		Status:      "ready",
		CreatedAt:   time.Now().UTC(),
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/test",
	}
	if err := h.DB.CreateClip(clip); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/abc123", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp clipResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.ID != "abc123" {
		t.Errorf("expected id=abc123, got %q", resp.ID)
	}
}

func TestGetClipByIDNotFound(t *testing.T) {
	_, r := setupTestHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/xxxxxx", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestGetClipByIDExpired(t *testing.T) {
	h, r := setupTestHandler(t)

	clip := &db.Clip{
		ID:          "exp123",
		Type:        "text",
		SizeBytes:   5,
		Status:      "ready",
		CreatedAt:   time.Now().UTC().Add(-2 * time.Hour),
		ExpiresAt:   time.Now().UTC().Add(-1 * time.Hour), // expired
		StoragePath: "/tmp/test",
	}
	h.DB.CreateClip(clip)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/exp123", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for expired clip, got %d", w.Code)
	}
}

func TestGetLatestClip(t *testing.T) {
	h, r := setupTestHandler(t)

	// Create two clips
	h.DB.CreateClip(&db.Clip{
		ID: "old111", Type: "text", SizeBytes: 3, Status: "ready",
		CreatedAt: time.Now().UTC().Add(-30 * time.Minute),
		ExpiresAt: time.Now().UTC().Add(30 * time.Minute),
	})
	h.DB.CreateClip(&db.Clip{
		ID: "new222", Type: "text", SizeBytes: 5, Status: "ready",
		CreatedAt: time.Now().UTC(),
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/latest", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp clipResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.ID != "new222" {
		t.Errorf("expected latest=new222, got %q", resp.ID)
	}
}

func TestGetLatestNoClips(t *testing.T) {
	_, r := setupTestHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/latest", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestGetRawContent(t *testing.T) {
	h, r := setupTestHandler(t)

	// Create a real file
	clipDir := filepath.Join(h.StoragePath, "raw123")
	os.MkdirAll(clipDir, 0755)
	filePath := filepath.Join(clipDir, "hello.txt")
	os.WriteFile(filePath, []byte("Hello, World!"), 0644)

	filename := "hello.txt"
	h.DB.CreateClip(&db.Clip{
		ID: "raw123", Type: "text", Filename: &filename, SizeBytes: 13, Status: "ready",
		CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour),
		StoragePath: filePath,
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/raw123/raw", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	if w.Body.String() != "Hello, World!" {
		t.Errorf("expected body 'Hello, World!', got %q", w.Body.String())
	}

	ct := w.Header().Get("Content-Type")
	if ct != "text/plain; charset=utf-8" {
		t.Errorf("expected text/plain content-type, got %q", ct)
	}

	disp := w.Header().Get("Content-Disposition")
	if disp == "" {
		t.Error("expected Content-Disposition header")
	}
}

func TestGetRawFailedClip(t *testing.T) {
	h, r := setupTestHandler(t)

	h.DB.CreateClip(&db.Clip{
		ID: "fail12", Type: "file", SizeBytes: 100, Status: "failed",
		CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour),
		StoragePath: "/tmp/whatever",
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/fail12/raw", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for failed clip, got %d", w.Code)
	}
}

func TestGetRawNotFound(t *testing.T) {
	_, r := setupTestHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/nope12/raw", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestUploadWithDeviceIDs(t *testing.T) {
	h, r := setupTestHandler(t)

	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	writer.WriteField("type", "text")
	writer.WriteField("target_device_id", "dev12345")
	writer.WriteField("sender_device_id", "dev67890")
	part, _ := writer.CreateFormFile("content", "clipboard.txt")
	io.WriteString(part, "Hello!")
	writer.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/v1/clips", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", w.Code, w.Body.String())
	}

	var resp clipResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	// Verify device IDs were persisted in DB
	clip, err := h.DB.GetClipByID(resp.ID)
	if err != nil {
		t.Fatal(err)
	}
	if clip.TargetDeviceID == nil || *clip.TargetDeviceID != "dev12345" {
		t.Errorf("expected target_device_id=dev12345, got %v", clip.TargetDeviceID)
	}
	if clip.SenderDeviceID == nil || *clip.SenderDeviceID != "dev67890" {
		t.Errorf("expected sender_device_id=dev67890, got %v", clip.SenderDeviceID)
	}
	if clip.Status != db.ClipStatusTargetedPending {
		t.Errorf("expected targeted clip status %q, got %q", db.ClipStatusTargetedPending, clip.Status)
	}
}

func TestUploadWithoutDeviceIDs(t *testing.T) {
	h, r := setupTestHandler(t)

	req := createMultipartRequest(t, "text", "clipboard.txt", "Hello!")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", w.Code, w.Body.String())
	}

	var resp clipResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	clip, err := h.DB.GetClipByID(resp.ID)
	if err != nil {
		t.Fatal(err)
	}
	if clip.TargetDeviceID != nil {
		t.Errorf("expected nil target_device_id, got %v", clip.TargetDeviceID)
	}
	if clip.SenderDeviceID != nil {
		t.Errorf("expected nil sender_device_id, got %v", clip.SenderDeviceID)
	}
	if clip.Status != db.ClipStatusReady {
		t.Errorf("expected untargeted clip status %q, got %q", db.ClipStatusReady, clip.Status)
	}
}

func TestGetRawAtomicConsume(t *testing.T) {
	h, r := setupTestHandler(t)

	// Create a real file
	clipDir := filepath.Join(h.StoragePath, "con123")
	os.MkdirAll(clipDir, 0755)
	filePath := filepath.Join(clipDir, "hello.txt")
	os.WriteFile(filePath, []byte("consume me"), 0644)

	filename := "hello.txt"
	h.DB.CreateClip(&db.Clip{
		ID: "con123", Type: "text", Filename: &filename, SizeBytes: 10, Status: "ready",
		CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour),
		StoragePath: filePath,
	})

	// First call should succeed
	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/con123/raw", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("first call: expected 200, got %d: %s", w.Code, w.Body.String())
	}
	if w.Body.String() != "consume me" {
		t.Errorf("expected body 'consume me', got %q", w.Body.String())
	}

	// Second call should get 410 Gone
	req = httptest.NewRequest(http.MethodGet, "/api/v1/clips/con123/raw", nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusGone {
		t.Fatalf("second call: expected 410, got %d: %s", w.Code, w.Body.String())
	}

	var errResp map[string]string
	json.Unmarshal(w.Body.Bytes(), &errResp)
	if errResp["error"] != "already_consumed" {
		t.Errorf("expected error=already_consumed, got %q", errResp["error"])
	}
}

func TestGetRawTargetedConsumeMarksDelivered(t *testing.T) {
	h, r := setupTestHandler(t)

	clipDir := filepath.Join(h.StoragePath, "traw01")
	os.MkdirAll(clipDir, 0755)
	filePath := filepath.Join(clipDir, "hello.txt")
	os.WriteFile(filePath, []byte("targeted"), 0644)

	filename := "hello.txt"
	target := "dev_target"
	h.DB.CreateClip(&db.Clip{
		ID:             "traw01",
		Type:           "text",
		Filename:       &filename,
		SizeBytes:      8,
		Status:         db.ClipStatusTargetedPending,
		CreatedAt:      time.Now().UTC(),
		ExpiresAt:      time.Now().UTC().Add(time.Hour),
		StoragePath:    filePath,
		TargetDeviceID: &target,
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/traw01/raw?device_id=dev_target", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	clip, err := h.DB.GetClipByID("traw01")
	if err != nil {
		t.Fatalf("get targeted clip: %v", err)
	}
	if clip == nil {
		t.Fatal("expected targeted clip record to persist after consume")
	}
	if clip.ConsumedAt == nil {
		t.Fatal("expected targeted clip consumed_at to be set")
	}
	if clip.Status != db.ClipStatusTargetedDelivered {
		t.Fatalf("expected targeted clip status %q, got %q", db.ClipStatusTargetedDelivered, clip.Status)
	}
}

func TestGetRawTargetedConsumeRequiresMatchingDeviceID(t *testing.T) {
	h, r := setupTestHandler(t)

	clipDir := filepath.Join(h.StoragePath, "traw02")
	os.MkdirAll(clipDir, 0755)
	filePath := filepath.Join(clipDir, "hello.txt")
	os.WriteFile(filePath, []byte("targeted"), 0644)

	filename := "hello.txt"
	target := "dev_target"
	h.DB.CreateClip(&db.Clip{
		ID:             "traw02",
		Type:           "text",
		Filename:       &filename,
		SizeBytes:      8,
		Status:         db.ClipStatusTargetedPending,
		CreatedAt:      time.Now().UTC(),
		ExpiresAt:      time.Now().UTC().Add(time.Hour),
		StoragePath:    filePath,
		TargetDeviceID: &target,
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/traw02/raw?device_id=other_device", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d: %s", w.Code, w.Body.String())
	}

	clip, err := h.DB.GetClipByID("traw02")
	if err != nil {
		t.Fatalf("get targeted clip after wrong-device request: %v", err)
	}
	if clip == nil {
		t.Fatal("expected targeted clip to still exist")
	}
	if clip.ConsumedAt != nil {
		t.Fatal("expected wrong-device request not to consume the clip")
	}
	if clip.Status != db.ClipStatusTargetedPending {
		t.Fatalf("expected targeted clip status %q, got %q", db.ClipStatusTargetedPending, clip.Status)
	}
}

func TestGetRawTargetedConsumeRequiresDeviceID(t *testing.T) {
	h, r := setupTestHandler(t)

	clipDir := filepath.Join(h.StoragePath, "traw03")
	os.MkdirAll(clipDir, 0755)
	filePath := filepath.Join(clipDir, "hello.txt")
	os.WriteFile(filePath, []byte("targeted"), 0644)

	filename := "hello.txt"
	target := "dev_target"
	h.DB.CreateClip(&db.Clip{
		ID:             "traw03",
		Type:           "text",
		Filename:       &filename,
		SizeBytes:      8,
		Status:         db.ClipStatusTargetedPending,
		CreatedAt:      time.Now().UTC(),
		ExpiresAt:      time.Now().UTC().Add(time.Hour),
		StoragePath:    filePath,
		TargetDeviceID: &target,
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/traw03/raw", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
	}

	clip, err := h.DB.GetClipByID("traw03")
	if err != nil {
		t.Fatalf("get targeted clip after missing-device request: %v", err)
	}
	if clip == nil {
		t.Fatal("expected targeted clip to still exist")
	}
	if clip.ConsumedAt != nil {
		t.Fatal("expected missing-device request not to consume the clip")
	}
	if clip.Status != db.ClipStatusTargetedPending {
		t.Fatalf("expected targeted clip status %q, got %q", db.ClipStatusTargetedPending, clip.Status)
	}
}

func TestGetRawTargetedConsumeDuplicateReturnsGone(t *testing.T) {
	h, r := setupTestHandler(t)

	clipDir := filepath.Join(h.StoragePath, "traw04")
	os.MkdirAll(clipDir, 0755)
	filePath := filepath.Join(clipDir, "hello.txt")
	os.WriteFile(filePath, []byte("targeted"), 0644)

	filename := "hello.txt"
	target := "dev_target"
	h.DB.CreateClip(&db.Clip{
		ID:             "traw04",
		Type:           "text",
		Filename:       &filename,
		SizeBytes:      8,
		Status:         db.ClipStatusTargetedPending,
		CreatedAt:      time.Now().UTC(),
		ExpiresAt:      time.Now().UTC().Add(time.Hour),
		StoragePath:    filePath,
		TargetDeviceID: &target,
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/traw04/raw?device_id=dev_target", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("first call: expected 200, got %d: %s", w.Code, w.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/clips/traw04/raw?device_id=dev_target", nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusGone {
		t.Fatalf("second call: expected 410, got %d: %s", w.Code, w.Body.String())
	}

	clip, err := h.DB.GetClipByID("traw04")
	if err != nil {
		t.Fatalf("get targeted clip after duplicate request: %v", err)
	}
	if clip == nil {
		t.Fatal("expected targeted clip to still exist")
	}
	if clip.Status != db.ClipStatusTargetedDelivered {
		t.Fatalf("expected targeted clip status %q, got %q", db.ClipStatusTargetedDelivered, clip.Status)
	}
}

func TestGetRawRaceCondition(t *testing.T) {
	h, r := setupTestHandler(t)

	// Create a real file
	clipDir := filepath.Join(h.StoragePath, "race12")
	os.MkdirAll(clipDir, 0755)
	filePath := filepath.Join(clipDir, "data.txt")
	os.WriteFile(filePath, []byte("race data"), 0644)

	filename := "data.txt"
	h.DB.CreateClip(&db.Clip{
		ID: "race12", Type: "text", Filename: &filename, SizeBytes: 9, Status: "ready",
		CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour),
		StoragePath: filePath,
	})

	// Fire two parallel GET /raw requests
	results := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func() {
			req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/race12/raw", nil)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)
			results <- w.Code
		}()
	}

	codes := make(map[int]int)
	for i := 0; i < 2; i++ {
		code := <-results
		codes[code]++
	}

	// Exactly one should get 200, the other should get 410
	if codes[http.StatusOK] != 1 {
		t.Errorf("expected exactly 1 x 200, got %d (codes: %v)", codes[http.StatusOK], codes)
	}
	if codes[http.StatusGone] != 1 {
		t.Errorf("expected exactly 1 x 410, got %d (codes: %v)", codes[http.StatusGone], codes)
	}
}

func TestListQueue(t *testing.T) {
	h, r := setupTestHandler(t)

	// Create clips with various states
	now := time.Now().UTC()

	// Unconsumed, no target — visible to any device
	h.DB.CreateClip(&db.Clip{
		ID: "q00001", Type: "text", SizeBytes: 5, Status: "ready",
		CreatedAt: now.Add(-2 * time.Minute), ExpiresAt: now.Add(time.Hour),
	})
	// Unconsumed, targeted to dev_a — visible to dev_a only
	targetA := "dev_a"
	h.DB.CreateClip(&db.Clip{
		ID: "q00002", Type: "text", SizeBytes: 5, Status: "ready",
		CreatedAt: now.Add(-1 * time.Minute), ExpiresAt: now.Add(time.Hour),
		TargetDeviceID: &targetA,
	})
	// Unconsumed, targeted to dev_b — NOT visible to dev_a
	targetB := "dev_b"
	h.DB.CreateClip(&db.Clip{
		ID: "q00003", Type: "text", SizeBytes: 5, Status: "ready",
		CreatedAt: now, ExpiresAt: now.Add(time.Hour),
		TargetDeviceID: &targetB,
	})
	// Already consumed — NOT visible
	consumed := now
	h.DB.CreateClip(&db.Clip{
		ID: "q00004", Type: "text", SizeBytes: 5, Status: "ready",
		CreatedAt: now, ExpiresAt: now.Add(time.Hour),
		ConsumedAt: &consumed,
	})
	// Uploading status — NOT visible
	h.DB.CreateClip(&db.Clip{
		ID: "q00005", Type: "file", SizeBytes: 0, Status: "uploading",
		CreatedAt: now, ExpiresAt: now.Add(time.Hour),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips?device_id=dev_a", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var clips []clipResponse
	json.Unmarshal(w.Body.Bytes(), &clips)

	if len(clips) != 2 {
		t.Fatalf("expected 2 clips for dev_a, got %d", len(clips))
	}

	// Newest first: q00002 then q00001
	if clips[0].ID != "q00002" {
		t.Errorf("expected first clip q00002, got %s", clips[0].ID)
	}
	if clips[1].ID != "q00001" {
		t.Errorf("expected second clip q00001, got %s", clips[1].ID)
	}
}

func TestListQueueMissingDeviceID(t *testing.T) {
	_, r := setupTestHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestGetLatestDeprecationHeader(t *testing.T) {
	h, r := setupTestHandler(t)

	h.DB.CreateClip(&db.Clip{
		ID: "dep123", Type: "text", SizeBytes: 5, Status: "ready",
		CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour),
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/clips/latest", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	if w.Header().Get("Deprecation") != "true" {
		t.Error("expected Deprecation header to be 'true'")
	}
}

func TestUploadAndDownloadRoundTrip(t *testing.T) {
	_, r := setupTestHandler(t)

	// Upload
	req := createMultipartRequest(t, "text", "test.txt", "round trip content")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("upload: expected 201, got %d: %s", w.Code, w.Body.String())
	}

	var uploadResp clipResponse
	json.Unmarshal(w.Body.Bytes(), &uploadResp)

	// Download raw
	req = httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/v1/clips/%s/raw", uploadResp.ID), nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("download: expected 200, got %d", w.Code)
	}
	if w.Body.String() != "round trip content" {
		t.Errorf("download: expected 'round trip content', got %q", w.Body.String())
	}
}
