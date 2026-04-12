package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/copy-everywhere/server/db"
	"github.com/gin-gonic/gin"
)

func setupUploadTestHandler(t *testing.T) (*UploadHandler, *ClipHandler, *gin.Engine) {
	t.Helper()
	tmpDir := t.TempDir()

	database, err := db.Open(tmpDir)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { database.Close() })

	uh := &UploadHandler{
		DB:            database,
		StoragePath:   tmpDir,
		MaxClipSizeMB: 10,
		TTLHours:      1,
	}

	ch := &ClipHandler{
		DB:            database,
		StoragePath:   tmpDir,
		MaxClipSizeMB: 10,
		TTLHours:      1,
	}

	r := gin.New()
	api := r.Group("/api/v1")
	api.POST("/uploads/init", uh.InitUpload)
	api.PUT("/uploads/:id/parts/:n", uh.UploadPart)
	api.POST("/uploads/:id/complete", uh.CompleteUpload)
	api.GET("/uploads/:id/status", uh.GetUploadStatus)
	api.GET("/clips/:id", ch.GetByID)
	api.GET("/clips/:id/raw", ch.GetRaw)

	return uh, ch, r
}

func TestInitUpload(t *testing.T) {
	_, _, r := setupUploadTestHandler(t)

	body, _ := json.Marshal(initUploadRequest{
		Filename:  "bigfile.zip",
		SizeBytes: 1000,
		ChunkSize: 300,
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/uploads/init", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", w.Code, w.Body.String())
	}

	var resp initUploadResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	if len(resp.UploadID) != 6 {
		t.Errorf("expected 6-char upload ID, got %q", resp.UploadID)
	}
	// 1000 / 300 = 3.33 -> 4 chunks
	if resp.ChunkCount != 4 {
		t.Errorf("expected 4 chunks, got %d", resp.ChunkCount)
	}
}

func TestInitUploadExceedsMaxSize(t *testing.T) {
	_, _, r := setupUploadTestHandler(t) // max 10MB

	body, _ := json.Marshal(initUploadRequest{
		Filename:  "huge.bin",
		SizeBytes: 11 * 1024 * 1024, // 11MB
		ChunkSize: 1024 * 1024,
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/uploads/init", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d: %s", w.Code, w.Body.String())
	}
}

func TestInitUploadMissingFields(t *testing.T) {
	_, _, r := setupUploadTestHandler(t)

	body, _ := json.Marshal(map[string]string{"filename": "test.bin"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/uploads/init", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
	}
}

func TestUploadPartAndConflict(t *testing.T) {
	uh, _, r := setupUploadTestHandler(t)

	// Create an upload record
	now := time.Now().UTC()
	partsDir := filepath.Join(uh.StoragePath, "uploads", "upl123")
	os.MkdirAll(partsDir, 0755)

	filename := "test.bin"
	uh.DB.CreateClip(&db.Clip{
		ID: "upl123", Type: "file", Filename: &filename, SizeBytes: 600,
		Status: "uploading", CreatedAt: now, ExpiresAt: now.Add(time.Hour),
		StoragePath: partsDir,
	})

	// Upload part 1
	chunkData := bytes.Repeat([]byte("A"), 300)
	req := httptest.NewRequest(http.MethodPut, "/api/v1/uploads/upl123/parts/1", bytes.NewReader(chunkData))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// Try uploading same part again -> 409
	req = httptest.NewRequest(http.MethodPut, "/api/v1/uploads/upl123/parts/1", bytes.NewReader(chunkData))
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409 for duplicate part, got %d: %s", w.Code, w.Body.String())
	}
}

func TestUploadPartNotFound(t *testing.T) {
	_, _, r := setupUploadTestHandler(t)

	req := httptest.NewRequest(http.MethodPut, "/api/v1/uploads/nope12/parts/1", bytes.NewReader([]byte("data")))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", w.Code, w.Body.String())
	}
}

func TestCompleteUploadMissingChunks(t *testing.T) {
	uh, _, r := setupUploadTestHandler(t)

	now := time.Now().UTC()
	partsDir := filepath.Join(uh.StoragePath, "uploads", "mis123")
	os.MkdirAll(partsDir, 0755)

	// Write only part 1 of 2 expected
	os.WriteFile(filepath.Join(partsDir, "part_1"), bytes.Repeat([]byte("A"), 300), 0644)

	filename := "test.bin"
	uh.DB.CreateClip(&db.Clip{
		ID: "mis123", Type: "file", Filename: &filename, SizeBytes: 600,
		Status: "uploading", CreatedAt: now, ExpiresAt: now.Add(time.Hour),
		StoragePath: partsDir,
	})

	req := httptest.NewRequest(http.MethodPost, "/api/v1/uploads/mis123/complete", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing chunks, got %d: %s", w.Code, w.Body.String())
	}
}

