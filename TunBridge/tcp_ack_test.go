package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"os"
	"sort"
	"strconv"
	"testing"
	"time"

	lwip "github.com/eycorsican/go-tun2socks/core"
)

// 暂停下游消费，验证协议栈仍能确认已缓存数据、处理其他连接，并用零窗口限流。
func TestTCPReceiveBackpressure(t *testing.T) {
	p := newTCPTestPeer(t, false, true)
	defer p.conn.(lwip.TCPConn).CloseRead()
	finished := make(chan error, 1)
	payload := bytes.Repeat([]byte{37}, 1460)
	go func() {
		for i := 0; i < 2; i++ {
			_, err := p.stack.Write(p.makePacket(p.sequence, p.acknowledgement, 0x18, payload))
			if err != nil {
				finished <- err
				return
			}
			p.sequence += uint32(len(payload))
		}
		finished <- nil
	}()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("下游尚未读取时，接收回调阻塞了协议栈")
	}
	for expected := p.sequence - uint32(len(payload)); expected <= p.sequence; expected += uint32(len(payload)) {
		select {
		case output := <-p.output:
			header := tcpHeader(output.packet)
			if binary.BigEndian.Uint32(header[8:]) != expected {
				t.Fatal("已缓存报文未立即获得 ACK")
			}
			p.acknowledged = expected
			p.window = uint32(binary.BigEndian.Uint16(header[14:])) << p.scale
		default:
			t.Fatal("ACK 仍需等待下游或定时器")
		}
	}
	// 同一个协议栈的另一个连接仍应立即获得 SYN ACK。
	p.write(tcpPacket6(100, 0, 2, nil))
	if header := tcpHeader(p.next(0).packet); header[13]&0x12 != 0x12 {
		t.Fatal("阻塞影响了其他连接")
	}
	for p.window > 0 {
		for p.sequence < p.acknowledged+p.window {
			n := min(len(payload), int(p.acknowledged+p.window-p.sequence))
			p.write(p.makePacket(p.sequence, p.acknowledgement, 0x18, payload[:n]))
			p.sequence += uint32(n)
		}
		header := tcpHeader(p.next(0).packet)
		p.acknowledged = binary.BigEndian.Uint32(header[8:])
		p.window = uint32(binary.BigEndian.Uint16(header[14:])) << p.scale
	}
	if p.sequence-101 > 1024*1024 {
		t.Fatal("未消费数据超出接收缓冲上限")
	}
	data := make([]byte, int(p.sequence-101))
	if _, err := io.ReadFull(p.conn, data); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, bytes.Repeat([]byte{37}, len(data))) {
		t.Fatal("缓冲数据损坏")
	}
	// 窗口恢复后再次穿过环形缓冲末尾，验证复用和数据顺序。
	p.upload(bytes.Repeat([]byte{91}, 2*1024*1024+17), 0)
}

func TestTCPReceiveFINDrainsBuffer(t *testing.T) {
	for _, closeWrite := range []bool{false, true} {
		p := newTCPTestPeer(t, false, true)
		data := bytes.Repeat([]byte{73}, 1460)
		p.write(p.makePacket(p.sequence, p.acknowledgement, 0x18, data))
		p.sequence += uint32(len(data))
		if closeWrite {
			if err := p.conn.(lwip.TCPConn).CloseWrite(); err != nil {
				t.Fatal(err)
			}
		}
		p.write(p.makePacket(p.sequence, p.acknowledgement, 0x11, nil))
		got, err := io.ReadAll(p.conn)
		if err != nil || !bytes.Equal(got, data) {
			t.Fatalf("FIN 之后缓冲未完整读出：长度=%d，错误=%v", len(got), err)
		}
		p.close()
	}
}

func ackMeasurementSize(t *testing.T, name string, fallback, minimum, maximum int) int {
	t.Helper()
	text := os.Getenv(name)
	if text == "" {
		return fallback
	}
	value, err := strconv.Atoi(text)
	if err != nil || value < minimum || value > maximum {
		t.Fatalf("%s 必须是 %d 到 %d 之间的整数", name, minimum, maximum)
	}
	return value
}

