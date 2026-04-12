package sse

import (
	"sync"
	"testing"
	"time"
)

func TestSubscribeAndNotify(t *testing.T) {
	b := NewBroker()
	ch := b.Subscribe("dev1")
	defer b.Unsubscribe("dev1", ch)

	b.Notify("dev1", ClipEvent{ClipID: "abc", Type: "text", Filename: "clipboard.txt", SizeBytes: 10})

	select {
	case ev := <-ch:
		if ev.ClipID != "abc" {
			t.Fatalf("expected abc, got %s", ev.ClipID)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for event")
	}
}

func TestNotifyDifferentDevice(t *testing.T) {
	b := NewBroker()
	ch := b.Subscribe("dev1")
	defer b.Unsubscribe("dev1", ch)

	b.Notify("dev2", ClipEvent{ClipID: "abc"})

	select {
	case <-ch:
		t.Fatal("should not receive event for different device")
	case <-time.After(100 * time.Millisecond):
		// Good
	}
}

func TestMultipleSubscribers(t *testing.T) {
	b := NewBroker()
	ch1 := b.Subscribe("dev1")
	ch2 := b.Subscribe("dev1")
	defer b.Unsubscribe("dev1", ch1)
	defer b.Unsubscribe("dev1", ch2)

	b.Notify("dev1", ClipEvent{ClipID: "abc"})

	for i, ch := range []chan ClipEvent{ch1, ch2} {
		select {
		case ev := <-ch:
			if ev.ClipID != "abc" {
				t.Fatalf("subscriber %d: expected abc, got %s", i, ev.ClipID)
			}
		case <-time.After(time.Second):
			t.Fatalf("subscriber %d: timed out", i)
		}
	}
}

func TestUnsubscribeRemoves(t *testing.T) {
	b := NewBroker()
	ch := b.Subscribe("dev1")
	b.Unsubscribe("dev1", ch)

	// Channel should be closed
	_, open := <-ch
	if open {
		t.Fatal("expected channel to be closed after unsubscribe")
	}

	// Map should be cleaned up
	b.mu.RLock()
	_, exists := b.subscribers["dev1"]
	b.mu.RUnlock()
	if exists {
		t.Fatal("expected device entry to be cleaned up")
	}
}

func TestConcurrentNotify(t *testing.T) {
	b := NewBroker()
	ch := b.Subscribe("dev1")
	defer b.Unsubscribe("dev1", ch)

	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			b.Notify("dev1", ClipEvent{ClipID: "abc"})
		}()
	}
	wg.Wait()

	// Drain the channel — should have received some events (buffer is 16, extras dropped)
	count := 0
	for {
		select {
		case <-ch:
			count++
		default:
			goto done
		}
	}
done:
	if count == 0 {
		t.Fatal("expected at least some events")
	}
	if count > 16 {
		t.Fatalf("expected at most 16 (buffer size), got %d", count)
	}
}
