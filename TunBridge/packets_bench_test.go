package main

import (
	"context"
	"fmt"
	"net/netip"
	"testing"
)

// 只测封装与排队成本，不包含网络或协议栈吞吐；接收器读取内容，防止空操作掩盖复制成本。
type datagramBenchSink struct{ last byte }

func (s *datagramBenchSink) Write(data []byte) (int, error) {
	s.last = data[len(data)-1]
	return len(data), nil
}

func BenchmarkDatagramWrite(b *testing.B) {
	for _, size := range []int{64, 1200, 8192, maxPacket} {
		b.Run(fmt.Sprint(size), func(b *testing.B) {
			data := udpMTUPattern(size, uint32(size))
			sink := &datagramBenchSink{}
			frames := datagramWriter{writer: sink}
			// 预热一次，使复用缓冲的初次分配不计入稳定流量的逐包成本。
			if err := frames.write(data); err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := frames.write(data); err != nil {
					b.Fatal(err)
				}
			}
			if sink.last != data[len(data)-1] {
				b.Fatal("发送内容未交给接收器")
			}
		})
	}
}

func BenchmarkUDPFullQueue(b *testing.B) {
	for _, size := range []int{1200, maxPacket} {
		b.Run(fmt.Sprint(size), func(b *testing.B) {
			target := netip.MustParseAddrPort("198.51.100.2:53")
			queue := make(chan []byte, 32)
			for i := 0; i < cap(queue); i++ {
				queue <- nil
			}
			association := &udpAssociation{context: context.Background(), peers: map[netip.AddrPort]*udpPeer{target: {outgoing: queue}}}
			data := udpMTUPattern(size, uint32(size))
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := association.SendPacket(data, target); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