func TestCompleteUploadNotFound(t *testing.T) {
	_, _, r := setupUploadTestHandler(t)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/uploads/nope12/complete", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", w.Code, w.Body.String())
	}
}

func TestGetUploadStatus(t *testing.T) {
	uh, _, r := setupUploadTestHandler(t)

	now := time.Now().UTC()
	partsDir := filepath.Join(uh.StoragePath, "uploads", "sts123")
	os.MkdirAll(partsDir, 0755)

	// Write parts 1 and 3
	os.WriteFile(filepath.Join(partsDir, "part_1"), bytes.Repeat([]byte("A"), 300), 0644)
	os.WriteFile(filepath.Join(partsDir, "part_3"), bytes.Repeat([]byte("C"), 300), 0644)

	filename := "test.bin"
	uh.DB.CreateClip(&db.Clip{
		ID: "sts123", Type: "file", Filename: &filename, SizeBytes: 900,
		Status: "uploading", CreatedAt: now, ExpiresAt: now.Add(time.Hour),
		StoragePath: partsDir,
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/uploads/sts123/status", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp uploadStatusResponse
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp.UploadID != "sts123" {
		t.Errorf("expected upload_id=sts123, got %q", resp.UploadID)
	}
	if len(resp.ReceivedParts) != 2 {
		t.Errorf("expected 2 received parts, got %d", len(resp.ReceivedParts))
	}
	if resp.TotalParts != 3 {
		t.Errorf("expected 3 total parts, got %d", resp.TotalParts)
	}
	if resp.Status != "uploading" {
		t.Errorf("expected status=uploading, got %q", resp.Status)
	}
}

func TestGetUploadStatusNotFound(t *testing.T) {
	_, _, r := setupUploadTestHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/uploads/nope12/status", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", w.Code, w.Body.String())
	}
}

func TestChunkedUploadFullRoundTrip(t *testing.T) {
	_, _, r := setupUploadTestHandler(t)

	// Step 1: Init upload
	initBody, _ := json.Marshal(initUploadRequest{
		Filename:  "testfile.dat",
		SizeBytes: 900,
		ChunkSize: 300,
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/uploads/init", bytes.NewReader(initBody))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("init: expected 201, got %d: %s", w.Code, w.Body.String())
	}

	var initResp initUploadResponse
	json.Unmarshal(w.Body.Bytes(), &initResp)

	if initResp.ChunkCount != 3 {
		t.Fatalf("expected 3 chunks, got %d", initResp.ChunkCount)
	}

	// Step 2: Upload all 3 chunks
	for i := 1; i <= 3; i++ {
		chunkData := bytes.Repeat([]byte{byte('A' + i - 1)}, 300)
		req = httptest.NewRequest(http.MethodPut,
			fmt.Sprintf("/api/v1/uploads/%s/parts/%d", initResp.UploadID, i),
			bytes.NewReader(chunkData))
		w = httptest.NewRecorder()
		r.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("upload part %d: expected 200, got %d: %s", i, w.Code, w.Body.String())
		}
	}

	// Step 3: Check status
	req = httptest.NewRequest(http.MethodGet,
		fmt.Sprintf("/api/v1/uploads/%s/status", initResp.UploadID), nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status: expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var statusResp uploadStatusResponse
	json.Unmarshal(w.Body.Bytes(), &statusResp)
	if len(statusResp.ReceivedParts) != 3 {
		t.Errorf("expected 3 received parts, got %d", len(statusResp.ReceivedParts))
	}

	// Step 4: Complete
	req = httptest.NewRequest(http.MethodPost,
		fmt.Sprintf("/api/v1/uploads/%s/complete", initResp.UploadID), nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("complete: expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var completeResp clipResponse
	json.Unmarshal(w.Body.Bytes(), &completeResp)

	if completeResp.ID != initResp.UploadID {
		t.Errorf("expected ID=%s, got %s", initResp.UploadID, completeResp.ID)
	}
	if completeResp.SizeBytes != 900 {
		t.Errorf("expected size 900, got %d", completeResp.SizeBytes)
	}

	// Step 5: Verify clip metadata shows ready
	req = httptest.NewRequest(http.MethodGet,
		fmt.Sprintf("/api/v1/clips/%s", initResp.UploadID), nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("get clip: expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// Step 6: Download raw content and verify merged data
	req = httptest.NewRequest(http.MethodGet,
		fmt.Sprintf("/api/v1/clips/%s/raw", initResp.UploadID), nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("raw: expected 200, got %d: %s", w.Code, w.Body.String())
	}

	expectedContent := string(bytes.Repeat([]byte("A"), 300)) +
		string(bytes.Repeat([]byte("B"), 300)) +
		string(bytes.Repeat([]byte("C"), 300))
	if w.Body.String() != expectedContent {
		t.Error("merged file content does not match expected chunks")
	}
}
