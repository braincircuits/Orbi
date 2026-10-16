package main

import (
	"errors"
	"io"
	"testing"
	"time"

	lwip "github.com/eycorsican/go-tun2socks/core"
)

type packetTestIO struct {
	io.Reader
	io.Writer
}
type packetTestWriter func([]byte) (int, error)

func (w packetTestWriter) Write(p []byte) (int, error) { return w(p) }

// 写入失败或短写必须通知会话清理，重复失败不能卡住持有全局锁的回调。
func TestPacketOutputFailureStopsForwarding(t *testing.T) {
	for _, short := range []bool{false, true} {
		reader, writer := io.Pipe()
		failure := errors.New("测试 TUN 写入失败")
		sink := packetTestWriter(func(p []byte) (int, error) {
			if short {
				return len(p) - 1, nil
			}
			return 0, failure
		})
		stopped := forwardPackets(io.Discard, packetTestIO{reader, sink})
		done := make(chan struct{})
		go func() {
			defer close(done)
			for i := 0; i < 4; i++ {
				_, err := lwip.OutputFn([]byte{0x45, 0, 0, 20})
				expected := failure
				if short {
					expected = io.ErrShortWrite
				}
				if !errors.Is(err, expected) {
					t.Errorf("输出错误未保留：%v", err)
				}
			}
		}()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("重复输出错误阻塞了协议栈")
		}
		select {
		case err := <-stopped:
			if err == nil {
				t.Error("未报告输出失败")
			}
		case <-time.After(time.Second):
			t.Fatal("会话未收到停止通知")
		}
		writer.Close()
		reader.Close()
	}
}

func TestPacketInputFailureStopsForwarding(t *testing.T) {
	reader, writer := io.Pipe()
	stopped := forwardPackets(io.Discard, packetTestIO{reader, io.Discard})
	failure := errors.New("测试 TUN 读取失败")
	writer.CloseWithError(failure)
	defer reader.Close()
	select {
	case err := <-stopped:
		if !errors.Is(err, failure) {
			t.Fatalf("输入错误未保留：%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("读取失败未停止转发")
	}
}
