package main

import (
	"fmt"
	"log"
	"time"

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

	clipHandler := &handlers.ClipHandler{
		DB:            database,
		StoragePath:   cfg.StoragePath,
		MaxClipSizeMB: cfg.MaxClipSizeMB,
		TTLHours:      cfg.TTLHours,
	}

	r := gin.Default()

	// Health endpoint (no auth required)
	r.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"version": "0.1.0",
			"uptime":  time.Since(startTime).String(),
		})
	})

	// API routes with auth
	api := r.Group("/api/v1")
	api.Use(middleware.AuthRequired(cfg.AccessToken))
	{
		api.POST("/clips", clipHandler.Upload)
		api.GET("/clips/latest", clipHandler.GetLatest)
		api.GET("/clips/:id", clipHandler.GetByID)
		api.GET("/clips/:id/raw", clipHandler.GetRaw)
	}

	addr := fmt.Sprintf(":%s", cfg.Port)
	log.Printf("CopyEverywhere server starting on %s (storage: %s, max_clip: %dMB, ttl: %dh)",
		addr, cfg.StoragePath, cfg.MaxClipSizeMB, cfg.TTLHours)

	if err := r.Run(addr); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
