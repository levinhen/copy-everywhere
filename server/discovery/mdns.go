package discovery

import (
	"fmt"
	"log"
	"strconv"

	"github.com/hashicorp/mdns"
)

const (
	ServiceType = "_copyeverywhere._tcp"
	ServiceName = "CopyEverywhere"
)

// MDNSServer manages mDNS service advertisement.
type MDNSServer struct {
	server *mdns.Server
}

// Start registers an mDNS service on the given port with the provided TXT records.
// Returns a server that can be Shutdown() to deregister the service.
func Start(port int, version string, authEnabled bool) (*MDNSServer, error) {
	info := []string{
		fmt.Sprintf("version=%s", version),
		fmt.Sprintf("auth=%s", strconv.FormatBool(authEnabled)),
	}

	service, err := mdns.NewMDNSService(
		ServiceName,  // instance name
		ServiceType,  // service type
		"",           // domain (empty = .local)
		"",           // host (empty = hostname)
		port,         // port
		nil,          // IPs (nil = all interfaces)
		info,         // TXT records
	)
	if err != nil {
		return nil, fmt.Errorf("mdns: create service: %w", err)
	}

	server, err := mdns.NewServer(&mdns.Config{Zone: service})
	if err != nil {
		return nil, fmt.Errorf("mdns: start server: %w", err)
	}

	log.Printf("mDNS: advertising %s on port %d (version=%s, auth=%v)", ServiceType, port, version, authEnabled)
	return &MDNSServer{server: server}, nil
}

// Shutdown deregisters the mDNS service.
func (m *MDNSServer) Shutdown() {
	if m.server != nil {
		m.server.Shutdown()
		log.Println("mDNS: service deregistered")
	}
}
