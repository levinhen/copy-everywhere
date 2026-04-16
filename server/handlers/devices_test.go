package handlers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/copy-everywhere/server/db"
	"github.com/copy-everywhere/server/sse"
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

	broker := sse.NewBroker()
	h := &DeviceHandler{DB: database, Broker: broker}

	r := gin.New()
	api := r.Group("/api/v1")
	api.POST("/devices/register", h.Register)
	api.GET("/devices", h.List)
	api.GET("/devices/:id/stream", h.Stream)

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
		"platform": "ios",
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

func TestStreamSSEHeaders(t *testing.T) {
	_, r := setupDeviceTestHandler(t)

	// Use a real HTTP server so SSE streaming works properly
	srv := httptest.NewServer(r)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/api/v1/devices/dev123/stream", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	ct := resp.Header.Get("Content-Type")
	if !strings.Contains(ct, "text/event-stream") {
		t.Fatalf("expected text/event-stream content type, got %s", ct)
	}

	// Read the initial comment
	scanner := bufio.NewScanner(resp.Body)
	if scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, "connected") {
			t.Fatalf("expected connected comment, got: %s", line)
		}
	}
}

func TestStreamSSEReceivesClipEvent(t *testing.T) {
	h, r := setupDeviceTestHandler(t)

	srv := httptest.NewServer(r)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/api/v1/devices/dev456/stream", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()

	// Wait a bit for the subscriber to register, then send an event
	time.Sleep(100 * time.Millisecond)
	h.Broker.Notify("dev456", sse.ClipEvent{
		ClipID:    "abc123",
		Type:      "text",
		Filename:  "clipboard.txt",
		SizeBytes: 42,
	})

	// Read SSE lines until we find the data line
	scanner := bufio.NewScanner(resp.Body)
	var dataLine string
	deadline := time.After(3 * time.Second)
	done := make(chan struct{})

	go func() {
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "data: ") {
				dataLine = strings.TrimPrefix(line, "data: ")
				close(done)
				return
			}
		}
	}()

	select {
	case <-done:
	case <-deadline:
		t.Fatal("timed out waiting for SSE data line")
	}

	var event sse.ClipEvent
	if err := json.Unmarshal([]byte(dataLine), &event); err != nil {
		t.Fatalf("unmarshal event: %v", err)
	}

	if event.ClipID != "abc123" {
		t.Fatalf("expected clip_id abc123, got %s", event.ClipID)
	}
	if event.Type != "text" {
		t.Fatalf("expected type text, got %s", event.Type)
	}
	if event.SizeBytes != 42 {
		t.Fatalf("expected size_bytes 42, got %d", event.SizeBytes)
	}
}

func TestStreamSSEMultipleSubscribers(t *testing.T) {
	h, r := setupDeviceTestHandler(t)

	srv := httptest.NewServer(r)
	defer srv.Close()

	ctx1, cancel1 := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel1()
	ctx2, cancel2 := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel2()

	req1, _ := http.NewRequestWithContext(ctx1, "GET", srv.URL+"/api/v1/devices/devMulti/stream", nil)
	req2, _ := http.NewRequestWithContext(ctx2, "GET", srv.URL+"/api/v1/devices/devMulti/stream", nil)

	resp1, err := http.DefaultClient.Do(req1)
	if err != nil {
		t.Fatalf("request 1: %v", err)
	}
	defer resp1.Body.Close()

	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("request 2: %v", err)
	}
	defer resp2.Body.Close()

	time.Sleep(100 * time.Millisecond)

	h.Broker.Notify("devMulti", sse.ClipEvent{
		ClipID:    "xyz789",
		Type:      "file",
		Filename:  "test.pdf",
		SizeBytes: 1024,
	})

	// Both subscribers should receive the event
	readEvent := func(resp *http.Response) string {
		scanner := bufio.NewScanner(resp.Body)
		ch := make(chan string, 1)
		go func() {
			for scanner.Scan() {
				line := scanner.Text()
				if strings.HasPrefix(line, "data: ") {
					ch <- strings.TrimPrefix(line, "data: ")
					return
				}
			}
		}()
		select {
		case data := <-ch:
			return data
		case <-time.After(3 * time.Second):
			t.Fatal("timed out waiting for event")
			return ""
		}
	}

	data1 := readEvent(resp1)
	data2 := readEvent(resp2)

	var ev1, ev2 sse.ClipEvent
	json.Unmarshal([]byte(data1), &ev1)
	json.Unmarshal([]byte(data2), &ev2)

	if ev1.ClipID != "xyz789" || ev2.ClipID != "xyz789" {
		t.Fatalf("both subscribers should receive event, got %s and %s", ev1.ClipID, ev2.ClipID)
	}
}

func TestStreamSSEUntargetedDoesNotPush(t *testing.T) {
	h, r := setupDeviceTestHandler(t)

	srv := httptest.NewServer(r)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/api/v1/devices/devNoTarget/stream", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()

	time.Sleep(100 * time.Millisecond)

	// Notify a DIFFERENT device — should not be received
	h.Broker.Notify("otherDevice", sse.ClipEvent{
		ClipID:    "nope",
		Type:      "text",
		Filename:  "clipboard.txt",
		SizeBytes: 10,
	})

	// Try to read — should time out with no data event
	scanner := bufio.NewScanner(resp.Body)
	gotData := make(chan bool, 1)
	go func() {
		for scanner.Scan() {
			if strings.HasPrefix(scanner.Text(), "data: ") {
				gotData <- true
				return
			}
		}
		gotData <- false
	}()

	select {
	case got := <-gotData:
		if got {
			t.Fatal("should NOT have received an event for a different device")
		}
	case <-time.After(500 * time.Millisecond):
		// Good — no event received
	}
}
