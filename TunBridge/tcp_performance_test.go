package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	lwip "github.com/eycorsican/go-tun2socks/core"
)

type tcpTestHandler struct{ accepted chan net.Conn }

func (h tcpTestHandler) Handle(conn net.Conn, _ *net.TCPAddr) error {
	h.accepted <- conn
	return nil
}

type tcpOutput struct {
	packet []byte
	at     time.Time
}

// 使用真实 lwIP 与 IP 报文测试窗口、数据完整性，不改动系统路由。
type tcpTestPeer struct {
	t                                               testing.TB
	stack                                           io.WriteCloser
	output                                          chan tcpOutput
	conn                                            net.Conn
	makePacket                                      func(uint32, uint32, byte, []byte) []byte
	sequence, acknowledgement, acknowledged, window uint32
	scale                                           uint
	mss                                             uint16
	close                                           func()
}

func tcpHeader(packet []byte) []byte {
	if packet[0]>>4 == 6 {
		return packet[40:]
	}
	return packet[int(packet[0]&15)*4:]
}

var tcpTestPort uint16 = 41000

func newTCPTestPeer(t testing.TB, ipv6, scaling bool, outputMode ...string) *tcpTestPeer {
	t.Helper()
	// 既有测试仍不声明 MSS，并保持 upload 中固定 1460 字节的分段方式。
	return newTCPTestPeerWithMSS(t, ipv6, scaling, 0, outputMode...)
}

func newTCPTestPeerWithMSS(t testing.TB, ipv6, scaling bool, peerMSS uint16, outputMode ...string) *tcpTestPeer {
	t.Helper()
	p := &tcpTestPeer{t: t, output: make(chan tcpOutput, 16384), makePacket: tcpPacket, sequence: 101, acknowledged: 101}
	if ipv6 {
		p.makePacket = tcpPacket6
	}
	// 每次使用独立四元组，避免 FIN 测试留下的 TIME_WAIT 干扰后续连接。
	tcpTestPort++
	port, makePacket := tcpTestPort, p.makePacket
	p.makePacket = func(sequence, acknowledgement uint32, flags byte, payload []byte) []byte {
		packet := makePacket(sequence, acknowledgement, flags, payload)
		header := tcpHeader(packet)
		oldPort := binary.BigEndian.Uint16(header)
		oldChecksum := binary.BigEndian.Uint16(header[16:])
		sum := uint32(^oldChecksum) + uint32(^oldPort) + uint32(port)
		for sum > 65535 {
			sum = sum&65535 + sum>>16
		}
		binary.BigEndian.PutUint16(header, port)
		binary.BigEndian.PutUint16(header[16:], ^uint16(sum))
		return packet
	}
	accepted := make(chan net.Conn, 1)
	output := func(packet []byte) (int, error) {
		// 保留 IPv6 分片输出，让 MTU 测试明确报告意外分片，避免过滤后只表现为超时。
		if (packet[0]>>4 == 4 && packet[9] == 6) || (packet[0]>>4 == 6 && (packet[6] == 6 || packet[6] == 44)) {
			p.output <- tcpOutput{append([]byte(nil), packet...), time.Now()}
		}
		return len(packet), nil
	}
	if len(outputMode) > 0 && outputMode[0] != "" {
		p.stack = newTCPOutputStack(t, output, outputMode[0])
	} else {
		lwip.RegisterOutputFn(output)
		p.stack = lwip.NewLWIPStack()
	}
	lwip.RegisterTCPConnHandler(tcpTestHandler{accepted})
	p.close = sync.OnceFunc(func() { p.stack.Close() })
	t.Cleanup(p.close)
	syn := p.makePacket(100, 0, 2, nil)
	var synOptions []byte
	if peerMSS != 0 {
		synOptions = append(synOptions, 2, 4, byte(peerMSS>>8), byte(peerMSS))
	}
	if scaling {
		// SYN 中协商窗口缩放；SYN 本身的窗口字段不缩放。
		synOptions = append(synOptions, 1, 3, 3, 5)
	}
	if len(synOptions) > 0 {
		syn = append(syn, synOptions...)
		tcp := tcpHeader(syn)
		tcp[12] = byte((20 + len(synOptions)) / 4 << 4)
		if ipv6 {
			binary.BigEndian.PutUint16(syn[4:], uint16(len(syn)-40))
		} else {
			binary.BigEndian.PutUint16(syn[2:], uint16(len(syn)))
		}
		tcp[16], tcp[17] = 0, 0
		var pseudo []byte
		if ipv6 {
			pseudo = append(pseudo, syn[8:40]...)
			pseudo = append(pseudo, 0, 0, 0, byte(len(tcp)), 0, 0, 0, 6)
		} else {
			syn[10], syn[11] = 0, 0
			binary.BigEndian.PutUint16(syn[10:], checksum(syn[:20]))
			pseudo = append(pseudo, syn[12:20]...)
			pseudo = append(pseudo, 0, 6, 0, byte(len(tcp)))
		}
		pseudo = append(pseudo, tcp...)
		binary.BigEndian.PutUint16(tcp[16:], checksum(pseudo))
	}
	p.write(syn)
	synAck := tcpHeader(p.next(0).packet)
	if synAck[13]&0x12 != 0x12 {
		t.Fatal("未收到 TCP SYN ACK")
	}
	p.acknowledgement = binary.BigEndian.Uint32(synAck[4:]) + 1
	p.window = uint32(binary.BigEndian.Uint16(synAck[14:]))
	options := synAck[20 : int(synAck[12]>>4)*4]
	for len(options) > 0 && options[0] != 0 {
		if options[0] == 1 {
			options = options[1:]
			continue
		}
		if len(options) < 2 || int(options[1]) > len(options) || options[1] < 2 {
			t.Fatal("TCP 选项长度无效")
		}
		if options[0] == 3 && options[1] == 3 {
			p.scale = uint(options[2])
		}
		if options[0] == 2 && options[1] == 4 {
			p.mss = binary.BigEndian.Uint16(options[2:4])
		}
		options = options[options[1]:]
	}
	p.write(p.makePacket(p.sequence, p.acknowledgement, 0x10, nil))
	select {
	case p.conn = <-accepted:
	case <-time.After(3 * time.Second):
		t.Fatal("TCP 未交给转发处理器")
	}
	return p
}

