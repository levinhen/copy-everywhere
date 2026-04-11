package handlers

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"

	"github.com/copy-everywhere/server/db"
	"github.com/gin-gonic/gin"
)

type initUploadRequest struct {
	Filename       string  `json:"filename" binding:"required"`
	SizeBytes      int64   `json:"size_bytes" binding:"required"`
	ChunkSize      int64   `json:"chunk_size" binding:"required"`
	TargetDeviceID *string `json:"target_device_id"`
	SenderDeviceID *string `json:"sender_device_id"`
}

type initUploadResponse struct {
	UploadID   string `json:"upload_id"`
	ChunkCount int    `json:"chunk_count"`
}

type uploadStatusResponse struct {
	UploadID      string `json:"upload_id"`
	ReceivedParts []int  `json:"received_parts"`
	TotalParts    int    `json:"total_parts"`
	Status        string `json:"status"`
}

// UploadHandler handles chunked upload endpoints.
type UploadHandler struct {
	DB            *db.DB
	StoragePath   string
	MaxClipSizeMB int
	TTLHours      int
}

// InitUpload handles POST /api/v1/uploads/init
func (h *UploadHandler) InitUpload(c *gin.Context) {
	var req initUploadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request: filename, size_bytes, and chunk_size are required"})
		return
	}

	maxBytes := int64(h.MaxClipSizeMB) * 1024 * 1024
	if req.SizeBytes > maxBytes {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{
			"error": fmt.Sprintf("file size %d bytes exceeds maximum %d MB", req.SizeBytes, h.MaxClipSizeMB),
		})
		return
	}

	uploadID, err := db.GenerateID()
	if err != nil {
		log.Printf("ERROR: generate upload ID: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	// Calculate chunk count
	chunkCount := int(req.SizeBytes / req.ChunkSize)
	if req.SizeBytes%req.ChunkSize != 0 {
		chunkCount++
	}

	// Create upload parts directory
	partsDir := filepath.Join(h.StoragePath, "uploads", uploadID)
	if err := os.MkdirAll(partsDir, 0755); err != nil {
		log.Printf("ERROR: create upload dir: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	// Create clip record with status=uploading
	now := time.Now().UTC()
	clip := &db.Clip{
		ID:             uploadID,
		Type:           "file",
		Filename:       &req.Filename,
		SizeBytes:      req.SizeBytes,
		Status:         "uploading",
		CreatedAt:      now,
		ExpiresAt:      now.Add(time.Duration(h.TTLHours) * time.Hour),
		StoragePath:    partsDir,
		TargetDeviceID: req.TargetDeviceID,
		SenderDeviceID: req.SenderDeviceID,
	}

	if err := h.DB.CreateClip(clip); err != nil {
		log.Printf("ERROR: create clip record: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	c.JSON(http.StatusCreated, initUploadResponse{
		UploadID:   uploadID,
		ChunkCount: chunkCount,
	})
}

// UploadPart handles PUT /api/v1/uploads/:id/parts/:n
func (h *UploadHandler) UploadPart(c *gin.Context) {
	uploadID := c.Param("id")
	partNum := c.Param("n")

	// Validate part number
	n, err := strconv.Atoi(partNum)
	if err != nil || n < 1 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid part number"})
		return
	}

	// Check upload exists
	clip, err := h.DB.GetClipByID(uploadID)
	if err != nil {
		log.Printf("ERROR: get clip: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	if clip == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "upload not found"})
		return
	}

	partsDir := filepath.Join(h.StoragePath, "uploads", uploadID)
	partPath := filepath.Join(partsDir, fmt.Sprintf("part_%d", n))

	// Check if chunk already uploaded
	if _, err := os.Stat(partPath); err == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "chunk already uploaded"})
		return
	}

	// Save chunk
	out, err := os.Create(partPath)
	if err != nil {
		log.Printf("ERROR: create part file: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	defer out.Close()

	if _, err := io.Copy(out, c.Request.Body); err != nil {
		log.Printf("ERROR: write part: %v", err)
		os.Remove(partPath)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"part": n, "status": "received"})
}

// CompleteUpload handles POST /api/v1/uploads/:id/complete
func (h *UploadHandler) CompleteUpload(c *gin.Context) {
	uploadID := c.Param("id")

	clip, err := h.DB.GetClipByID(uploadID)
	if err != nil {
		log.Printf("ERROR: get clip: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	if clip == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "upload not found"})
		return
	}

	partsDir := filepath.Join(h.StoragePath, "uploads", uploadID)
	receivedParts, totalParts := h.getPartsInfo(partsDir, clip.SizeBytes)

	// Check all chunks are present
	if len(receivedParts) != totalParts {
		c.JSON(http.StatusBadRequest, gin.H{
			"error":          "missing chunks",
			"received_parts": receivedParts,
			"total_parts":    totalParts,
		})
		return
	}

	// Merge chunks into final file
	clipDir := filepath.Join(h.StoragePath, uploadID)
	if err := os.MkdirAll(clipDir, 0755); err != nil {
		log.Printf("ERROR: create clip dir: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	filename := "upload"
	if clip.Filename != nil {
		filename = *clip.Filename
	}
	finalPath := filepath.Join(clipDir, filename)

	out, err := os.Create(finalPath)
	if err != nil {
		log.Printf("ERROR: create final file: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	defer out.Close()

	sort.Ints(receivedParts)
	for _, partNum := range receivedParts {
		partPath := filepath.Join(partsDir, fmt.Sprintf("part_%d", partNum))
		partFile, err := os.Open(partPath)
		if err != nil {
			log.Printf("ERROR: open part %d: %v", partNum, err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
			return
		}
		if _, err := io.Copy(out, partFile); err != nil {
			partFile.Close()
			log.Printf("ERROR: copy part %d: %v", partNum, err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
			return
		}
		partFile.Close()
	}

	// Get final file size
	info, err := os.Stat(finalPath)
	if err != nil {
		log.Printf("ERROR: stat final file: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	// Update clip record
	if err := h.DB.UpdateClip(uploadID, "ready", info.Size(), finalPath); err != nil {
		log.Printf("ERROR: update clip: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	// Clean up parts directory
	os.RemoveAll(partsDir)

	// Re-read updated clip
	clip, _ = h.DB.GetClipByID(uploadID)

	c.JSON(http.StatusOK, clipToResponse(clip))
}

// GetUploadStatus handles GET /api/v1/uploads/:id/status
func (h *UploadHandler) GetUploadStatus(c *gin.Context) {
	uploadID := c.Param("id")

	clip, err := h.DB.GetClipByID(uploadID)
	if err != nil {
		log.Printf("ERROR: get clip: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	if clip == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "upload not found"})
		return
	}

	partsDir := filepath.Join(h.StoragePath, "uploads", uploadID)
	receivedParts, totalParts := h.getPartsInfo(partsDir, clip.SizeBytes)

	c.JSON(http.StatusOK, uploadStatusResponse{
		UploadID:      uploadID,
		ReceivedParts: receivedParts,
		TotalParts:    totalParts,
		Status:        clip.Status,
	})
}

// getPartsInfo reads the parts directory to determine which parts exist and the total expected.
// It uses the chunk size derived from the first part file size.
func (h *UploadHandler) getPartsInfo(partsDir string, totalSize int64) ([]int, int) {
	entries, err := os.ReadDir(partsDir)
	if err != nil {
		return []int{}, 0
	}

	var parts []int
	var chunkSize int64
	for _, e := range entries {
		var n int
		if _, err := fmt.Sscanf(e.Name(), "part_%d", &n); err == nil {
			parts = append(parts, n)
			if chunkSize == 0 {
				if info, err := e.Info(); err == nil {
					chunkSize = info.Size()
				}
			}
		}
	}

	totalParts := 0
	if chunkSize > 0 {
		totalParts = int(totalSize / chunkSize)
		if totalSize%chunkSize != 0 {
			totalParts++
		}
	}

	sort.Ints(parts)
	return parts, totalParts
}
