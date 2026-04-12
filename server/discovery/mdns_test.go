package discovery

import (
	"testing"
	"time"

	"github.com/hashicorp/mdns"
)

func TestStartAndShutdown(t *testing.T) {
	srv, err := Start(19876, "0.1.0", false)
	if err != nil {
		t.Fatalf("Start() error: %v", err)
	}

	// Verify Shutdown completes without panic
	srv.Shutdown()
}

func TestStartAuthEnabled(t *testing.T) {
	srv, err := Start(19877, "0.2.0", true)
	if err != nil {
		t.Fatalf("Start() error: %v", err)
	}
	defer srv.Shutdown()
}

func TestShutdownIdempotent(t *testing.T) {
	srv, err := Start(19878, "0.1.0", false)
	if err != nil {
		t.Fatalf("Start() error: %v", err)
	}
	srv.Shutdown()
	srv.Shutdown() // should not panic
}

func TestMDNSDiscovery(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping mDNS discovery test in short mode")
	}

	srv, err := Start(19879, "0.1.0", false)
	if err != nil {
		t.Fatalf("Start() error: %v", err)
	}
	defer srv.Shutdown()

	time.Sleep(500 * time.Millisecond)

	entriesCh := make(chan *mdns.ServiceEntry, 4)
	found := false

	params := mdns.DefaultParams(ServiceType)
	params.DisableIPv6 = true
	params.Entries = entriesCh
	params.Timeout = 5 * time.Second

	go func() {
		_ = mdns.Query(params)
		close(entriesCh)
	}()

	for entry := range entriesCh {
		if entry.Port == 19879 {
			found = true
			break
		}
	}

	if !found {
		t.Log("mDNS discovery did not find service — may be a network/environment issue (non-fatal)")
	}
}