func (p *tcpTestPeer) write(packet []byte) {
	p.t.Helper()
	if _, err := p.stack.Write(packet); err != nil {
		p.t.Fatal(err)
	}
}

func (p *tcpTestPeer) next(delay time.Duration) tcpOutput {
	p.t.Helper()
	select {
	case packet := <-p.output:
		if remaining := time.Until(packet.at.Add(delay)); remaining > 0 {
			time.Sleep(remaining)
		}
		return packet
	case <-time.After(5 * time.Second):
		p.t.Fatal("等待 TCP 报文超时")
	}
	return tcpOutput{}
}

func (p *tcpTestPeer) upload(data []byte, delay time.Duration) {
	p.t.Helper()
	result := make(chan error, 1)
	go func() {
		received := make([]byte, len(data))
		_, err := io.ReadFull(p.conn, received)
		if err == nil && !bytes.Equal(received, data) {
			err = io.ErrUnexpectedEOF
		}
		result <- err
	}()
	for sent := 0; sent < len(data); {
		for sent < len(data) && p.sequence < p.acknowledged+p.window {
			n := min(1460, len(data)-sent, int(p.acknowledged+p.window-p.sequence))
			p.write(p.makePacket(p.sequence, p.acknowledgement, 0x18, data[sent:sent+n]))
			p.sequence += uint32(n)
			sent += n
		}
		// 收端确认收到全部数据即可结束，避免把最后一个延迟 ACK 算成传输耗时。
		if sent == len(data) {
			break
		}
		header := tcpHeader(p.next(delay).packet)
		if header[13]&4 != 0 {
			p.t.Fatal("上传期间连接被重置")
		}
		p.acknowledged = binary.BigEndian.Uint32(header[8:])
		p.window = uint32(binary.BigEndian.Uint16(header[14:])) << p.scale
	}
	if err := <-result; err != nil {
		p.t.Fatalf("上传内容不完整：%v", err)
	}
}

func TestTCPWindowAndLargeWrite(t *testing.T) {
	for _, mode := range []string{"", "direct"} {
		for _, ipv6 := range []bool{false, true} {
			for _, scaling := range []bool{false, true} {
				name := mode + "IPv4"
				if ipv6 {
					name = mode + "IPv6"
				}
				if scaling {
					name += "窗口缩放"
				} else {
					name += "普通窗口"
				}
				t.Run(name, func(t *testing.T) {
					p := newTCPTestPeer(t, ipv6, scaling, mode)
					data := make([]byte, 256*1024+17)
					for i := range data {
						data[i] = byte(i * 31)
					}
					p.upload(data, 0)
					if scaling && (p.scale == 0 || p.window < 256*1024) {
						t.Fatalf("未启用大 TCP 窗口：缩放=%d，窗口=%d", p.scale, p.window)
					}
					if !scaling && (p.scale != 0 || p.window > 65535) {
						t.Fatal("未协商缩放时窗口超出协议范围")
					}
					// 单次写入超过 65535 字节，检查 C 接口长度截断与剩余数据处理。
					written := make(chan error, 1)
					go func() {
						n, err := p.conn.Write(data)
						if err == nil && n != len(data) {
							err = io.ErrShortWrite
						}
						written <- err
					}()
					var received []byte
					for len(received) < len(data) {
						header := tcpHeader(p.next(0).packet)
						payload := header[int(header[12]>>4)*4:]
						if len(payload) == 0 {
							continue
						}
						if binary.BigEndian.Uint32(header[4:]) != p.acknowledgement {
							t.Fatal("下行序列不连续")
						}
						received = append(received, payload...)
						p.acknowledgement += uint32(len(payload))
						p.write(p.makePacket(p.sequence, p.acknowledgement, 0x10, nil))
					}
					if !bytes.Equal(received, data) {
						t.Fatal("大块下行数据被截断或损坏")
					}
					if err := <-written; err != nil {
						t.Fatal(err)
					}
				})
			}
		}
	}

	// 固定 5 毫秒确认延迟对比窗口利用率；不代表真实局域网或远程桌面文件复制速度。
}

func BenchmarkTCPUpload(b *testing.B) {
	data := make([]byte, 4*1024*1024)
	for i := range data {
		data[i] = byte(i * 31)
	}
	b.SetBytes(int64(len(data)))
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		p := newTCPTestPeer(b, false, true)
		p.upload([]byte{1}, 0)
		b.StartTimer()
		p.upload(data, 5*time.Millisecond)
		b.StopTimer()
		p.close()
	}
}
