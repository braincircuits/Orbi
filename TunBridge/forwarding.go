package main

import (
	"context"
	"fmt"
	"io"
	"time"

	lwip "github.com/eycorsican/go-tun2socks/core"
	"golang.getoutline.org/sdk/network/lwip2transport"
	"golang.getoutline.org/sdk/network/packetrelay"
)

// 每次会话只启动一个组件；调用方必须先关闭 TUN，再关闭返回的协议栈。
func startForwarding(engine string, ctx context.Context, dialer localDialer, tun io.ReadWriter) (io.Closer, <-chan error, error) {
	switch engine {
	case "outline":
		relay, err := packetrelay.NewTimeoutPacketRelay(udpRelay{dialer: dialer, context: ctx}, 60*time.Second)
		if err != nil {
			return nil, nil, err
		}
		device, err := lwip2transport.ConfigureDeviceWithRelay(dialer, relay)
		if err != nil {
			return nil, nil, fmt.Errorf("初始化 Outline SDK 失败：%w", err)
		}
		return device, forwardPackets(device, tun), nil
	case "tun2socks":
		return startTun2socks(ctx, dialer, tun)
	default:
		return nil, nil, fmt.Errorf("TUN 转发组件无效：%s", engine)
	}
}

// lwIP 的 TCP、UDP 和定时器输出均在协议栈锁下串行执行，可以直接写入 TUN。
// 借用的报文在回调返回前完成写入，省去 SDK 输出通道的两次同步交接。
func forwardPackets(device io.Writer, tun io.ReadWriter) <-chan error {
	stopped := make(chan error, 2)
	lwip.RegisterOutputFn(func(packet []byte) (int, error) {
		n, err := tun.Write(packet)
		if err == nil && n != len(packet) {
			err = io.ErrShortWrite
		}
		if err != nil {
			// 多个回包同时失败时仍要释放协议栈锁，由会话统一停止转发并清理路由。
			select {
			case stopped <- err:
			default:
			}
		}
		return n, err
	})
	go func() {
		_, err := io.Copy(device, tun)
		select {
		case stopped <- err:
		default:
		}
	}()
	return stopped
}
