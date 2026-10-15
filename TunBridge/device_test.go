package main

import (
	"context"
	"encoding/binary"
	"net/netip"
	"testing"
	"time"

	"golang.getoutline.org/sdk/network/lwip2transport"
)

func checksum(data []byte) uint16 {
	var sum uint32
	for len(data) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}
	if len(data) == 1 {
		sum += uint32(data[0]) << 8
	}
	for sum > 65535 {
		sum = sum&65535 + sum>>16
	}
	return ^uint16(sum)
}
func ipv4(payload []byte, protocol byte) []byte {
	packet := make([]byte, 20+len(payload))
	packet[0] = 0x45
	packet[8] = 64
	packet[9] = protocol
	binary.BigEndian.PutUint16(packet[2:], uint16(len(packet)))
	copy(packet[12:], []byte{198, 18, 0, 2, 198, 51, 100, 2})
	binary.BigEndian.PutUint16(packet[10:], checksum(packet[:20]))
	copy(packet[20:], payload)
	return packet
}
func tcpPacket(sequence, acknowledgement uint32, flags byte, payload []byte) []byte {
	tcp := make([]byte, 20+len(payload))
	binary.BigEndian.PutUint16(tcp, 40000)
	binary.BigEndian.PutUint16(tcp[2:], 80)
	binary.BigEndian.PutUint32(tcp[4:], sequence)
	binary.BigEndian.PutUint32(tcp[8:], acknowledgement)
	tcp[12] = 0x50
	tcp[13] = flags
	binary.BigEndian.PutUint16(tcp[14:], 65535)
	copy(tcp[20:], payload)
	pseudo := []byte{198, 18, 0, 2, 198, 51, 100, 2, 0, 6, byte(len(tcp) >> 8), byte(len(tcp))}
	pseudo = append(pseudo, tcp...)
	binary.BigEndian.PutUint16(tcp[16:], checksum(pseudo))
	return ipv4(tcp, 6)
}

func tcpPacket6(sequence, acknowledgement uint32, flags byte, payload []byte) []byte {
	tcp := tcpPacket(sequence, acknowledgement, flags, payload)[20:]
	binary.BigEndian.PutUint16(tcp, 40001)
	tcp[16], tcp[17] = 0, 0
	packet := make([]byte, 40+len(tcp))
	packet[0], packet[6], packet[7] = 0x60, 6, 64
	binary.BigEndian.PutUint16(packet[4:], uint16(len(tcp)))
	copy(packet[8:24], netip.MustParseAddr("fdfe:dcba:9876::2").AsSlice())
	copy(packet[24:40], netip.MustParseAddr("2001:db8::2").AsSlice())
	pseudo := append([]byte{}, packet[8:40]...)
	pseudo = append(pseudo, 0, 0, byte(len(tcp)>>8), byte(len(tcp)), 0, 0, 0, 6)
	pseudo = append(pseudo, tcp...)
	binary.BigEndian.PutUint16(tcp[16:], checksum(pseudo))
	copy(packet[40:], tcp)
	return packet
}