// 只记录源端的读取批次，不包装目标 Writer，保留 io.CopyN 对目标 ReadFrom 的选择。
// 原始 lwIP 连接不实现 WriterTo，因此增加这个 Reader 不改变原有复制路径。
type tcpForwardReadSamples struct {
	reader io.Reader
	sizes  []int
	bytes  int64
}

func (r *tcpForwardReadSamples) Read(buffer []byte) (int, error) {
	n, err := r.reader.Read(buffer)
	if n > 0 {
		r.sizes = append(r.sizes, n)
		r.bytes += int64(n)
	}
	return n, err
}

// 不添加延迟：经真实 macOS TCP 套接字、可选 Java 内核转发，测量输入调用及实际 ACK 生成时间。
// NETWORK_ACK_PROXY 只能指向隔离测试内核，避免改动正在使用的代理配置。
func TestTCPActualACKLatency(t *testing.T) {
	if os.Getenv("NETWORK_ACK_MEASURE") != "1" {
		t.Skip("按需测量实际转发时延")
	}
	totalMiB := ackMeasurementSize(t, "NETWORK_ACK_MIB", 64, 1, 1024)
	maxInflight := ackMeasurementSize(t, "NETWORK_ACK_MAX_INFLIGHT", 32*1024, 1460, 1024*1024)
	total := totalMiB * 1024 * 1024
	// 大文件测量允许较慢转发持续完成，保持原来 64 MiB 测量的最低超时。
	deadline := time.Now().Add(max(20*time.Second, time.Duration(totalMiB)*time.Second/4))
	t.Logf("测量规模：数据=%d MiB 最大在途=%d 字节", totalMiB, maxInflight)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	received := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			received <- err
			return
		}
		defer conn.Close()
		conn.SetDeadline(deadline)
		hash := byte(0)
		buffer := make([]byte, 65536)
		for n := 0; n < total; {
			count, err := conn.Read(buffer[:min(len(buffer), total-n)])
			for _, value := range buffer[:count] {
				hash |= value ^ 57
			}
			n += count
			if err != nil {
				received <- err
				return
			}
		}
		if hash != 0 {
			received <- io.ErrUnexpectedEOF
			return
		}
		received <- nil
	}()
	var downstream net.Conn
	if proxy := os.Getenv("NETWORK_ACK_PROXY"); proxy != "" {
		downstream, err = (localDialer{proxy: proxy}).DialStream(context.Background(), listener.Addr().String())
	} else {
		downstream, err = net.Dial("tcp", listener.Addr().String())
	}
	if err != nil {
		t.Fatal(err)
	}
	defer downstream.Close()
	downstream.SetDeadline(deadline)
	p := newTCPTestPeer(t, false, true, os.Getenv("NETWORK_ACK_OUTPUT"))
	defer p.conn.(lwip.TCPConn).CloseRead()
	copied := make(chan error, 1)
	reads := &tcpForwardReadSamples{reader: p.conn}
	go func() { _, err := io.CopyN(downstream, reads, int64(total)); copied <- err }()
	type sentPacket struct {
		end uint32
		at  time.Time
	}
	var pending []sentPacket
	var inputTimes, ackTimes []time.Duration
	payload := bytes.Repeat([]byte{57}, 1460)
	acknowledgedIndex := 0
	consume := func(output tcpOutput) {
		header := tcpHeader(output.packet)
		if header[13]&4 != 0 {
			t.Fatal("传输期间连接重置")
		}
		ack := binary.BigEndian.Uint32(header[8:])
		for acknowledgedIndex < len(pending) && pending[acknowledgedIndex].end <= ack {
			ackTimes = append(ackTimes, output.at.Sub(pending[acknowledgedIndex].at))
			acknowledgedIndex++
		}
		p.acknowledged = ack
		p.window = uint32(binary.BigEndian.Uint16(header[14:])) << p.scale
	}
	rdpPattern := os.Getenv("NETWORK_ACK_PATTERN") == "rdp"
	started := time.Now()
	for sent := 0; sent < total; {
		// 使用显式在途上限复现现场发送节奏，不靠人工 ACK 延迟或定时合包改变结果。
		limit := p.acknowledged + min(p.window, uint32(maxInflight))
		if p.sequence >= limit {
			consume(p.next(0))
			continue
		}
		packetSize := len(payload)
		if rdpPattern {
			// 现场抓包中的 RDP TLS 记录通常为 1645 字节，分成 1460 + 185。
			offset := sent % 1645
			if offset < 1460 {
				packetSize = 1460 - offset
			} else {
				packetSize = 1645 - offset
			}
		}
		n := min(packetSize, total-sent)
		if uint32(n) > limit-p.sequence {
			consume(p.next(0))
			continue
		}
		packet := p.makePacket(p.sequence, p.acknowledgement, 0x18, payload[:n])
		at := time.Now()
		p.write(packet)
		inputTimes = append(inputTimes, time.Since(at))
		p.sequence += uint32(n)
		sent += n
		pending = append(pending, sentPacket{p.sequence, at})
		select {
		case output := <-p.output:
			consume(output)
		default:
		}
	}
	if err := <-received; err != nil {
		t.Fatal(err)
	}
	if err := <-copied; err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(started)
	for acknowledgedIndex < len(pending) {
		consume(p.next(0))
	}
	for name, values := range map[string][]time.Duration{"发送端提交报文调用": inputTimes, "数据输入到累计ACK输出": ackTimes} {
		sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
		t.Logf("%s：样本=%d p50=%s p95=%s p99=%s 最大=%s", name, len(values), values[len(values)/2], values[len(values)*95/100], values[len(values)*99/100], values[len(values)-1])
	}
	sort.Ints(reads.sizes)
	t.Logf("Go 到本机 TCP 的读取批次：次数=%d 平均=%.2f 字节 p50=%d p95=%d p99=%d 最大=%d；该计数不是网络报文数或系统调用数",
		len(reads.sizes), float64(reads.bytes)/float64(len(reads.sizes)), reads.sizes[len(reads.sizes)/2],
		reads.sizes[len(reads.sizes)*95/100], reads.sizes[len(reads.sizes)*99/100], reads.sizes[len(reads.sizes)-1])
	t.Logf("无人工延迟转发：字节=%d 耗时=%s 吞吐=%.2f MB/s", total, elapsed, float64(total)/elapsed.Seconds()/1e6)
}

