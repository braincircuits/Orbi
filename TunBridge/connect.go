package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"golang.getoutline.org/sdk/transport"
)

const udpHeader = "X-Network-Transport"
const maxPacket = 65507

// 适配器只连接本机内核；目标解析、认证、路由和远端传输均由 Java 负责。
type localDialer struct{ proxy string }

func (d localDialer) DialStream(ctx context.Context, target string) (transport.StreamConn, error) {
	return d.connect(ctx, target, false)
}

func (d localDialer) connect(ctx context.Context, target string, udp bool) (transport.StreamConn, error) {
	host, port, err := net.SplitHostPort(target)
	n, portErr := strconv.Atoi(port)
	if err != nil || portErr != nil || n < 1 || n > 65535 || host == "" || strings.ContainsAny(target, "\r\n \t") {
		return nil, fmt.Errorf("CONNECT 目标无效")
	}
	// Outline 可能把 IPv4 表示为映射地址，恢复原始地址以匹配内核路由规则。
	if address, err := netip.ParseAddr(host); err == nil {
		target = net.JoinHostPort(address.Unmap().String(), port)
	}
	proxyHost, _, proxyErr := net.SplitHostPort(d.proxy)
	proxyAddress, addressErr := netip.ParseAddr(proxyHost)
	if proxyErr != nil || addressErr != nil || !proxyAddress.IsLoopback() {
		return nil, fmt.Errorf("只允许连接本机代理入口")
	}
	conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", d.proxy)
	if err != nil {
		return nil, fmt.Errorf("连接本地内核失败：%w", err)
	}
	tcp := conn.(*net.TCPConn)
	ok := false
	defer func() {
		if !ok {
			tcp.Close()
		}
	}()
	deadline := time.Now().Add(20 * time.Second)
	if value, has := ctx.Deadline(); has && value.Before(deadline) {
		deadline = value
	}
	if err = tcp.SetDeadline(deadline); err != nil {
		return nil, err
	}
	cancelDone := make(chan struct{})
	stop := context.AfterFunc(ctx, func() { tcp.Close(); close(cancelDone) })
	defer func() {
		if !stop() {
			<-cancelDone
		}
	}()
	header := "X-Network-Source: tun\r\n"
	if udp {
		header += udpHeader + ": udp\r\n"
	}
	if _, err = io.WriteString(tcp, "CONNECT "+target+" HTTP/1.1\r\nHost: "+target+"\r\n"+header+"\r\n"); err != nil {
		return nil, err
	}
	reader := bufio.NewReaderSize(tcp, 16384)
	// 限定响应头大小，同时保留握手与首包合并到达时的缓存数据。
	var responseHeader strings.Builder
	for {
		line, readErr := reader.ReadSlice('\n')
		if readErr != nil {
			return nil, readErr
		}
		responseHeader.Write(line)
		if responseHeader.Len() > 16384 {
			return nil, fmt.Errorf("CONNECT 响应头超过限制")
		}
		if string(line) == "\r\n" {
			break
		}
	}
	response, err := http.ReadResponse(bufio.NewReader(strings.NewReader(responseHeader.String())), &http.Request{Method: "CONNECT"})
	if err != nil {
		return nil, fmt.Errorf("CONNECT 响应格式无效")
	}
	if response.StatusCode != 200 {
		return nil, fmt.Errorf("CONNECT 失败：%d", response.StatusCode)
	}
	if udp && (len(response.Header.Values(udpHeader)) != 1 || response.Header.Get(udpHeader) != "udp") {
		return nil, fmt.Errorf("内核未确认 UDP 隧道")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err = tcp.SetDeadline(time.Time{}); err != nil {
		return nil, err
	}
	ok = true
	return transport.WrapConn(tcp, reader, tcp), nil
}
