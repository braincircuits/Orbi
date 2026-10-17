package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.getoutline.org/sdk/network/packetrelay"
)

func TestMalformedConnectResponseDoesNotEchoCredentials(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	const secret = "response-password-secret"
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		http.ReadRequest(bufio.NewReader(conn))
		io.WriteString(conn, "HTTP/1.1 "+secret+"\r\n\r\n")
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err = (localDialer{proxy: listener.Addr().String()}).DialStream(ctx, "example.test:443")
	if err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("无效响应应只返回固定错误，不包含凭据：%v", err)
	}
}

// 本机假内核按实际 CONNECT 线协议回显，不需要管理员权限或公网服务。
func echoKernel(t *testing.T) (localDialer, <-chan string) {
	return selectiveEchoKernel(t, "", nil)
}

func selectiveEchoKernel(t *testing.T, stalledTarget string, release <-chan struct{}) (localDialer, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	requests := make(chan string, 100)
	var connections sync.Map
	t.Cleanup(func() {
		listener.Close()
		connections.Range(func(key, _ any) bool { key.(net.Conn).Close(); return true })
	})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			connections.Store(conn, true)
			go func() {
				defer conn.Close()
				defer connections.Delete(conn)
				reader := bufio.NewReader(conn)
				request, err := http.ReadRequest(reader)
				if err != nil {
					return
				}
				if request.Header.Get("X-Network-Source") != "tun" {
					t.Error("缺少 TUN 来源标识")
					return
				}
				requests <- request.Host
				if request.Host == stalledTarget {
					<-release
				}
				if request.Header.Get(udpHeader) == "udp" {
					io.WriteString(conn, "HTTP/1.1 200 OK\r\nx-network-transport: udp\r\n\r\n")
					for {
						var prefix [2]byte
						if _, err := io.ReadFull(reader, prefix[:]); err != nil {
							return
						}
						data := make([]byte, int(binary.BigEndian.Uint16(prefix[:])))
						if _, err := io.ReadFull(reader, data); err != nil {
							return
						}
						conn.Write(prefix[:])
						conn.Write(data)
					}
				} else {
					io.WriteString(conn, "HTTP/1.1 200 OK\r\n\r\n")
					io.Copy(conn, reader)
				}
			}()
		}
	}()
	return localDialer{proxy: listener.Addr().String()}, requests
}

func TestBlockedUDPConnectDoesNotBlockOtherDestinations(t *testing.T) {
	release := make(chan struct{})
	unblock := sync.OnceFunc(func() { close(release) })
	defer unblock()
	dialer, requests := selectiveEchoKernel(t, "198.51.100.9:443", release)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sender, receiver, err := (udpRelay{dialer, ctx}).NewAssociation()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { cancel(); sender.Close() }()
	returned := make(chan error, 1)
	input := []byte{1}
	go func() { returned <- sender.SendPacket(input, netip.MustParseAddrPort("198.51.100.9:443")) }()
	select {
	case <-requests:
	case <-time.After(time.Second):
		t.Fatal("未发起测试 CONNECT")
	}
	select {
	case err := <-returned:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("等待代理 CONNECT 阻塞了 TUN 报文回调")
	}
	input[0] = 9
	// 填满阻塞目标的有限队列，仍不能拖住同一来源的其他目标。
	for i := 0; i < 64; i++ {
		if err := sender.SendPacket([]byte{3}, netip.MustParseAddrPort("198.51.100.9:443")); err != nil {
			t.Fatal(err)
		}
	}
	received := make(chan receivedPacket, 100)
	go receiver.ReceivePackets(packetHandlerFunc(func(data []byte, source netip.AddrPort) error {
		received <- receivedPacket{append([]byte{}, data...), source}
		return nil
	}))
	healthy := netip.MustParseAddrPort("192.0.2.1:53")
	if err := sender.SendPacket([]byte{2}, healthy); err != nil {
		t.Fatal(err)
	}
	select {
	case reply := <-received:
		if reply.source != healthy || string(reply.data) != string([]byte{2}) {
			t.Fatal("其他目标回包错误")
		}
	case <-time.After(time.Second):
		t.Fatal("代理目标阻塞影响了同一来源的其他目标")
	}
	unblock()
	select {
	case reply := <-received:
		if reply.source.String() != "198.51.100.9:443" || string(reply.data) != string([]byte{1}) {
			t.Fatal("排队报文被调用方复用的缓冲区修改")
		}
	case <-time.After(time.Second):
		t.Fatal("解除阻塞后未发送排队报文")
	}
}

func TestTCPConnectAndHalfClose(t *testing.T) {
	dialer, requests := echoKernel(t)
	conn, err := dialer.DialStream(context.Background(), "198.51.100.2:443")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	conn.Write([]byte("测试 TCP"))
	conn.CloseWrite()
	data, err := io.ReadAll(conn)
	if err != nil || string(data) != "测试 TCP" {
		t.Fatalf("TCP 回显失败：%q，%v", data, err)
	}
	if target := <-requests; target != "198.51.100.2:443" {
		t.Fatalf("目标错误：%s", target)
	}
}

type packetHandlerFunc func([]byte, netip.AddrPort) error

func (f packetHandlerFunc) HandlePacket(p []byte, source netip.AddrPort) error { return f(p, source) }

func TestUDPAssociationPreservesBoundariesDestinationsAndCancellation(t *testing.T) {
	dialer, _ := echoKernel(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sender, receiver, err := (udpRelay{dialer, ctx}).NewAssociation()
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	received := make(chan receivedPacket, 10)
	ended := make(chan error, 1)
	go func() {
		ended <- receiver.ReceivePackets(packetHandlerFunc(func(p []byte, addr netip.AddrPort) error {
			received <- receivedPacket{append([]byte{}, p...), addr}
			return nil
		}))
	}()
	for _, target := range []string{"192.0.2.1:53", "[2001:db8::2]:123"} {
		address := netip.MustParseAddrPort(target)
		for _, size := range []int{0, 1, 4096, maxPacket} {
			packet := make([]byte, size)
			for i := range packet {
				packet[i] = byte(i)
			}
			if err := sender.SendPacket(packet, address); err != nil {
				t.Fatal(err)
			}
			select {
			case response := <-received:
				if string(response.data) != string(packet) || response.source != address {
					t.Fatal("UDP 报文边界或来源丢失")
				}
			case <-time.After(3 * time.Second):
				t.Fatal("UDP 回显超时")
			}
		}
	}
	cancel()
	select {
	case err := <-ended:
		if err != packetrelay.ErrClosed {
			t.Fatalf("关闭结果错误：%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("取消未结束接收")
	}
	if sender.SendPacket([]byte{1}, netip.MustParseAddrPort("192.0.2.1:53")) != packetrelay.ErrClosed {
		t.Fatal("关闭后仍接受报文")
	}
}

func TestUDPRequiresExplicitAcknowledgement(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		http.ReadRequest(bufio.NewReader(conn))
		io.WriteString(conn, "HTTP/1.1 200 OK\r\n\r\n")
	}()
	_, err = (localDialer{listener.Addr().String()}).connect(context.Background(), "192.0.2.1:53", true)
	if err == nil {
		t.Fatal("未确认 UDP 的响应不应被接受")
	}
}
