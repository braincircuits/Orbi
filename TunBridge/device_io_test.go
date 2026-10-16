//go:build darwin

package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"testing"

	"golang.org/x/sys/unix"
)

func TestTunBuffersPreservePacketBoundaries(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	file := os.NewFile(uintptr(fds[0]), "测试虚拟网卡")
	peer := os.NewFile(uintptr(fds[1]), "测试网络对端")
	defer file.Close()
	defer peer.Close()
	for _, fd := range fds {
		if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_SNDBUF, 65536); err != nil {
			t.Fatal(err)
		}
		// 本地数据报夹具的默认接收缓冲仅 4096 字节，须容纳完整的 8192 字节包与地址族。
		if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, 65536); err != nil {
			t.Fatal(err)
		}
	}
	tun := &tunDevice{file: file}
	buffer := make([]byte, 8192+4)
	for _, size := range []int{1500, 40, 2048, 60, 8192, 40, 2048, 60, 1500} {
		for _, family := range []uint32{unix.AF_INET, unix.AF_INET6} {
			packet := bytes.Repeat([]byte{byte(size)}, size)
			packet[0] = 0x45
			if family == unix.AF_INET6 {
				packet[0] = 0x60
			}
			if n, err := tun.Write(packet); err != nil || n != size {
				t.Fatalf("写入报文失败：%d，%v", n, err)
			}
			n, err := peer.Read(buffer)
			if err != nil || n != size+4 || binary.BigEndian.Uint32(buffer) != family || !bytes.Equal(buffer[4:n], packet) {
				t.Fatalf("收发缓冲复用破坏报文：大小=%d，错误=%v", size, err)
			}
			if _, err := peer.Write(buffer[:n]); err != nil {
				t.Fatal(err)
			}
			received := make([]byte, size)
			if n, err := tun.Read(received); err != nil || n != size || !bytes.Equal(received, packet) {
				t.Fatalf("读取报文失败：%d，%v", n, err)
			}
		}
	}
}

// 隔离测量 utun 帧封装的内存分配，不包含实际网卡带宽。
func BenchmarkTUNWrite(b *testing.B) {
	file, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		b.Fatal(err)
	}
	defer file.Close()
	tun := &tunDevice{file: file}
	packet := make([]byte, 1500)
	packet[0] = 0x45
	if _, err := tun.Write(packet); err != nil {
		b.Fatal(err)
	}
	b.SetBytes(int64(len(packet)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := tun.Write(packet); err != nil {
			b.Fatal(err)
		}
	}
}
