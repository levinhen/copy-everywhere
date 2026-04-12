package sse

import (
	"sync"
)

// ClipEvent is the payload sent over SSE when a targeted clip becomes ready.
type ClipEvent struct {
	ClipID    string `json:"clip_id"`
	Type      string `json:"type"`
	Filename  string `json:"filename"`
	SizeBytes int64  `json:"size_bytes"`
}

// Broker manages SSE subscribers keyed by device ID.
// Multiple connections per device are supported (fan-out).
type Broker struct {
	mu          sync.RWMutex
	subscribers map[string]map[chan ClipEvent]struct{}
}

// NewBroker creates a new SSE broker.
func NewBroker() *Broker {
	return &Broker{
		subscribers: make(map[string]map[chan ClipEvent]struct{}),
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
