package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/copy-everywhere/server/cleanup"
	"github.com/copy-everywhere/server/config"
	"github.com/copy-everywhere/server/db"
	"github.com/copy-everywhere/server/discovery"
	"github.com/copy-everywhere/server/handlers"
	"github.com/copy-everywhere/server/middleware"
	"github.com/copy-everywhere/server/sse"
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

	// Start cleanup goroutine (expired + consumed clips)
	cleanup.Start(database, cfg.StoragePath, time.Duration(cfg.CleanupIntervalSeconds)*time.Second)

	broker := sse.NewBroker()

	clipHandler := &handlers.ClipHandler{
		DB:            database,
		StoragePath:   cfg.StoragePath,
		MaxClipSizeMB: cfg.MaxClipSizeMB,
		TTLHours:      cfg.TTLHours,
		Broker:        broker,
	}

	uploadHandler := &handlers.UploadHandler{
		DB:            database,
		StoragePath:   cfg.StoragePath,
		MaxClipSizeMB: cfg.MaxClipSizeMB,
		TTLHours:      cfg.TTLHours,
		Broker:        broker,
	}

	deviceHandler := &handlers.DeviceHandler{
		DB:     database,
		Broker: broker,
	}

	r := gin.Default()

	// Health endpoint (no auth required)
	r.GET("/health", func(c *gin.Context) {
		resp := gin.H{
			"version": "0.1.0",
			"uptime":  time.Since(startTime).String(),
			"auth":    cfg.AuthEnabled,
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

	// API routes — auth is opt-in via AUTH_ENABLED
	api := r.Group("/api/v1")
	if cfg.AuthEnabled {
		api.Use(middleware.AuthRequired(cfg.AccessToken))
	}
	{
		api.POST("/clips", clipHandler.Upload)
		api.GET("/clips", clipHandler.ListQueue)
		api.GET("/clips/latest", clipHandler.GetLatest)
		api.GET("/clips/:id", clipHandler.GetByID)
		api.GET("/clips/:id/raw", clipHandler.GetRaw)

		api.POST("/uploads/init", uploadHandler.InitUpload)
		api.PUT("/uploads/:id/parts/:n", uploadHandler.UploadPart)
		api.POST("/uploads/:id/complete", uploadHandler.CompleteUpload)
		api.GET("/uploads/:id/status", uploadHandler.GetUploadStatus)

		api.POST("/devices/register", deviceHandler.Register)
		api.GET("/devices", deviceHandler.List)
		api.GET("/devices/:id/stream", deviceHandler.Stream)
	}

	addr := fmt.Sprintf(":%s", cfg.Port)
	log.Printf("CopyEverywhere server starting on %s (storage: %s, max_clip: %dMB, ttl: %dh)",
		addr, cfg.StoragePath, cfg.MaxClipSizeMB, cfg.TTLHours)

	// Start mDNS service advertisement
	port, _ := strconv.Atoi(cfg.Port)
	mdnsSrv, err := discovery.Start(port, "0.1.0", cfg.AuthEnabled)
	if err != nil {
		log.Printf("WARNING: mDNS advertisement failed: %v", err)
	} else {
		// Deregister mDNS on shutdown
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		go func() {
			<-sigCh
			mdnsSrv.Shutdown()
			os.Exit(0)
		}()
	}

	if err := r.Run(addr); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
