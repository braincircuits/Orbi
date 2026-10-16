package main

import (
	"io"

	lwip "github.com/eycorsican/go-tun2socks/core"
)

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
