package sse

import (
	"sync"
	"time"
)

// ClipEvent is the payload sent over SSE when a targeted clip becomes ready.
type ClipEvent struct {
	ClipID    string `json:"clip_id"`
	Type      string `json:"type"`
	Filename  string `json:"filename"`
	SizeBytes int64  `json:"size_bytes"`
}

type ReceiverStatus string

const (
	ReceiverStatusOnline   ReceiverStatus = "online"
	ReceiverStatusDegraded ReceiverStatus = "degraded"
	ReceiverStatusOffline  ReceiverStatus = "offline"
)

type receiverPresence struct {
	activeSubscribers int
	lastHeartbeatAt   time.Time
}

// Broker manages SSE subscribers keyed by device ID.
// Multiple connections per device are supported (fan-out).
type Broker struct {
	mu          sync.RWMutex
	subscribers map[string]map[chan ClipEvent]struct{}
	presence    map[string]receiverPresence
	now         func() time.Time
	onlineTTL   time.Duration
}

// NewBroker creates a new SSE broker.
func NewBroker() *Broker {
	return NewBrokerWithPresenceTTL(time.Now, 35*time.Second)
}

// NewBrokerWithPresenceTTL creates a broker with a custom clock and online TTL.
// Production code should normally use NewBroker; tests can shorten the TTL.
func NewBrokerWithPresenceTTL(now func() time.Time, onlineTTL time.Duration) *Broker {
	return &Broker{
		subscribers: make(map[string]map[chan ClipEvent]struct{}),
		presence:    make(map[string]receiverPresence),
		now:         now,
		onlineTTL:   onlineTTL,
	}
}

// Subscribe registers a new channel for the given device ID and returns it.
// The caller must call Unsubscribe when done.
func (b *Broker) Subscribe(deviceID string) chan ClipEvent {
	ch := make(chan ClipEvent, 16)
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.subscribers[deviceID] == nil {
		b.subscribers[deviceID] = make(map[chan ClipEvent]struct{})
	}
	b.subscribers[deviceID][ch] = struct{}{}
	presence := b.presence[deviceID]
	presence.activeSubscribers++
	presence.lastHeartbeatAt = b.now().UTC()
	b.presence[deviceID] = presence
	return ch
}

// Unsubscribe removes and closes a subscriber channel.
func (b *Broker) Unsubscribe(deviceID string, ch chan ClipEvent) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if subs, ok := b.subscribers[deviceID]; ok {
		delete(subs, ch)
		if len(subs) == 0 {
			delete(b.subscribers, deviceID)
		}
	}
	if presence, ok := b.presence[deviceID]; ok {
		presence.activeSubscribers--
		if presence.activeSubscribers <= 0 {
			delete(b.presence, deviceID)
		} else {
			b.presence[deviceID] = presence
		}
	}
	close(ch)
}

// Notify sends a ClipEvent to all subscribers for the given device ID.
// Non-blocking: if a subscriber's channel is full, the event is dropped for that subscriber.
func (b *Broker) Notify(deviceID string, event ClipEvent) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if subs, ok := b.subscribers[deviceID]; ok {
		for ch := range subs {
			select {
			case ch <- event:
			default:
				// Drop if subscriber is slow
			}
		}
	}
}

// MarkAlive refreshes a device's SSE presence after a successful stream write.
func (b *Broker) MarkAlive(deviceID string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if presence, ok := b.presence[deviceID]; ok && presence.activeSubscribers > 0 {
		presence.lastHeartbeatAt = b.now().UTC()
		b.presence[deviceID] = presence
	}
}

// ReceiverStatus reports whether a device currently has an online, degraded,
// or offline auto-receive channel based on active SSE presence freshness.
func (b *Broker) ReceiverStatus(deviceID string) ReceiverStatus {
	return b.receiverStatusAt(deviceID, b.now().UTC())
}

func (b *Broker) receiverStatusAt(deviceID string, now time.Time) ReceiverStatus {
	b.mu.RLock()
	defer b.mu.RUnlock()

	presence, ok := b.presence[deviceID]
	if !ok || presence.activeSubscribers <= 0 {
		return ReceiverStatusOffline
	}
	if now.Sub(presence.lastHeartbeatAt) <= b.onlineTTL {
		return ReceiverStatusOnline
	}
	return ReceiverStatusDegraded
}
