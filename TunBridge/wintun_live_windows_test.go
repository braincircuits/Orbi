package main

import (
	"context"
	"encoding/json"
	"flag"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

var windowsLive = flag.Bool("orbi-wintun-live", false, "实际创建 Wintun 并测试独立测试网段，需要管理员授权")

// 仅接管保留测试网段，验证两个转发组件的真实 Windows TCP/UDP 数据通道与接口清理。
func TestWindowsWintunLive(t *testing.T) {
	if !*windowsLive {
		t.Skip("使用 -orbi-wintun-live 显式运行需要管理员授权的网卡集成测试")
	}
	result := map[string]any{"success": false, "engines": []string{}}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		result["success"] = !t.Failed()
		body, _ := json.MarshalIndent(result, "", "  ")
		os.WriteFile(filepath.Join(filepath.Dir(executable), "wintun-live-result.json"), body, 0600)
	}()
	if !windows.GetCurrentProcessToken().IsElevated() {
		t.Fatal("测试需要管理员授权")
	}
	for _, engine := range []string{"outline", "tun2socks"} {
		if !t.Run(engine, func(t *testing.T) {
			dialer, _ := echoKernel(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			tun, err := openTun()
			if err != nil {
				t.Fatal(err)
			}
			index := tun.index
			device, _, err := startForwarding(engine, ctx, dialer, tun)
			if err != nil {
				tun.Close()
				t.Fatal(err)
			}
			defer func() {
				cancel()
				if err := tun.Close(); err != nil {
					t.Error(err)
				}
				device.Close()
			}()
			if err := tun.install([]netip.Prefix{netip.MustParsePrefix("198.19.0.0/24"), netip.MustParsePrefix("2001:db8:1234::/64")}, func() error { return nil }); err != nil {
				t.Fatal(err)
			}
			for _, host := range []string{"198.19.0.2", "2001:db8:1234::2"} {
				tcp, err := net.DialTimeout("tcp", net.JoinHostPort(host, "18080"), 5*time.Second)
				if err != nil {
					t.Fatal(err)
				}
				tcp.SetDeadline(time.Now().Add(5 * time.Second))
				payload := []byte("Windows TUN TCP 双向转发")
				_, err = tcp.Write(payload)
				if err != nil {
					tcp.Close()
					t.Fatal(err)
				}
				reply := make([]byte, len(payload))
				_, err = io.ReadFull(tcp, reply)
				tcp.Close()
				if err != nil || string(reply) != string(payload) {
					t.Fatalf("TCP 回包无效：%q，%v", reply, err)
				}
				udp, err := net.DialTimeout("udp", net.JoinHostPort(host, "18081"), 5*time.Second)
				if err != nil {
					t.Fatal(err)
				}
				udp.SetDeadline(time.Now().Add(5 * time.Second))
				payload = []byte("Windows TUN UDP 双向转发")
				_, err = udp.Write(payload)
				if err != nil {
					udp.Close()
					t.Fatal(err)
				}
				buffer := make([]byte, 512)
				n, err := udp.Read(buffer)
				udp.Close()
				if err != nil || string(buffer[:n]) != string(payload) {
					t.Fatalf("UDP 回包无效：%q，%v", buffer[:n], err)
				}
			}
			cancel()
			if err := tun.Close(); err != nil {
				t.Fatal(err)
			}
			output, err := powershell("@(Get-NetRoute -InterfaceIndex " + strconv.FormatUint(uint64(index), 10) + " -ErrorAction SilentlyContinue).Count")
			if err != nil || output != "0" {
				t.Fatalf("停止后仍有测试网卡路由：%s，%v", output, err)
			}
		}) {
			return
		}
		result["engines"] = append(result["engines"].([]string), engine)
	}
}
