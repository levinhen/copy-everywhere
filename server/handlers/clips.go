package handlers

import (
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/copy-everywhere/server/db"
	"github.com/gin-gonic/gin"
)

type ClipHandler struct {
	DB            *db.DB
	StoragePath   string
	MaxClipSizeMB int
	TTLHours      int
}

type clipResponse struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Filename  *string   `json:"filename"`
	SizeBytes int64     `json:"size_bytes"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

func clipToResponse(c *db.Clip) *clipResponse {
	return &clipResponse{
		ID:        c.ID,
		Type:      c.Type,
		Filename:  c.Filename,
		SizeBytes: c.SizeBytes,
		CreatedAt: c.CreatedAt,
		ExpiresAt: c.ExpiresAt,
	}
}

// Upload handles POST /api/v1/clips
func (h *ClipHandler) Upload(c *gin.Context) {
	clipType := c.PostForm("type")
	if clipType == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "type field is required"})
		return
	}
	if clipType != "text" && clipType != "image" && clipType != "file" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "type must be text, image, or file"})
		return
	}

	file, header, err := c.Request.FormFile("content")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "content file part is required"})
		return
	}
	defer file.Close()

	// Check size limit
	maxBytes := int64(h.MaxClipSizeMB) * 1024 * 1024
	if header.Size > maxBytes {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{
			"error": fmt.Sprintf("file size %d bytes exceeds maximum %d MB", header.Size, h.MaxClipSizeMB),
		})
		return
	}

	// Generate clip ID
	clipID, err := db.GenerateID()
	if err != nil {
		log.Printf("ERROR: generate clip ID: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	// Create storage directory
	clipDir := filepath.Join(h.StoragePath, clipID)
	if err := os.MkdirAll(clipDir, 0755); err != nil {
		log.Printf("ERROR: create clip dir: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	filename := header.Filename
	destPath := filepath.Join(clipDir, filename)

	// Write file to disk
	out, err := os.Create(destPath)
	if err != nil {
		log.Printf("ERROR: create file: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	defer out.Close()

	written, err := io.Copy(out, file)
	if err != nil {
		log.Printf("ERROR: write file: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	now := time.Now().UTC()
	clip := &db.Clip{
		ID:          clipID,
		Type:        clipType,
		Filename:    &filename,
		SizeBytes:   written,
		Status:      "ready",
		CreatedAt:   now,
		ExpiresAt:   now.Add(time.Duration(h.TTLHours) * time.Hour),
		StoragePath: destPath,
	}

	if err := h.DB.CreateClip(clip); err != nil {
		log.Printf("ERROR: create clip record: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	c.JSON(http.StatusCreated, clipToResponse(clip))
}

// GetByID handles GET /api/v1/clips/:id
func (h *ClipHandler) GetByID(c *gin.Context) {
	id := c.Param("id")

	clip, err := h.DB.GetClipByID(id)
	if err != nil {
		log.Printf("ERROR: get clip: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	if clip == nil || clip.ExpiresAt.Before(time.Now().UTC()) {
		c.JSON(http.StatusNotFound, gin.H{"error": "clip not found or expired"})
		return
	}

	c.JSON(http.StatusOK, clipToResponse(clip))
}

// GetLatest handles GET /api/v1/clips/latest
func (h *ClipHandler) GetLatest(c *gin.Context) {
	clip, err := h.DB.GetLatestClip()
	if err != nil {
		log.Printf("ERROR: get latest clip: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	if clip == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "no clips available"})
		return
	}

	c.JSON(http.StatusOK, clipToResponse(clip))
}

// GetRaw handles GET /api/v1/clips/:id/raw
func (h *ClipHandler) GetRaw(c *gin.Context) {
	id := c.Param("id")

	clip, err := h.DB.GetClipByID(id)
	if err != nil {
		log.Printf("ERROR: get clip: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}
	if clip == nil || clip.ExpiresAt.Before(time.Now().UTC()) {
		c.JSON(http.StatusNotFound, gin.H{"error": "clip not found or expired"})
		return
	}

	if clip.Status == "failed" {
		c.JSON(http.StatusForbidden, gin.H{"error": "upload incomplete - download unavailable"})
		return
	}

	// Determine content type
	contentType := "application/octet-stream"
	if clip.Filename != nil {
		ext := filepath.Ext(*clip.Filename)
		if mimeType := mime.TypeByExtension(ext); mimeType != "" {
			contentType = mimeType
		}
	}
	if clip.Type == "text" {
		contentType = "text/plain; charset=utf-8"
	}

	// Set headers
	c.Header("Content-Type", contentType)
	if clip.Filename != nil {
		c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, *clip.Filename))
	}

	c.File(clip.StoragePath)
}
