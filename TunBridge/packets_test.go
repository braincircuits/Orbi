package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/netip"
	"sync"
	"testing"

	"golang.getoutline.org/sdk/network/packetrelay"
)

func TestDatagramWriterPreservesFramesAcrossResize(t *testing.T) {
	var output bytes.Buffer
	frames := datagramWriter{writer: &output}
	sizes := []int{0, 64, 8192, 1, maxPacket, 0, 1200, 64}
	for i, size := range sizes {
		payload := udpMTUPattern(size, uint32(i+1))
		if err := frames.write(payload); err != nil {
			t.Fatal(err)
		}
		// 上游可以在同步发送返回后复用输入，后续发送也不能覆盖已写出的报文。
		clear(payload)
	}
	for i, size := range sizes {
		payload, err := readDatagram(&output)
		if err != nil || !bytes.Equal(payload, udpMTUPattern(size, uint32(i+1))) {
			t.Fatalf("第 %d 条报文边界或内容错误：长度=%d，错误=%v", i+1, len(payload), err)
		}
	}
	if output.Len() != 0 {
		t.Fatal("缩小报文后写出了缓冲中的旧数据")
	}
	if err := frames.write(make([]byte, maxPacket+1)); err == nil || output.Len() != 0 {
		t.Fatal("超限报文不应写入长度前缀或载荷")
	}
	if err := frames.write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	payload, err := readDatagram(&output)
	if err != nil || !bytes.Equal(payload, []byte{1}) {
		t.Fatal("拒绝超限报文后未恢复正常发送")
	}
}

func TestDatagramWriterReportsWriteFailures(t *testing.T) {
	failure := errors.New("测试发送失败")
	for _, test := range []struct {
		name          string
		n             int
		err, expected error
	}{
		{"未写入", 0, nil, io.ErrShortWrite},
		{"只写入前缀", 2, nil, io.ErrShortWrite},
		{"部分写入失败", 2, failure, failure},
		{"完整写入后报错", 5, failure, failure},
	} {
		t.Run(test.name, func(t *testing.T) {
			calls := 0
			frames := datagramWriter{writer: packetTestWriter(func(frame []byte) (int, error) {
				calls++
				if !bytes.Equal(frame, []byte{0, 3, 1, 2, 3}) {
					t.Fatal("长度前缀和载荷必须合并写入")
				}
				return test.n, test.err
			})}
			if err := frames.write([]byte{1, 2, 3}); !errors.Is(err, test.expected) {
				t.Fatalf("未保留写入失败：%v", err)
			}
			if calls != 1 {
				t.Fatal("短写失败后不应重新发送帧")
			}
		})
	}
}

func TestDatagramWriterSteadyTrafficDoesNotAllocate(t *testing.T) {
	frames := datagramWriter{writer: io.Discard}
	data := udpMTUPattern(maxPacket, 1)
	if err := frames.write(data); err != nil {
		t.Fatal(err)
	}
	allocations := testing.AllocsPerRun(100, func() {
		for _, size := range []int{0, 64, 1200, maxPacket} {
			if err := frames.write(data[:size]); err != nil {
				t.Fatal(err)
			}
		}
	})
	if allocations != 0 {
		t.Fatalf("稳定流量不应继续为发送帧分配内存：%v", allocations)
	}
}

func TestUDPFullQueueDropsWithoutAllocationAndRecovers(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	target := netip.MustParseAddrPort("198.51.100.2:53")
	other := netip.MustParseAddrPort("198.51.100.3:53")
	queue := make(chan []byte, 32)
	otherQueue := make(chan []byte, 32)
	association := &udpAssociation{context: ctx, peers: map[netip.AddrPort]*udpPeer{
		target: {outgoing: queue}, other: {outgoing: otherQueue},
	}}
	for i := 0; i < cap(queue); i++ {
		queue <- []byte{byte(i)}
	}
	payload := udpMTUPattern(maxPacket, 1)
	allocations := testing.AllocsPerRun(100, func() {
		if err := association.SendPacket(payload, target); err != nil {
			t.Fatal(err)
		}
	})
	if allocations != 0 || len(queue) != cap(queue) {
		t.Fatalf("满队列丢包不应分配或改变队列：分配=%v，队列长度=%d", allocations, len(queue))
	}
	if err := association.SendPacket([]byte{99}, other); err != nil || !bytes.Equal(<-otherQueue, []byte{99}) {
		t.Fatal("满队列影响了其他目标")
	}
	for i := 0; i < cap(queue); i++ {
		if !bytes.Equal(<-queue, []byte{byte(i)}) {
			t.Fatal("丢包改变了原有排队内容或顺序")
		}
	}
	for _, data := range [][]byte{{1, 2, 3}, {}} {
		expected := append([]byte{}, data...)
		if err := association.SendPacket(data, target); err != nil {
			t.Fatal(err)
		}
		clear(data)
		if !bytes.Equal(<-queue, expected) {
			t.Fatal("队列恢复后未复制输入，或未保留空报文")
		}
	}
	cancel()
	if err := association.SendPacket(payload, target); err != packetrelay.ErrClosed || len(queue) != 0 {
		t.Fatal("取消后仍接受报文")
	}
}

func TestUDPQueueConcurrentSendersPreservePayloads(t *testing.T) {
	target := netip.MustParseAddrPort("198.51.100.2:53")
	queue := make(chan []byte, 32)
	association := &udpAssociation{context: context.Background(), peers: map[netip.AddrPort]*udpPeer{target: {outgoing: queue}}}
	var senders sync.WaitGroup
	for id := byte(1); id <= 8; id++ {
		senders.Add(1)
		go func(id byte) {
			defer senders.Done()
			data := make([]byte, 64)
			for i := 0; i < 300; i++ {
				for j := range data {
					data[j] = id
				}
				if err := association.SendPacket(data, target); err != nil {
					t.Error(err)
					return
				}
				clear(data)
			}
		}(id)
	}
	go func() { senders.Wait(); close(queue) }()
	received := 0
	for data := range queue {
		received++
		if len(data) != 64 || data[0] < 1 || data[0] > 8 || !bytes.Equal(data, bytes.Repeat(data[:1], 64)) {
			t.Fatal("并发发送或队列消费破坏了报文")
		}
	}
	if received == 0 {
		t.Fatal("没有接收到任何报文")
	}
}
