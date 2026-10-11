package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net/netip"
	"sync"
	"time"

	"golang.getoutline.org/sdk/network/packetrelay"
	"golang.getoutline.org/sdk/transport"
)

type udpRelay struct {
	dialer  localDialer
	context context.Context
}

// Outline 的一个 UDP 来源可访问多个目标；每个来源/目标对独立使用一条 CONNECT。
func (r udpRelay) NewAssociation() (packetrelay.PacketSender, packetrelay.PacketReceiver, error) {
	ctx, cancel := context.WithCancel(r.context)
	a := &udpAssociation{dialer: r.dialer, context: ctx, cancel: cancel, peers: make(map[netip.AddrPort]*udpPeer), packets: make(chan receivedPacket, 32)}
	context.AfterFunc(ctx, func() { a.Close() })
	return a, a, nil
}

type receivedPacket struct {
	data   []byte
	source netip.AddrPort
}
type udpPeer struct {
	conn transport.StreamConn
	mu   sync.Mutex
}
type udpAssociation struct {
	dialer  localDialer
	context context.Context
	cancel  context.CancelFunc
	mu      sync.Mutex
	peers   map[netip.AddrPort]*udpPeer
	packets chan receivedPacket
}

func (a *udpAssociation) SendPacket(data []byte, target netip.AddrPort) error {
	if len(data) > maxPacket || !target.IsValid() || target.Port() == 0 {
		return fmt.Errorf("UDP 目标或报文长度无效")
	}
	a.mu.Lock()
	if a.context.Err() != nil {
		a.mu.Unlock()
		return packetrelay.ErrClosed
	}
	peer := a.peers[target]
	if peer == nil {
		if len(a.peers) >= 64 {
			a.mu.Unlock()
			return fmt.Errorf("UDP 来源的目标数量超过上限")
		}
		conn, err := a.dialer.connect(a.context, target.String(), true)
		if err != nil {
			a.mu.Unlock()
			return err
		}
		peer = &udpPeer{conn: conn}
		a.peers[target] = peer
		go a.receive(peer, target)
	}
	a.mu.Unlock()
	peer.mu.Lock()
	defer peer.mu.Unlock()
	frame := make([]byte, len(data)+2)
	binary.BigEndian.PutUint16(frame, uint16(len(data)))
	copy(frame[2:], data)
	peer.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err := io.Copy(peer.conn, bytes.NewReader(frame))
	if err != nil {
		peer.conn.Close()
	}
	return err
}

func (a *udpAssociation) receive(peer *udpPeer, target netip.AddrPort) {
	defer func() {
		peer.conn.Close()
		a.mu.Lock()
		if a.peers[target] == peer {
			delete(a.peers, target)
		}
		a.mu.Unlock()
	}()
	var prefix [2]byte
	for {
		if _, err := io.ReadFull(peer.conn, prefix[:]); err != nil {
			return
		}
		size := int(binary.BigEndian.Uint16(prefix[:]))
		if size > maxPacket {
			return
		}
		data := make([]byte, size)
		if _, err := io.ReadFull(peer.conn, data); err != nil {
			return
		}
		select {
		case a.packets <- receivedPacket{data, target}:
		case <-a.context.Done():
			return
		}
	}
}

func (a *udpAssociation) ReceivePackets(handler packetrelay.PacketHandler) error {
	for {
		select {
		case packet := <-a.packets:
			if err := handler.HandlePacket(packet.data, packet.source); err != nil {
				a.Close()
				return err
			}
		case <-a.context.Done():
			return packetrelay.ErrClosed
		}
	}
}
func (a *udpAssociation) Close() error {
	a.cancel()
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, peer := range a.peers {
		peer.conn.Close()
	}
	return nil
}
