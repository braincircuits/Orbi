package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net/netip"
	"testing"
	"time"

	lwip "github.com/eycorsican/go-tun2socks/core"
	"golang.getoutline.org/sdk/network/lwip2transport"
	"golang.getoutline.org/sdk/network/packetrelay"
)

const udpTestMTU = tunMTU

// 在真实 lwIP 重组之后观察 UDP 数据报，再交给生产转发器和本机回显内核。
// 应用层回显只提供回复来源，IP 分片与重组由真实 lwIP 执行并单独断言。
type udpMTURelay struct {
	packetrelay.PacketRelay
	sent chan receivedPacket
}

func (r udpMTURelay) NewAssociation() (packetrelay.PacketSender, packetrelay.PacketReceiver, error) {
	sender, receiver, err := r.PacketRelay.NewAssociation()
	if err != nil {
		return nil, nil, err
	}
	return udpMTUSender{sender, r.sent}, receiver, nil
}

type udpMTUSender struct {
	packetrelay.PacketSender
	sent chan receivedPacket
}

func (s udpMTUSender) SendPacket(data []byte, target netip.AddrPort) error {
	select {
	case s.sent <- receivedPacket{append([]byte{}, data...), target}:
	default:
		return fmt.Errorf("UDP 测试观测队列已满，可能重复交付了数据报")
	}
	return s.PacketSender.SendPacket(data, target)
}

func udpMTUAddresses(ipv6 bool) (netip.AddrPort, netip.AddrPort) {
	if ipv6 {
		return netip.MustParseAddrPort("[fdfe:dcba:9876::2]:41235"), netip.MustParseAddrPort("[2001:db8::2]:5353")
	}
	return netip.MustParseAddrPort("198.18.0.2:41234"), netip.MustParseAddrPort("198.51.100.2:5353")
}

func udpMTUPattern(size int, seed uint32) []byte {
	data := make([]byte, size)
	state := seed + 0x12345678
	for i := range data {
		// 避免固定字节或短周期数据掩盖分片错位、串包与截断。
		state ^= state << 13
		state ^= state >> 17
		state ^= state << 5
		data[i] = byte(state >> 24)
	}
	return data
}

func udpMTUPseudo(source, target netip.Addr, udp []byte) []byte {
	pseudo := append([]byte{}, source.AsSlice()...)
	pseudo = append(pseudo, target.AsSlice()...)
	if source.Is6() {
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], uint32(len(udp)))
		pseudo = append(pseudo, length[:]...)
		pseudo = append(pseudo, 0, 0, 0, 17)
	} else {
		pseudo = append(pseudo, 0, 17, byte(len(udp)>>8), byte(len(udp)))
	}
	return append(pseudo, udp...)
}

func udpMTUPacket(ipv6 bool, data []byte) []byte {
	source, target := udpMTUAddresses(ipv6)
	udp := make([]byte, 8+len(data))
	binary.BigEndian.PutUint16(udp, source.Port())
	binary.BigEndian.PutUint16(udp[2:], target.Port())
	binary.BigEndian.PutUint16(udp[4:], uint16(len(udp)))
	copy(udp[8:], data)
	sum := checksum(udpMTUPseudo(source.Addr(), target.Addr(), udp))
	if sum == 0 {
		sum = 0xffff
	}
	binary.BigEndian.PutUint16(udp[6:], sum)
	if !ipv6 {
		return ipv4(udp, 17)
	}
	packet := make([]byte, 40+len(udp))
	packet[0], packet[6], packet[7] = 0x60, 17, 64
	binary.BigEndian.PutUint16(packet[4:], uint16(len(udp)))
	copy(packet[8:24], source.Addr().AsSlice())
	copy(packet[24:40], target.Addr().AsSlice())
	copy(packet[40:], udp)
	return packet
}

