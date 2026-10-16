package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"time"

	"github.com/xjasonlyu/tun2socks/v2/core"
	"github.com/xjasonlyu/tun2socks/v2/core/adapter"
	"github.com/xjasonlyu/tun2socks/v2/core/device/iobased"
	"github.com/xjasonlyu/tun2socks/v2/core/option"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// 使用官方 I/O 接口和默认协议栈设置，仅适配现有 TUN 与本机 CONNECT。
type tun2socksSession struct {
	stack  *stack.Stack
	link   *iobased.Endpoint
	cancel context.CancelFunc
}

func startTun2socks(parent context.Context, dialer localDialer, tun io.ReadWriter) (io.Closer, <-chan error, error) {
	ctx, cancel := context.WithCancel(parent)
	stopped := make(chan error, 2)
	link, err := iobased.New(observedPacketIO{tun, stopped}, tunMTU, 0)
	if err != nil {
		cancel()
		return nil, nil, err
	}
	handler := &tun2socksHandler{ctx, dialer}
	network, err := core.CreateStack(&core.Config{
		LinkEndpoint: link, TransportHandler: handler, ICMPHandler: handler,
		Options: []option.Option{func(s *stack.Stack) error {
			// 官方 ICMPHandler 仅注册 IPv4；通过公开选项在网卡启动前拦截 IPv6 Echo，避免本机伪造远端回包。
			s.SetTransportProtocolHandler(header.ICMPv6ProtocolNumber, func(_ stack.TransportEndpointID, packet *stack.PacketBuffer) bool {
				// 此处借用原始报文，生命周期由协议栈管理；其他 ICMPv6 仍由协议栈处理。
				return header.ICMPv6(packet.TransportHeader().Slice()).Type() == header.ICMPv6EchoRequest
			})
			return nil
		}},
	})
	if err != nil {
		cancel()
		link.Close()
		return nil, nil, fmt.Errorf("初始化 xjasonlyu/tun2socks 失败：%w", err)
	}
	return &tun2socksSession{network, link, cancel}, stopped, nil
}

func (s *tun2socksSession) Close() error {
	s.cancel()
	s.stack.Close()
	s.link.Close()
	s.stack.Wait()
	s.link.Wait()
	return nil
}

// 官方接口内部处理读写循环；将设备异常交给会话统一清理路由。
type observedPacketIO struct {
	io.ReadWriter
	stopped chan<- error
}

func (p observedPacketIO) report(err error) {
	if err != nil {
		select {
		case p.stopped <- err:
		default:
		}
	}
}
func (p observedPacketIO) Read(data []byte) (int, error) {
	n, err := p.ReadWriter.Read(data)
	p.report(err)
	return n, err
}
func (p observedPacketIO) Write(data []byte) (int, error) {
	n, err := p.ReadWriter.Write(data)
	if err == nil && n != len(data) {
		err = io.ErrShortWrite
	}
	p.report(err)
	return n, err
}

type tun2socksHandler struct {
	context context.Context
	dialer  localDialer
}

// 当前内核只转发 TCP/UDP，不把本机生成的 ICMP 回答当作远端可达性。
func (*tun2socksHandler) HandlePacket(packet adapter.Packet) bool {
	packet.Buffer().DecRef()
	return true
}

func (h *tun2socksHandler) HandleTCP(conn adapter.TCPConn) {
	go func() {
		defer conn.Close()
		stop := context.AfterFunc(h.context, func() { conn.Close() })
		defer stop()
		id := conn.ID()
		target := net.JoinHostPort(id.LocalAddress.String(), fmt.Sprint(id.LocalPort))
		remote, err := h.dialer.connect(h.context, target, false)
		if err != nil {
			if h.context.Err() == nil {
				log.Printf("TCP 目标连接失败：目标=%s，原因=%v", target, err)
			}
			return
		}
		defer remote.Close()
		stopRemote := context.AfterFunc(h.context, func() { remote.Close() })
		defer stopRemote()
		// 两个方向独立排空；正常 EOF 只关闭写侧，让半关闭后的响应继续返回。
		done := make(chan struct{})
		go func() {
			_, err := io.Copy(remote, conn)
			remote.CloseWrite()
			if err != nil {
				remote.Close()
				conn.Close()
			}
			close(done)
		}()
		_, err = io.Copy(conn, remote)
		if half, ok := conn.(interface{ CloseWrite() error }); ok {
			half.CloseWrite()
		}
		if err != nil {
			remote.Close()
			conn.Close()
		}
		<-done
	}()
}

func (h *tun2socksHandler) HandleUDP(conn adapter.UDPConn) {
	go func() {
		defer conn.Close()
		stop := context.AfterFunc(h.context, func() { conn.Close() })
		defer stop()
		id := conn.ID()
		target := net.JoinHostPort(id.LocalAddress.String(), fmt.Sprint(id.LocalPort))
		remote, err := h.dialer.connect(h.context, target, true)
		if err != nil {
			if h.context.Err() == nil {
				log.Printf("UDP 目标连接失败：目标=%s，原因=%v", target, err)
			}
			return
		}
		defer remote.Close()
		stopRemote := context.AfterFunc(h.context, func() { remote.Close() })
		defer stopRemote()
		// 每个来源/目标对应一条内核 UDP CONNECT，空报文和报文边界原样保留。
		done := make(chan struct{})
		go func() {
			defer close(done)
			defer conn.Close()
			for {
				data, err := readDatagram(remote)
				if err != nil {
					return
				}
				conn.SetReadDeadline(time.Now().Add(60 * time.Second))
				if _, err = conn.Write(data); err != nil {
					return
				}
			}
		}()
		data := make([]byte, maxPacket)
		for {
			conn.SetReadDeadline(time.Now().Add(60 * time.Second))
			n, err := conn.Read(data)
			if err != nil {
				break
			}
			remote.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err = writeDatagram(remote, data[:n]); err != nil {
				break
			}
		}
		remote.Close()
		<-done
	}()
}
