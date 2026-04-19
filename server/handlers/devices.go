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

type deviceResponse struct {
	ID             string    `json:"device_id"`
	Name           string    `json:"name"`
	Platform       string    `json:"platform"`
	LastSeenAt     time.Time `json:"last_seen_at"`
	CreatedAt      time.Time `json:"created_at"`
	ReceiverStatus string    `json:"receiver_status"`
}

func clipToEvent(clip *db.Clip) sse.ClipEvent {
	filename := ""
	if clip.Filename != nil {
		filename = *clip.Filename
	}
	return sse.ClipEvent{
		ClipID:    clip.ID,
		Type:      clip.Type,
		Filename:  filename,
		SizeBytes: clip.SizeBytes,
	}
}

func (h *DeviceHandler) Register(c *gin.Context) {
	var req registerRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "name and platform are required"})
		return
	}

	if req.Platform != "macos" && req.Platform != "windows" && req.Platform != "linux" && req.Platform != "android" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "platform must be macos, windows, linux, or android"})
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
		c.JSON(http.StatusOK, []deviceResponse{})
		return
	}

	response := make([]deviceResponse, 0, len(devices))
	for _, device := range devices {
		status := sse.ReceiverStatusOffline
		if h.Broker != nil {
			status = h.Broker.ReceiverStatus(device.ID)
		}
		response = append(response, deviceResponse{
			ID:             device.ID,
			Name:           device.Name,
			Platform:       device.Platform,
			LastSeenAt:     device.LastSeenAt,
			CreatedAt:      device.CreatedAt,
			ReceiverStatus: string(status),
		})
	}

	c.JSON(http.StatusOK, response)
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
	eventID := 0

	pending, err := h.DB.ListPendingTargetedClips(deviceID)
	if err != nil {
		log.Printf("ERROR: list pending targeted clips for replay: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal server error"})
		return
	}

	// Send initial comment to confirm connection
	fmt.Fprintf(c.Writer, ": connected\n\n")
	flusher.Flush()
	h.Broker.MarkAlive(deviceID)
	log.Printf("SSE: device %s connected", deviceID)
	for _, clip := range pending {
		eventID++
		event := clipToEvent(clip)
		data, _ := json.Marshal(event)
		fmt.Fprintf(c.Writer, "id: %d\n", eventID)
		fmt.Fprintf(c.Writer, "event: clip\n")
		fmt.Fprintf(c.Writer, "data: %s\n\n", data)
		flusher.Flush()
		h.Broker.MarkAlive(deviceID)
		log.Printf("TARGETED: replayed pending clip %s to device %s on SSE connect", clip.ID, deviceID)
	}

	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("SSE: device %s disconnected", deviceID)
			return
		case event := <-ch:
			eventID++
			data, _ := json.Marshal(event)
			fmt.Fprintf(c.Writer, "id: %d\n", eventID)
			fmt.Fprintf(c.Writer, "event: clip\n")
			fmt.Fprintf(c.Writer, "data: %s\n\n", data)
			flusher.Flush()
			h.Broker.MarkAlive(deviceID)
		case <-heartbeat.C:
			_, err := io.WriteString(c.Writer, ": heartbeat\n\n")
			if err != nil {
				log.Printf("SSE: device %s heartbeat write failed: %v", deviceID, err)
				return
			}
			flusher.Flush()
			h.Broker.MarkAlive(deviceID)
		}
	}
}