// 输入路径可比当前虚拟 MTU 更小，单独指定输入片大小以保留原来的重组回归。
// 非末片的数据长度与偏移均按 8 字节对齐。
func udpMTUFragments(packet []byte, id uint32, inputMTU int) [][]byte {
	if len(packet) <= inputMTU {
		return [][]byte{packet}
	}
	header, fragmentHeader := 20, 0
	ipv6 := packet[0]>>4 == 6
	if ipv6 {
		header, fragmentHeader = 40, 8
	}
	data := packet[header:]
	limit := (inputMTU - header - fragmentHeader) &^ 7
	var fragments [][]byte
	for offset := 0; offset < len(data); {
		n := min(limit, len(data)-offset)
		more := offset+n < len(data)
		fragment := make([]byte, header+fragmentHeader+n)
		copy(fragment, packet[:header])
		if ipv6 {
			fragment[6], fragment[40] = 44, 17
			binary.BigEndian.PutUint16(fragment[4:], uint16(8+n))
			bits := uint16(offset)
			if more {
				bits |= 1
			}
			binary.BigEndian.PutUint16(fragment[42:], bits)
			binary.BigEndian.PutUint32(fragment[44:], id)
		} else {
			binary.BigEndian.PutUint16(fragment[2:], uint16(len(fragment)))
			binary.BigEndian.PutUint16(fragment[4:], uint16(id))
			bits := uint16(offset / 8)
			if more {
				bits |= 0x2000
			}
			binary.BigEndian.PutUint16(fragment[6:], bits)
			fragment[10], fragment[11] = 0, 0
			binary.BigEndian.PutUint16(fragment[10:], checksum(fragment[:20]))
		}
		copy(fragment[header+fragmentHeader:], data[offset:offset+n])
		fragments = append(fragments, fragment)
		offset += n
	}
	return fragments
}

func udpMTUWrite(t *testing.T, device io.Writer, packet []byte) {
	t.Helper()
	if n, err := device.Write(packet); err != nil || n != len(packet) {
		t.Fatalf("写入 UDP IP 报文失败：长度=%d，返回=%d，错误=%v", len(packet), n, err)
	}
	// 分片会被 lwIP 跨调用保留；覆写输入缓冲可发现错误的引用所有权。
	clear(packet)
}

func udpMTUObserve(t *testing.T, observed <-chan receivedPacket, ipv6 bool, expected []byte) {
	t.Helper()
	_, target := udpMTUAddresses(ipv6)
	select {
	case packet := <-observed:
		// net.UDPAddr.AddrPort 会把 IPv4 的 16 字节表示保留为映射地址。
		if packet.source.Addr().Unmap() != target.Addr() || packet.source.Port() != target.Port() || !bytes.Equal(packet.data, expected) {
			t.Fatalf("lwIP 未交付完整的原 UDP 数据报：目标=%s，长度=%d，预期长度=%d", packet.source, len(packet.data), len(expected))
		}
	case <-time.After(3 * time.Second):
		t.Fatal("等待 lwIP 重组后的 UDP 数据报超时")
	}
}

func udpMTUNoDelivery(t *testing.T, observed <-chan receivedPacket) {
	t.Helper()
	select {
	case packet := <-observed:
		t.Fatalf("UDP 发生提前或重复交付：目标=%s，长度=%d", packet.source, len(packet.data))
	default:
	}
}

