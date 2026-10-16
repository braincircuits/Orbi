package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand"
	"testing"
	"time"
)

// 固定种子生成非固定周期的测试数据，避免重复内容掩盖丢段、重复或错序。
func tcpMTUPayload(size int) []byte {
	data := make([]byte, size)
	rand.New(rand.NewSource(20261016)).Read(data)
	return data
}

// 同时检查 IP 长度和分片标记，不能只从重组后的 TCP 载荷判断是否符合 MTU。
func tcpMTUHeader(t *testing.T, packet []byte, ipv6 bool) []byte {
	t.Helper()
	if len(packet) > tunMTU {
		t.Fatalf("TCP 输出超过虚拟 MTU：报文=%d，MTU=%d", len(packet), tunMTU)
	}
	if ipv6 {
		if len(packet) < 60 || packet[0]>>4 != 6 || int(binary.BigEndian.Uint16(packet[4:6])) != len(packet)-40 {
			t.Fatal("IPv6 TCP 报文长度或版本错误")
		}
		if packet[6] != 6 {
			t.Fatalf("TCP 不应携带 IPv6 分片或扩展首部：Next Header=%d", packet[6])
		}
	} else {
		if len(packet) < 40 || packet[0]>>4 != 4 || int(binary.BigEndian.Uint16(packet[2:4])) != len(packet) {
			t.Fatal("IPv4 TCP 报文长度或版本错误")
		}
		if packet[9] != 6 || binary.BigEndian.Uint16(packet[6:8])&0x3fff != 0 {
			t.Fatal("TCP 输出不是完整且未分片的 IPv4 报文")
		}
	}
	header := tcpHeader(packet)
	if len(header) < 20 || int(header[12]>>4)*4 < 20 || int(header[12]>>4)*4 > len(header) {
		t.Fatal("TCP 首部长度无效")
	}
	return header
}

func TestTCPMTUSYNAndSinglePacketUpload(t *testing.T) {
	for _, mode := range []string{"", "direct"} {
		for _, ipv6 := range []bool{false, true} {
			family, headerSize := "IPv4", 40
			if ipv6 {
				family, headerSize = "IPv6", 60
			}
			expectedMSS := uint16(tunMTU - headerSize)
			// 保留实际复制的 1645 字节和原 1500/2048 边界，再验证当前 MTU 的完整单包。
			sizes := []int{1645, 1500 - headerSize, 1501 - headerSize, 2048 - headerSize}
			if tunMTU > 2048 {
				sizes = append(sizes, 2049-headerSize, tunMTU-headerSize)
			}
			for _, size := range sizes {
				t.Run(fmt.Sprintf("%s%s/单包%d", mode, family, size), func(t *testing.T) {
					p := newTCPTestPeerWithMSS(t, ipv6, true, expectedMSS, mode)
					if p.mss != expectedMSS {
						t.Fatalf("SYN ACK 的 MSS 错误：得到=%d，预期=%d", p.mss, expectedMSS)
					}
					data := tcpMTUPayload(size)
					packet := p.makePacket(p.sequence, p.acknowledgement, 0x18, data)
					header := tcpMTUHeader(t, packet, ipv6)
					if payload := header[int(header[12]>>4)*4:]; !bytes.Equal(payload, data) {
						t.Fatalf("单个 IP 报文未包含完整的 %d 字节载荷", size)
					}
					// 明确只提交一次 IP 包，不使用旧 upload 的 1460 字节分段逻辑。
					if n, err := p.stack.Write(packet); err != nil || n != len(packet) {
						t.Fatalf("提交单个 IP 报文失败：写入=%d，预期=%d，错误=%v", n, len(packet), err)
					}
					p.sequence += uint32(len(data))
					received := make([]byte, len(data))
					read := make(chan error, 1)
					go func() {
						_, err := io.ReadFull(p.conn, received)
						read <- err
					}()
					select {
					case err := <-read:
						if err != nil || !bytes.Equal(received, data) {
							t.Fatalf("单包上传内容损坏或不完整：错误=%v", err)
						}
					case <-time.After(3 * time.Second):
						t.Fatal("单包上传未交给转发连接")
					}
					ack := tcpMTUHeader(t, p.next(0).packet, ipv6)
					if ack[13]&0x14 != 0x10 || binary.BigEndian.Uint32(ack[8:12]) != p.sequence {
						t.Fatalf("协议栈未确认完整的 %d 字节单包", size)
					}
				})
			}
		}
	}
}

func TestTCPMTUDownloadRespectsPeerMSS(t *testing.T) {
	for _, mode := range []string{"", "direct"} {
		for _, ipv6 := range []bool{false, true} {
			family, headerSize := "IPv4", 40
			if ipv6 {
				family, headerSize = "IPv6", 60
			}
			// 小 MSS、原两档 MTU 和当前 MTU 都必须约束真实输出段长。
			peerMSSValues := []uint16{536, 1200, uint16(1500 - headerSize), uint16(2048 - headerSize)}
			if tunMTU > 2048 {
				peerMSSValues = append(peerMSSValues, uint16(tunMTU-headerSize))
			}
			for _, peerMSS := range peerMSSValues {
				t.Run(fmt.Sprintf("%s%s/MSS%d", mode, family, peerMSS), func(t *testing.T) {
					p := newTCPTestPeerWithMSS(t, ipv6, true, peerMSS, mode)
					data := tcpMTUPayload(4*int(peerMSS) + 37)
					written := make(chan error, 1)
					go func() {
						n, err := p.conn.Write(data)
						if err == nil && n != len(data) {
							err = io.ErrShortWrite
						}
						written <- err
					}()
					var received []byte
					maxPayload := 0
					for len(received) < len(data) {
						header := tcpMTUHeader(t, p.next(0).packet, ipv6)
						if header[13]&4 != 0 {
							t.Fatal("下载期间连接被重置")
						}
						payload := header[int(header[12]>>4)*4:]
						if len(payload) == 0 {
							continue
						}
						if len(payload) > int(peerMSS) {
							t.Fatalf("下载超过对端 MSS：载荷=%d，MSS=%d", len(payload), peerMSS)
						}
						maxPayload = max(maxPayload, len(payload))
						if binary.BigEndian.Uint32(header[4:8]) != p.acknowledgement {
							t.Fatal("下载 TCP 序列不连续")
						}
						received = append(received, payload...)
						p.acknowledgement += uint32(len(payload))
						p.write(p.makePacket(p.sequence, p.acknowledgement, 0x10, nil))
					}
					if !bytes.Equal(received, data) {
						t.Fatal("下载内容损坏、重复或不完整")
					}
					// 验证测试 SYN 的 MSS 选项实际生效，避免始终沿用默认 536 而误通过。
					if maxPayload != int(peerMSS) {
						t.Fatalf("未观察到协商的完整 TCP 段：最大载荷=%d，MSS=%d", maxPayload, peerMSS)
					}
					select {
					case err := <-written:
						if err != nil {
							t.Fatal(err)
						}
					case <-time.After(3 * time.Second):
						t.Fatal("下载写入未完成")
					}
				})
			}
		}
	}
}
