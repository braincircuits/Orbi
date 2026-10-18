package main

import (
	"context"
	"io"
	"testing"

	"golang.getoutline.org/sdk/network/lwip2transport"
)

type packetTestDevice struct {
	io.Writer
	io.Closer
}

// Windows 单元测试通过逐次写入的管道注入 IP 报文，不创建需要管理员授权的网卡。
func newTCPOutputStack(t testing.TB, output func([]byte) (int, error), mode string) io.WriteCloser {
	t.Helper()
	input, writer := io.Pipe()
	dialer := localDialer{proxy: "127.0.0.1:1"}
	device, err := lwip2transport.ConfigureDeviceWithRelay(dialer, udpRelay{dialer, context.Background()})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	switch mode {
	case "sdk":
		go func() { io.Copy(device, input); close(done) }()
		go func() {
			buffer := make([]byte, 65536)
			for {
				n, err := device.Read(buffer)
				if err != nil {
					return
				}
				output(buffer[:n])
			}
		}()
	case "direct":
		stopped := forwardPackets(device, packetTestIO{input, packetTestWriter(output)})
		go func() { <-stopped; close(done) }()
	default:
		t.Fatalf("未知输出测量模式：%s", mode)
	}
	t.Cleanup(func() { input.Close(); writer.Close(); device.Close(); <-done })
	return packetTestDevice{writer, device}
}