// 单个小报文没有后续报文触发累计确认，直接观察协议栈自己的延迟 ACK 定时器。
func TestTCPSinglePacketACKLatency(t *testing.T) {
	if os.Getenv("NETWORK_ACK_MEASURE") != "1" {
		t.Skip("按需测量孤立报文的实际 ACK")
	}
	p := newTCPTestPeer(t, false, true, os.Getenv("NETWORK_ACK_OUTPUT"))
	defer p.conn.(lwip.TCPConn).CloseRead()
	done := make(chan struct{})
	go func() { io.Copy(io.Discard, p.conn); close(done) }()
	for i := 0; i < 4; i++ {
		at := time.Now()
		p.write(p.makePacket(p.sequence, p.acknowledgement, 0x18, []byte{1}))
		p.sequence++
		for {
			output := p.next(0)
			if binary.BigEndian.Uint32(tcpHeader(output.packet)[8:]) == p.sequence {
				t.Logf("孤立报文实际 ACK 延迟：%s", output.at.Sub(at))
				break
			}
		}
	}
	p.conn.(lwip.TCPConn).CloseRead()
	<-done
}

func TestTCPReceiveCloseWakesReader(t *testing.T) {
	for _, abort := range []bool{false, true} {
		p := newTCPTestPeer(t, false, true)
		done := make(chan error, 1)
		go func() { var buffer [1]byte; _, err := p.conn.Read(buffer[:]); done <- err }()
		if abort {
			p.conn.(lwip.TCPConn).Abort()
		} else {
			p.conn.(lwip.TCPConn).CloseRead()
		}
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("关闭后仍未结束读取")
			}
		case <-time.After(time.Second):
			t.Fatal("关闭没有唤醒等待中的读取")
		}
		p.close()
	}
}