func TestOutlineTranslatesActualIPPackets(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	dialer, requests := selectiveEchoKernel(t, "198.51.100.2:443", release)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	device, err := lwip2transport.ConfigureDeviceWithRelay(dialer, udpRelay{dialer, ctx})
	if err != nil {
		t.Fatal(err)
	}
	defer device.Close()
	packets := make(chan []byte, 30)
	go func() {
		for {
			buffer := make([]byte, 1500)
			n, err := device.Read(buffer)
			if err != nil {
				return
			}
			select {
			case packets <- buffer[:n]:
			case <-ctx.Done():
				return
			}
		}
	}()
	next := func() []byte {
		deadline := time.After(3 * time.Second)
		for {
			select {
			case packet := <-packets:
				// lwIP 初始化 IPv6 时还会产生路由器探测包，不属于业务回包。
				if len(packet) >= 40 && packet[0]>>4 == 6 && packet[6] == 58 {
					continue
				}
				return packet
			case <-deadline:
				t.Fatal("Outline 未返回 IP 报文")
				return nil
			}
		}
	}
	udp := []byte{0x9c, 0x40, 0, 53, 0, 11, 0, 0, 1, 2, 3}
	if _, err := device.Write(ipv4(udp, 17)); err != nil {
		t.Fatal(err)
	}
	reply := next()
	if reply[9] != 17 || string(reply[len(reply)-3:]) != string([]byte{1, 2, 3}) {
		t.Fatal("Outline UDP 回包错误")
	}
	if target := <-requests; target != "198.51.100.2:53" {
		t.Fatalf("UDP 目标错误：%s", target)
	}
	// IPv6 UDP 必须携带伪首部校验和，验证真实协议栈的双栈收发。
	packet6 := make([]byte, 40+len(udp))
	packet6[0], packet6[6], packet6[7] = 0x60, 17, 64
	binary.BigEndian.PutUint16(packet6[4:], uint16(len(udp)))
	copy(packet6[8:24], netip.MustParseAddr("fdfe:dcba:9876::2").AsSlice())
	copy(packet6[24:40], netip.MustParseAddr("2001:db8::2").AsSlice())
	copy(packet6[40:], udp)
	pseudo := append([]byte{}, packet6[8:40]...)
	pseudo = append(pseudo, 0, 0, 0, byte(len(udp)), 0, 0, 0, 17)
	pseudo = append(pseudo, udp...)
	binary.BigEndian.PutUint16(packet6[46:], checksum(pseudo))
	if _, err := device.Write(packet6); err != nil {
		t.Fatal(err)
	}
	select {
	case target := <-requests:
		if target != "[2001:db8::2]:53" {
			t.Fatalf("IPv6 UDP 目标错误：%s", target)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("IPv6 UDP 未发起 CONNECT")
	}
	reply6 := next()
	if reply6[0]>>4 != 6 || reply6[6] != 17 || string(reply6[len(reply6)-3:]) != string([]byte{1, 2, 3}) {
		t.Fatalf("Outline IPv6 UDP 回包错误：%x", reply6)
	}
	// 两个地址族的空 UDP 必须真实产生长度为零的回包。
	empty4 := ipv4([]byte{0x9c, 0x40, 0, 53, 0, 8, 0, 0}, 17)
	empty6 := append([]byte{}, packet6[:48]...)
	binary.BigEndian.PutUint16(empty6[4:], 8)
	binary.BigEndian.PutUint16(empty6[44:], 8)
	empty6[46], empty6[47] = 0, 0
	pseudo = append([]byte{}, empty6[8:40]...)
	pseudo = append(pseudo, 0, 0, 0, 8, 0, 0, 0, 17)
	pseudo = append(pseudo, empty6[40:]...)
	binary.BigEndian.PutUint16(empty6[46:], checksum(pseudo))
	for _, packet := range [][]byte{empty4, empty6} {
		if _, err := device.Write(packet); err != nil {
			t.Fatal(err)
		}
		reply := next()
		if len(reply) != len(packet) || reply[0]>>4 != packet[0]>>4 {
			t.Fatalf("空 UDP 回包错误：%x", reply)
		}
	}
	// 已建立的 UDP 来源新增一个一直等待 CONNECT 的目标，模拟代理流额度耗尽。
	// 后续 UDP 和两个地址族的 TCP 都必须继续通过同一个 lwIP 协议栈。
	blocked := append([]byte{}, udp...)
	binary.BigEndian.PutUint16(blocked[2:], 443)
	written := make(chan error, 1)
	go func() { _, err := device.Write(ipv4(blocked, 17)); written <- err }()
	select {
	case err := <-written:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		// 先解除等待，以便旧实现失败时仍能正常退出测试。
		cancel()
		t.Fatal("UDP CONNECT 等待阻塞了整个 TUN 输入")
	}
	select {
	case target := <-requests:
		if target != "198.51.100.2:443" {
			t.Fatalf("阻塞目标错误：%s", target)
		}
	case <-time.After(time.Second):
		t.Fatal("未发起阻塞目标的 CONNECT")
	}
	if _, err := device.Write(ipv4(udp, 17)); err != nil {
		t.Fatal(err)
	}
	if reply := next(); reply[9] != 17 || string(reply[len(reply)-3:]) != string([]byte{1, 2, 3}) {
		t.Fatal("代理等待期间其他 UDP 目标未正常回包")
	}
	for family, makePacket := range []func(uint32, uint32, byte, []byte) []byte{tcpPacket, tcpPacket6} {
		if _, err := device.Write(makePacket(100, 0, 2, nil)); err != nil {
			t.Fatal(err)
		}
		headerSize := func(packet []byte) int {
			if packet[0]>>4 == 6 {
				return 40
			}
			return int(packet[0]&15) * 4
		}
		synAck := next()
		offset := headerSize(synAck)
		if synAck[offset+13]&0x12 != 0x12 {
			t.Fatal("未收到 TCP SYN ACK")
		}
		serverSeq := binary.BigEndian.Uint32(synAck[offset+4:]) + 1
		device.Write(makePacket(101, serverSeq, 0x10, nil))
		device.Write(makePacket(101, serverSeq, 0x18, []byte("hello")))
		for {
			packet := next()
			start := headerSize(packet)
			payload := start + int(packet[start+12]>>4)*4
			if payload < len(packet) {
				if string(packet[payload:]) != "hello" {
					t.Fatal("Outline TCP 回包错误")
				}
				device.Write(makePacket(106, binary.BigEndian.Uint32(packet[start+4:])+5, 0x10, nil))
				break
			}
		}
		expected := []string{"198.51.100.2:80", "[2001:db8::2]:80"}[family]
		if target := <-requests; target != expected {
			t.Fatalf("TCP 目标错误：%s", target)
		}
	}
}
