package handlers

import (
	"net/http"

	"github.com/copy-everywhere/server/db"
	"github.com/gin-gonic/gin"
)

type DeviceHandler struct {
	DB *db.DB
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
