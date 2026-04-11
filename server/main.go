package main

import (
	"fmt"
	"log"
	"time"

	"github.com/copy-everywhere/server/cleanup"
	"github.com/copy-everywhere/server/config"
	"github.com/copy-everywhere/server/db"
	"github.com/copy-everywhere/server/handlers"
	"github.com/copy-everywhere/server/middleware"
	"github.com/gin-gonic/gin"
)

var startTime time.Time

func init() {
	startTime = time.Now()
}

func main() {
	cfg := config.Load()

	database, err := db.Open(cfg.StoragePath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer database.Close()

	// Start TTL cleanup goroutine (every 10 minutes)
	cleanup.Start(database, cfg.StoragePath, 10*time.Minute)

	clipHandler := &handlers.ClipHandler{
		DB:            database,
		StoragePath:   cfg.StoragePath,
		MaxClipSizeMB: cfg.MaxClipSizeMB,
		TTLHours:      cfg.TTLHours,
	}

	uploadHandler := &handlers.UploadHandler{
		DB:            database,
		StoragePath:   cfg.StoragePath,
		MaxClipSizeMB: cfg.MaxClipSizeMB,
		TTLHours:      cfg.TTLHours,
	}

	deviceHandler := &handlers.DeviceHandler{
		DB: database,
	}

	r := gin.Default()

	// Health endpoint (no auth required)
	r.GET("/health", func(c *gin.Context) {
		resp := gin.H{
			"version": "0.1.0",
			"uptime":  time.Since(startTime).String(),
		}
		stats, err := database.GetStorageStats()
		if err != nil {
			log.Printf("ERROR: get storage stats: %v", err)
		} else {
			resp["storage_used_bytes"] = stats.StorageUsedBytes
			resp["clip_count"] = stats.ClipCount
		}
		c.JSON(200, resp)
	})

	// API routes with auth
	api := r.Group("/api/v1")
	api.Use(middleware.AuthRequired(cfg.AccessToken))
	{
		api.POST("/clips", clipHandler.Upload)
		api.GET("/clips/latest", clipHandler.GetLatest)
		api.GET("/clips/:id", clipHandler.GetByID)
		api.GET("/clips/:id/raw", clipHandler.GetRaw)

		api.POST("/uploads/init", uploadHandler.InitUpload)
		api.PUT("/uploads/:id/parts/:n", uploadHandler.UploadPart)
		api.POST("/uploads/:id/complete", uploadHandler.CompleteUpload)
		api.GET("/uploads/:id/status", uploadHandler.GetUploadStatus)

		api.POST("/devices/register", deviceHandler.Register)
		api.GET("/devices", deviceHandler.List)
	}

	addr := fmt.Sprintf(":%s", cfg.Port)
	log.Printf("CopyEverywhere server starting on %s (storage: %s, max_clip: %dMB, ttl: %dh)",
		addr, cfg.StoragePath, cfg.MaxClipSizeMB, cfg.TTLHours)

	if err := r.Run(addr); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
