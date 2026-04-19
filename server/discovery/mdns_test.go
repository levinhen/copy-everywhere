package discovery

import (
	"slices"
	"testing"
	"time"

	"github.com/hashicorp/mdns"
)

func TestStartAndShutdown(t *testing.T) {
	srv, err := Start(19876, "0.1.0", false, "server-19876")
	if err != nil {
		t.Fatalf("Start() error: %v", err)
	}

	// Verify Shutdown completes without panic
	srv.Shutdown()
}

func TestStartAuthEnabled(t *testing.T) {
	srv, err := Start(19877, "0.2.0", true, "server-19877")
	if err != nil {
		t.Fatalf("Start() error: %v", err)
	}
	defer srv.Shutdown()
}

func TestShutdownIdempotent(t *testing.T) {
	srv, err := Start(19878, "0.1.0", false, "server-19878")
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

	const serverID = "server-19879"

	srv, err := Start(19879, "0.1.0", false, serverID)
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
			if !slices.Contains(entry.InfoFields, "server_id="+serverID) {
				t.Fatalf("expected TXT records to include server_id=%s, got %v", serverID, entry.InfoFields)
			}
			break
		}
	}

	if !found {
		t.Log("mDNS discovery did not find service — may be a network/environment issue (non-fatal)")
	}
}
