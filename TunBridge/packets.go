package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
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
	return a, a, nil
}

type receivedPacket struct {
	data   []byte
	source netip.AddrPort
}
type udpPeer struct {
	conn     transport.StreamConn
	context  context.Context
	cancel   context.CancelFunc
	outgoing chan []byte
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
	defer a.mu.Unlock()
	if a.context.Err() != nil {
		return packetrelay.ErrClosed
	}
	peer := a.peers[target]
	if peer == nil {
		if len(a.peers) >= 64 {
			// 丢弃超额目标的报文，不让一个来源拖垮其他目标。
			return nil
		}
		ctx, cancel := context.WithCancel(a.context)
		peer = &udpPeer{context: ctx, cancel: cancel, outgoing: make(chan []byte, 32)}
		a.peers[target] = peer
		go a.send(peer, target)
	}
	// 此方法由 lwIP 输入回调调用，不能等待 CONNECT 或套接字写入。
	// 每个目标独立排队，队列满时丢包；必须复制协议栈会复用的输入缓冲区。
	select {
	case peer.outgoing <- append([]byte{}, data...):
	default:
	}
	return nil
}

func (a *udpAssociation) send(peer *udpPeer, target netip.AddrPort) {
	defer func() {
		peer.cancel()
		a.mu.Lock()
		if a.peers[target] == peer {
			delete(a.peers, target)
		}
		a.mu.Unlock()
	}()
	conn, err := a.dialer.connect(peer.context, target.String(), true)
	if err != nil {
		if peer.context.Err() == nil {
			log.Printf("UDP 目标连接失败：目标=%s，原因=%v", target, err)
		}
		return
	}
	peer.conn = conn
	defer conn.Close()
	stop := context.AfterFunc(peer.context, func() { conn.Close() })
	defer stop()
	go a.receive(peer, target)
	for {
		select {
		case <-peer.context.Done():
			return
		case data := <-peer.outgoing:
			frame := make([]byte, len(data)+2)
			binary.BigEndian.PutUint16(frame, uint16(len(data)))
			copy(frame[2:], data)
			conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := io.Copy(conn, bytes.NewReader(frame)); err != nil {
				if peer.context.Err() == nil {
					log.Printf("UDP 报文发送失败：目标=%s，原因=%v", target, err)
				}
				return
			}
		}
	}
}

func (a *udpAssociation) receive(peer *udpPeer, target netip.AddrPort) {
	defer peer.cancel()
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
		case <-peer.context.Done():
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
	return nil
}
