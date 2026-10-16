package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"syscall"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

func TestTun2socksDoesNotReplyToEcho(t *testing.T) {
	for _, ipv6 := range []bool{false, true} {
		t.Run(map[bool]string{false: "IPv4", true: "IPv6"}[ipv6], func(t *testing.T) {
			dialer, _ := echoKernel(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			input, writer := io.Pipe()
			defer input.Close()
			defer writer.Close()
			output := make(chan []byte, 8)
			device, _, err := startForwarding("tun2socks", ctx, dialer, packetTestIO{input, packetTestWriter(func(p []byte) (int, error) {
				select {
				case output <- append([]byte(nil), p...):
					return len(p), nil
				case <-ctx.Done():
					return 0, ctx.Err()
				}
			})})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { cancel(); input.Close(); writer.Close(); device.Close() }()

			echo := []byte{8, 0, 0, 0, 0, 1, 0, 1}
			binary.BigEndian.PutUint16(echo[2:], checksum(echo))
			packet := ipv4(echo, 1)
			if ipv6 {
				packet = make([]byte, 48)
				packet[0], packet[6], packet[7] = 0x60, 58, 64
				binary.BigEndian.PutUint16(packet[4:], 8)
				copy(packet[8:24], netip.MustParseAddr("fdfe:dcba:9876::2").AsSlice())
				copy(packet[24:40], netip.MustParseAddr("2001:db8::2").AsSlice())
				echo[0], echo[2], echo[3] = byte(header.ICMPv6EchoRequest), 0, 0
				pseudo := append([]byte{}, packet[8:40]...)
				pseudo = append(pseudo, 0, 0, 0, 8, 0, 0, 0, 58)
				binary.BigEndian.PutUint16(echo[2:], checksum(append(pseudo, echo...)))
				copy(packet[40:], echo)
			}
			if _, err := writer.Write(packet); err != nil {
				t.Fatal(err)
			}
			// 随后的 UDP 回包确认输入和输出队列已经推进，避免仅凭等待超时判定 Echo 被拦截。
			payload := []byte("转发仍然可用")
			if _, err := writer.Write(udpMTUPacket(ipv6, payload)); err != nil {
				t.Fatal(err)
			}
			deadline := time.NewTimer(3 * time.Second)
			defer deadline.Stop()
			for {
				select {
				case reply := <-output:
					protocol, offset := 9, 20
					if ipv6 {
						protocol, offset = 6, 40
					}
					if len(reply) != offset+8+len(payload) || reply[protocol] != 17 || string(reply[offset+8:]) != string(payload) {
						t.Errorf("应仅收到 UDP 回包，不应本机应答 Echo：%x", reply)
						continue
					}
					return
				case <-deadline.C:
					t.Fatal("拦截 Echo 后 UDP 转发未完成")
				}
			}
		})
	}
}

func TestTun2socksDeviceErrorsStopSession(t *testing.T) {
	for _, mode := range []string{"read", "write", "short"} {
		t.Run(mode, func(t *testing.T) {
			release := make(chan struct{})
			defer close(release)
			dialer, _ := selectiveEchoKernel(t, "", release)
			input, writer := io.Pipe()
			failure := errors.New("测试设备失败")
			device, stopped, err := startForwarding("tun2socks", context.Background(), dialer,
				packetTestIO{input, packetTestWriter(func(p []byte) (int, error) {
					if mode == "short" {
						return len(p) - 1, nil
					}
					return 0, failure
				})})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { input.Close(); writer.Close(); device.Close() }()
			if mode == "read" {
				writer.CloseWithError(failure)
			} else {
				if _, err := writer.Write(ipv4([]byte{0x9c, 0x40, 0, 53, 0, 9, 0, 0, 1}, 17)); err != nil {
					t.Fatal(err)
				}
			}
			expected := failure
			if mode == "short" {
				expected = io.ErrShortWrite
			}
			select {
			case err := <-stopped:
				if !errors.Is(err, expected) {
					t.Fatalf("未报告设备错误：%v", err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("设备失败后未通知会话停止")
			}
		})
	}
}

type testTunTCPConn struct{ *net.TCPConn }

func (*testTunTCPConn) ID() stack.TransportEndpointID {
	return stack.TransportEndpointID{LocalAddress: tcpip.AddrFrom4([4]byte{198, 51, 100, 2}), LocalPort: 80}
}

func TestTun2socksTCPHalfCloseAndCancellation(t *testing.T) {
	for _, cancelSession := range []bool{false, true} {
		t.Run(map[bool]string{false: "半关闭", true: "取消会话"}[cancelSession], func(t *testing.T) {
			kernel, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer kernel.Close()
			target, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer target.Close()
			client, err := net.Dial("tcp", target.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			incoming, err := target.Accept()
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			handler := tun2socksHandler{ctx, localDialer{kernel.Addr().String()}}
			handler.HandleTCP(&testTunTCPConn{incoming.(*net.TCPConn)})
			upstream, err := kernel.Accept()
			if err != nil {
				t.Fatal(err)
			}
			defer upstream.Close()
			upstream.SetDeadline(time.Now().Add(3 * time.Second))
			client.SetDeadline(time.Now().Add(3 * time.Second))
			reader := bufio.NewReader(upstream)
			request, err := http.ReadRequest(reader)
			if err != nil {
				t.Fatal(err)
			}
			if request.Host != "198.51.100.2:80" || request.Header.Get("X-Network-Source") != "tun" {
				t.Fatal("未保留内核目标与 TUN 来源标识")
			}
			io.WriteString(upstream, "HTTP/1.1 200 OK\r\n\r\n")
			if cancelSession {
				cancel()
			} else {
				io.WriteString(client, "请求内容")
				client.(*net.TCPConn).CloseWrite()
			}
			received, err := io.ReadAll(reader)
			// 取消可能早于 CONNECT 响应被读完，此时关闭连接允许产生 RST；半关闭仍必须正常 EOF。
			if err != nil && !(cancelSession && errors.Is(err, syscall.ECONNRESET)) {
				t.Fatalf("内核未收到半关闭或取消通知：%v", err)
			}
			if !cancelSession {
				if string(received) != "请求内容" {
					t.Fatalf("请求未排空：%q", received)
				}
				io.WriteString(upstream, "半关闭后的响应")
				upstream.(*net.TCPConn).CloseWrite()
			}
			reply, err := io.ReadAll(client)
			if err != nil && !(cancelSession && errors.Is(err, syscall.ECONNRESET)) {
				t.Fatalf("客户端未正常结束：%v", err)
			}
			if !cancelSession && string(reply) != "半关闭后的响应" {
				t.Fatalf("响应被提前截断：%q", reply)
			}
		})
	}
}

func TestUnknownForwardingEngineIsRejected(t *testing.T) {
	if _, _, err := startForwarding("unknown", context.Background(), localDialer{}, nil); err == nil {
		t.Fatal("未知组件不应自动回退")
	}
}