// 独立按 IP 偏移重组真实 lwIP 输出；不把 CONNECT 帧回显误当成 IP 分片验证。
func udpMTUReply(t *testing.T, output <-chan []byte, ipv6 bool, expected []byte) {
	t.Helper()
	local, remote := udpMTUAddresses(ipv6)
	data := make([]byte, 8+len(expected))
	covered := make([]bool, len(data))
	total, fragments := 0, 0
	var identifier uint32
	lastSeen := false
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	for total < len(data) || !lastSeen {
		var packet []byte
		select {
		case packet = <-output:
		case <-deadline.C:
			t.Fatalf("等待 UDP 回包分片超时：已重组=%d，预期=%d", total, len(data))
		}
		// 协议栈初始化的 IPv6 路由器探测不属于 UDP 回包。
		if len(packet) >= 40 && packet[0]>>4 == 6 && packet[6] == 58 {
			continue
		}
		if len(packet) < 20 || len(packet) > udpTestMTU || (packet[0]>>4 == 6) != ipv6 {
			t.Fatalf("UDP 回包 IP 地址族或长度无效：长度=%d", len(packet))
		}
		var payload []byte
		var source, target netip.Addr
		var id uint32
		offset, more, fragmented := 0, false, false
		if ipv6 {
			if len(packet) < 48 || int(binary.BigEndian.Uint16(packet[4:])) != len(packet)-40 {
				t.Fatal("IPv6 UDP 回包长度字段错误")
			}
			source, _ = netip.AddrFromSlice(packet[8:24])
			target, _ = netip.AddrFromSlice(packet[24:40])
			switch packet[6] {
			case 17:
				payload = packet[40:]
			case 44:
				if packet[40] != 17 || packet[41] != 0 {
					t.Fatal("IPv6 分片的上层协议或保留字段错误")
				}
				bits := binary.BigEndian.Uint16(packet[42:])
				if bits&6 != 0 {
					t.Fatal("IPv6 分片偏移保留位不为零")
				}
				offset, more, fragmented = int(bits&0xfff8), bits&1 != 0, true
				id = binary.BigEndian.Uint32(packet[44:])
				payload = packet[48:]
			default:
				t.Fatalf("UDP 回包出现未知 IPv6 Next Header：%d", packet[6])
			}
		} else {
			if packet[0]&15 != 5 || packet[9] != 17 || int(binary.BigEndian.Uint16(packet[2:])) != len(packet) || checksum(packet[:20]) != 0 {
				t.Fatal("IPv4 UDP 回包首部、协议或校验和错误")
			}
			source, _ = netip.AddrFromSlice(packet[12:16])
			target, _ = netip.AddrFromSlice(packet[16:20])
			bits := binary.BigEndian.Uint16(packet[6:])
			offset, more = int(bits&0x1fff)*8, bits&0x2000 != 0
			fragmented = offset != 0 || more
			id = uint32(binary.BigEndian.Uint16(packet[4:]))
			payload = packet[20:]
		}
		if source != remote.Addr() || target != local.Addr() {
			t.Fatalf("UDP 回包地址错误：%s -> %s", source, target)
		}
		header := 20
		if ipv6 {
			header = 40
		}
		if fragmented != (header+len(data) > udpTestMTU) {
			t.Fatalf("UDP 分片未遵守 MTU=%d：UDP长度=%d，分片=%t", udpTestMTU, len(data), fragmented)
		}
		if fragments > 0 && id != identifier {
			t.Fatal("同一 UDP 回包的分片标识发生变化")
		}
		identifier = id
		fragments++
		if more && len(payload)%8 != 0 {
			t.Fatal("非末尾 IP 分片长度未按 8 字节对齐")
		}
		if offset+len(payload) > len(data) || (!more && offset+len(payload) != len(data)) {
			t.Fatal("UDP 回包分片偏移或最终长度错误")
		}
		for i, value := range payload {
			position := offset + i
			if covered[position] {
				t.Fatal("UDP 回包 IP 分片重复覆盖数据")
			}
			covered[position], data[position] = true, value
			total++
		}
		lastSeen = lastSeen || !more
	}
	if binary.BigEndian.Uint16(data) != remote.Port() || binary.BigEndian.Uint16(data[2:]) != local.Port() || int(binary.BigEndian.Uint16(data[4:])) != len(data) {
		t.Fatal("重组后的 UDP 端口或长度错误")
	}
	if binary.BigEndian.Uint16(data[6:]) == 0 || checksum(udpMTUPseudo(remote.Addr(), local.Addr(), data)) != 0 {
		t.Fatal("重组后的 UDP 伪首部校验和错误")
	}
	if !bytes.Equal(data[8:], expected) {
		t.Fatal("重组后的 UDP 数据被截断、错位或混入其他数据报")
	}
	// 输出片数按当前 MTU 独立计算；旧 4096 字节输入仍可分片，回包则允许成为完整一包。
	header, fragmentHeader := 20, 0
	if ipv6 {
		header, fragmentHeader = 40, 8
	}
	expectedFragments := 1
	if header+len(data) > udpTestMTU {
		limit := (udpTestMTU - header - fragmentHeader) &^ 7
		expectedFragments = (len(data) + limit - 1) / limit
	}
	if fragments != expectedFragments {
		t.Fatalf("UDP 输出片数错误：载荷=%d，得到=%d，预期=%d", len(expected), fragments, expectedFragments)
	}
}

