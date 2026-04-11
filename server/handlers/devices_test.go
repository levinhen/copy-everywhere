package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/copy-everywhere/server/db"
	"github.com/gin-gonic/gin"
)

func setupDeviceTestHandler(t *testing.T) (*DeviceHandler, *gin.Engine) {
	t.Helper()
	tmpDir := t.TempDir()

	database, err := db.Open(tmpDir)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { database.Close() })

	h := &DeviceHandler{DB: database}

	r := gin.New()
	api := r.Group("/api/v1")
	api.POST("/devices/register", h.Register)
	api.GET("/devices", h.List)

	return h, r
}

func TestRegisterDevice(t *testing.T) {
	_, r := setupDeviceTestHandler(t)

	body, _ := json.Marshal(map[string]string{
		"name":     "My Mac",
		"platform": "macos",
	})
	req := httptest.NewRequest("POST", "/api/v1/devices/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	deviceID := resp["device_id"]
	if len(deviceID) != 8 {
		t.Fatalf("expected 8-char device id, got %d: %s", len(deviceID), deviceID)
	}
}

func TestRegisterDeviceIdempotent(t *testing.T) {
	_, r := setupDeviceTestHandler(t)

	body, _ := json.Marshal(map[string]string{
		"name":     "My Mac",
		"platform": "macos",
	})

	// First registration
	req := httptest.NewRequest("POST", "/api/v1/devices/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	var resp1 map[string]string
	json.Unmarshal(w.Body.Bytes(), &resp1)

	// Second registration — same name+platform
	req = httptest.NewRequest("POST", "/api/v1/devices/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp2 map[string]string
	json.Unmarshal(w.Body.Bytes(), &resp2)

	if resp1["device_id"] != resp2["device_id"] {
		t.Fatalf("expected same device_id on re-register, got %s vs %s", resp1["device_id"], resp2["device_id"])
	}
}

func TestRegisterDeviceMissingFields(t *testing.T) {
	_, r := setupDeviceTestHandler(t)

	// Missing platform
	body, _ := json.Marshal(map[string]string{"name": "Mac"})
	req := httptest.NewRequest("POST", "/api/v1/devices/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestRegisterDeviceInvalidPlatform(t *testing.T) {
	_, r := setupDeviceTestHandler(t)

	body, _ := json.Marshal(map[string]string{
		"name":     "Phone",
		"platform": "android",
	})
	req := httptest.NewRequest("POST", "/api/v1/devices/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestListDevices(t *testing.T) {
	h, r := setupDeviceTestHandler(t)

	// Empty list
	req := httptest.NewRequest("GET", "/api/v1/devices", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var empty []db.Device
	json.Unmarshal(w.Body.Bytes(), &empty)
	if len(empty) != 0 {
		t.Fatalf("expected 0 devices, got %d", len(empty))
	}

	// Register two devices
	h.DB.RegisterDevice("Mac", "macos")
	h.DB.RegisterDevice("PC", "windows")

	req = httptest.NewRequest("GET", "/api/v1/devices", nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var devices []db.Device
	json.Unmarshal(w.Body.Bytes(), &devices)
	if len(devices) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(devices))
	}
}

func TestListDevicesResponseShape(t *testing.T) {
	h, r := setupDeviceTestHandler(t)

	h.DB.RegisterDevice("Mac", "macos")

	req := httptest.NewRequest("GET", "/api/v1/devices", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	var devices []map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &devices)

	if len(devices) != 1 {
		t.Fatalf("expected 1 device, got %d", len(devices))
	}

	dev := devices[0]
	for _, key := range []string{"device_id", "name", "platform", "last_seen_at"} {
		if _, ok := dev[key]; !ok {
			t.Fatalf("expected key %s in response", key)
		}
	}
}
