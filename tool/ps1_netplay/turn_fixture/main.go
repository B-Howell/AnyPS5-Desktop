package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"time"

	"github.com/pion/turn/v4"
)

func main() {
	const (
		user     = "anyps5-probe"
		password = "loopback-fixture"
		realm    = "anyps5-loopback"
	)
	bind := flag.String("address", "127.0.0.1", "IPv4 address of the test adapter")
	flag.Parse()
	address := net.ParseIP(*bind)
	if address == nil || address.To4() == nil || !(address.IsLoopback() || address.IsPrivate()) {
		log.Fatal("A loopback or private IPv4 address is required")
	}
	listener, err := net.ListenPacket("udp4", net.JoinHostPort(address.String(), "0"))
	if err != nil {
		log.Fatal(err)
	}
	server, err := turn.NewServer(turn.ServerConfig{
		Realm: realm,
		AuthHandler: func(username, requestedRealm string, source net.Addr) ([]byte, bool) {
			endpoint, ok := source.(*net.UDPAddr)
			if !ok || username != user || requestedRealm != realm || !endpoint.IP.Equal(address) {
				log.Print("rejected TURN authentication")
				return nil, false
			}
			log.Print("accepted TURN authentication")
			return turn.GenerateAuthKey(user, realm, password), true
		},
		PacketConnConfigs: []turn.PacketConnConfig{{
			PacketConn: listener,
			RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{
				RelayAddress: address,
				Address:      address.String(),
			},
			PermissionHandler: func(_ net.Addr, peer net.IP) bool {
				return peer.Equal(address)
			},
		}},
	})
	if err != nil {
		log.Fatal(err)
	}
	defer server.Close()
	fmt.Println(listener.LocalAddr().(*net.UDPAddr).Port)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	last := 0
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			if allocations := server.AllocationCount(); allocations != last {
				log.Printf("TURN allocations: %d", allocations)
				last = allocations
			}
		}
	}
}