func TestUDPMTUFragmentationAndReassembly(t *testing.T) {
	dialer, requests := echoKernel(t)
	ctx, cancel := context.WithCancel(context.Background())
	observed := make(chan receivedPacket, 32)
	device, err := lwip2transport.ConfigureDeviceWithRelay(dialer, udpMTURelay{udpRelay{dialer, ctx}, observed})
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	t.Cleanup(func() { cancel(); device.Close() })
	output := make(chan []byte, 64)
	lwip.RegisterOutputFn(func(packet []byte) (int, error) {
		select {
		case output <- append([]byte(nil), packet...):
			return len(packet), nil
		case <-ctx.Done():
			return 0, ctx.Err()
		}
	})
	for _, ipv6 := range []bool{false, true} {
		family, sizes := "IPv4", []int{0, 1472, 1473, 2020, 2021, 4096}
		if ipv6 {
			family, sizes = "IPv6", []int{0, 1452, 1453, 2000, 2001, 4096}
		}
		if udpTestMTU >= 8192 {
			if ipv6 {
				sizes = append(sizes, 8144, 8145, 16384)
			} else {
				sizes = append(sizes, 8164, 8165, 16384)
			}
		}
		t.Run(family, func(t *testing.T) {
			for _, size := range sizes {
				t.Run(fmt.Sprintf("边界%d", size), func(t *testing.T) {
					data := udpMTUPattern(size, uint32(size))
					for _, fragment := range udpMTUFragments(udpMTUPacket(ipv6, data), uint32(100+size), udpTestMTU) {
						udpMTUWrite(t, device, fragment)
					}
					udpMTUObserve(t, observed, ipv6, data)
					udpMTUReply(t, output, ipv6, data)
					udpMTUNoDelivery(t, observed)
					if size == 0 {
						_, target := udpMTUAddresses(ipv6)
						select {
						case got := <-requests:
							if got != target.String() {
								t.Fatalf("UDP CONNECT 目标错误：%s", got)
							}
						case <-time.After(3 * time.Second):
							t.Fatal("未收到 UDP CONNECT 请求")
						}
					}
				})
			}
			// 旧 1500/2048 输入片继续覆盖，新增大 MTU 下两条三片报文的交错重组。
			cases := []struct{ size, inputMTU int }{{4096, 1500}, {4096, 2048}}
			if udpTestMTU >= 8192 {
				cases = append(cases, struct{ size, inputMTU int }{16384, 8192})
			}
			for _, tc := range cases {
				t.Run(fmt.Sprintf("交错乱序%d/输入MTU%d", tc.size, tc.inputMTU), func(t *testing.T) {
					first, second := udpMTUPattern(tc.size, 10001), udpMTUPattern(tc.size, 10002)
					a := udpMTUFragments(udpMTUPacket(ipv6, first), 51001, tc.inputMTU)
					b := udpMTUFragments(udpMTUPacket(ipv6, second), 51002, tc.inputMTU)
					if len(a) != 3 || len(b) != 3 {
						t.Fatal("测试输入没有产生三片 UDP 数据报")
					}
					for _, fragment := range [][]byte{a[2], b[1], a[0], b[2]} {
						udpMTUWrite(t, device, fragment)
						udpMTUNoDelivery(t, observed)
					}
					udpMTUWrite(t, device, a[1])
					udpMTUObserve(t, observed, ipv6, first)
					udpMTUReply(t, output, ipv6, first)
					udpMTUNoDelivery(t, observed)
					// 第二条仍缺片时，普通 UDP 仍须正常推进，不能被重组队列阻塞。
					marker := udpMTUPattern(37, 10003)
					udpMTUWrite(t, device, udpMTUPacket(ipv6, marker))
					udpMTUObserve(t, observed, ipv6, marker)
					udpMTUReply(t, output, ipv6, marker)
					udpMTUNoDelivery(t, observed)
					udpMTUWrite(t, device, b[0])
					udpMTUObserve(t, observed, ipv6, second)
					udpMTUReply(t, output, ipv6, second)
					udpMTUNoDelivery(t, observed)
				})
			}
		})
	}
}
