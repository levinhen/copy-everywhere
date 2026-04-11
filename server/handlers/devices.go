package handlers

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/copy-everywhere/server/db"
	"github.com/copy-everywhere/server/sse"
	"github.com/gin-gonic/gin"
)

type DeviceHandler struct {
	DB     *db.DB
	Broker *sse.Broker
}

type registerRequest struct {
	Name     string `json:"name" binding:"required"`
	Platform string `json:"platform" binding:"required"`
}

func (h *DeviceHandler) Register(c *gin.Context) {
	var req registerRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "name and platform are required"})
		return
	}

	if req.Platform != "macos" && req.Platform != "windows" && req.Platform != "linux" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "platform must be macos, windows, or linux"})
		return
	}

	device, err := h.DB.RegisterDevice(req.Name, req.Platform)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to register device"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"device_id": device.ID})
}

func (h *DeviceHandler) List(c *gin.Context) {
	devices, err := h.DB.ListDevices()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to list devices"})
		return
	}

	if devices == nil {
		devices = []*db.Device{}
	}

	c.JSON(http.StatusOK, devices)
}

// Stream handles GET /api/v1/devices/:id/stream — Server-Sent Events for targeted clips.
func (h *DeviceHandler) Stream(c *gin.Context) {
	deviceID := c.Param("id")

	// Set SSE headers
	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache")
	c.Header("Connection", "keep-alive")

	// Subscribe to events for this device
	ch := h.Broker.Subscribe(deviceID)
	defer h.Broker.Unsubscribe(deviceID, ch)

	// Get the underlying flusher
	flusher, ok := c.Writer.(http.Flusher)
	if !ok {
		log.Printf("ERROR: SSE client does not support flushing")
		c.JSON(http.StatusInternalServerError, gin.H{"error": "streaming not supported"})
		return
	}

	// Use client disconnect context
	ctx := c.Request.Context()

	// Send initial comment to confirm connection
	fmt.Fprintf(c.Writer, ": connected\n\n")
	flusher.Flush()

	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()

	eventID := 0

	for {
		select {
		case <-ctx.Done():
			return
		case event := <-ch:
			eventID++
			data, _ := json.Marshal(event)
			fmt.Fprintf(c.Writer, "id: %d\n", eventID)
			fmt.Fprintf(c.Writer, "event: clip\n")
			fmt.Fprintf(c.Writer, "data: %s\n\n", data)
			flusher.Flush()
		case <-heartbeat.C:
			_, err := io.WriteString(c.Writer, ": heartbeat\n\n")
			if err != nil {
				return
			}
			flusher.Flush()
		}
	}
}
