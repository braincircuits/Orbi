package main

import (
	"context"
	"io"
	"os"
	"testing"

	"golang.getoutline.org/sdk/network/lwip2transport"
	"golang.org/x/sys/unix"
)

// 用真实数据报套接字保留双向逐包系统调用，比较 SDK 同步交接与直接输出。
type packetTestDevice struct {
	io.Writer
	io.Closer
}

func newTCPOutputStack(t testing.TB, output func([]byte) (int, error), mode string) io.WriteCloser {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, fd := range fds {
		if err := unix.SetNonblock(fd, true); err != nil {
			t.Fatal(err)
		}
		if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_SNDBUF, 65536); err != nil {
			t.Fatal(err)
		}
		// UNIX 数据报默认接收队列只有几 KiB，至少容纳一次测试 TCP 窗口。
		if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, 2*1024*1024); err != nil {
			t.Fatal(err)
		}
	}
	file := os.NewFile(uintptr(fds[0]), "测试 TUN 输出")
	peer := os.NewFile(uintptr(fds[1]), "测试 ACK 接收")
	tun := &tunDevice{file: file}
	dialer := localDialer{proxy: "127.0.0.1:1"}
	device, err := lwip2transport.ConfigureDeviceWithRelay(dialer, udpRelay{dialer, context.Background()})
	if err != nil {
		file.Close()
		peer.Close()
		t.Fatal(err)
	}
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		buffer := make([]byte, 65536)
		for {
			n, err := peer.Read(buffer)
			if err != nil {
				return
			}
			if n > 4 {
				output(buffer[4:n])
			}
		}
	}()
	var writeDone, inputDone chan struct{}
	var stopped <-chan error
	switch mode {
	case "sdk":
		inputDone = make(chan struct{})
		go func() { defer close(inputDone); io.Copy(device, tun) }()
		writeDone = make(chan struct{})
		go func() { defer close(writeDone); io.Copy(tun, device) }()
	case "direct":
		stopped = forwardPackets(device, tun)
	default:
		t.Fatalf("未知输出测量模式：%s", mode)
	}
	t.Cleanup(func() {
		device.Close()
		file.Close()
		peer.Close()
		<-readDone
		if writeDone != nil {
			<-writeDone
		}
		if stopped != nil {
			<-stopped
		}
		if inputDone != nil {
			<-inputDone
		}
	})
	return packetTestDevice{Writer: &tunDevice{file: peer}, Closer: device}
}
