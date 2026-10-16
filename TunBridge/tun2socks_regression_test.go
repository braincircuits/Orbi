package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestTun2socksCloseWithTCPHandshake(t *testing.T) {
	mode := os.Getenv("NETWORK_TUN_TEST_HANDSHAKE")
	if mode == "" {
		// 与生产生命周期一致，用独立进程确认 Close 返回后能真正退出并回收 SDK 握手任务。
		for _, mode := range []string{"IPv4/SYN", "IPv4/SYN-ACK", "IPv6/SYN", "IPv6/SYN-ACK"} {
			t.Run(mode, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				child := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestTun2socksCloseWithTCPHandshake$", "-test.timeout=8s")
				child.Env = append(os.Environ(), "NETWORK_TUN_TEST_HANDSHAKE="+mode)
				if output, err := child.CombinedOutput(); err != nil {
					t.Fatalf("TCP 握手期间会话进程未正常退出：%v\n%s", err, output)
				}
			})
		}
		return
	}
	makePacket, offset := tcpPacket, 20
	if strings.HasPrefix(mode, "IPv6/") {
		makePacket, offset = tcpPacket6, 40
	}
	for i := 0; i < 100; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		input, writer := io.Pipe()
		synAck := make(chan struct{}, 1)
		device, _, err := startForwarding("tun2socks", ctx, localDialer{}, packetTestIO{input, packetTestWriter(func(p []byte) (int, error) {
			if len(p) >= offset+20 && p[offset+13]&0x12 == 0x12 {
				select {
				case synAck <- struct{}{}:
				default:
				}
			}
			return len(p), nil
		})})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(makePacket(100, 0, 2, nil)); err != nil {
			t.Fatal(err)
		}
		if strings.HasSuffix(mode, "/SYN-ACK") {
			select {
			case <-synAck:
			case <-time.After(time.Second):
				t.Fatal("未收到 SYN-ACK")
			}
		}
		cancel()
		input.Close()
		writer.Close()
		if err := device.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestTun2socksCloseWithPacketsInFlight(t *testing.T) {
	dialer, _ := echoKernel(t)
	for _, ipv6 := range []bool{false, true} {
		t.Run(map[bool]string{false: "IPv4", true: "IPv6"}[ipv6], func(t *testing.T) {
			packet := udpMTUPacket(ipv6, []byte("关闭时的最后一个报文"))
			for i := 0; i < 100; i++ {
				ctx, cancel := context.WithCancel(context.Background())
				input, writer := io.Pipe()
				device, _, err := startForwarding("tun2socks", ctx, dialer, packetTestIO{input, io.Discard})
				if err != nil {
					cancel()
					input.Close()
					writer.Close()
					t.Fatal(err)
				}
				_, writeErr := writer.Write(packet)
				// 与生产调用方一致：关闭设备后立即清理协议栈，不等待最后一个报文处理完成。
				cancel()
				input.Close()
				writer.Close()
				closed := make(chan error, 1)
				go func() { closed <- device.Close() }()
				select {
				case err := <-closed:
					if err != nil {
						t.Fatal(err)
					}
				case <-time.After(3 * time.Second):
					t.Fatalf("第 %d 次关闭未结束，输入循环与协议栈可能互相等待", i+1)
				}
				if writeErr != nil {
					t.Fatal(writeErr)
				}
			}
		})
	}
}

func TestTun2socksUDPSizeLimit(t *testing.T) {
	for _, test := range []struct {
		ipv6 bool
		size int
	}{{false, maxPacket}, {true, maxPacket}, {true, maxPacket + 1}, {true, 65527}} {
		family := map[bool]string{false: "IPv4", true: "IPv6"}[test.ipv6]
		t.Run(fmt.Sprintf("%s/%d字节", family, test.size), func(t *testing.T) {
			dialer, requests := echoKernel(t)
			ctx, cancel := context.WithCancel(context.Background())
			input, writer := io.Pipe()
			output := make(chan []byte, 64)
			device, _, err := startForwarding("tun2socks", ctx, dialer, packetTestIO{input, packetTestWriter(func(p []byte) (int, error) {
				select {
				case output <- append([]byte{}, p...):
					return len(p), nil
				case <-ctx.Done():
					return 0, ctx.Err()
				}
			})})
			if err != nil {
				cancel()
				input.Close()
				writer.Close()
				t.Fatal(err)
			}
			defer func() { cancel(); input.Close(); writer.Close(); device.Close() }()
			// 先建立同一 UDP 会话，确保长度边界测试不会被 CONNECT 尚未就绪掩盖。
			initial := []byte("建立会话")
			udpMTUWrite(t, writer, udpMTUPacket(test.ipv6, initial))
			udpMTUReply(t, output, test.ipv6, initial)
			<-requests

			data := udpMTUPattern(test.size, uint32(test.size))
			for _, packet := range udpMTUFragments(udpMTUPacket(test.ipv6, data), 1, tunMTU) {
				udpMTUWrite(t, writer, packet)
			}
			if test.size <= maxPacket {
				// 验证真实协议栈重组、完整 CONNECT 回显和回包分片，不能误丢恰好到上限的报文。
				udpMTUReply(t, output, test.ipv6, data)
			} else {
				select {
				case packet := <-output:
					t.Fatalf("超限 UDP 不应被截断后转发：输入长度=%d，收到回包长度=%d", test.size, len(packet))
				case <-time.After(200 * time.Millisecond):
				}
			}
			// 丢弃超限报文后，同一会话的正常报文和空报文仍应保持边界并成功转发。
			for _, payload := range [][]byte{[]byte("后续报文"), {}} {
				udpMTUWrite(t, writer, udpMTUPacket(test.ipv6, payload))
				udpMTUReply(t, output, test.ipv6, payload)
			}
			select {
			case <-requests:
				t.Fatal("长度检查不应关闭并重建 UDP 会话")
			default:
			}
		})
	}
}
