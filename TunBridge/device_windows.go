package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wintun"
)

const tunMTU = 8192

type tunDevice struct {
	adapter         *wintun.Adapter
	session         wintun.Session
	index           uint32
	readMu, writeMu sync.Mutex
	closed          atomic.Bool
	once            sync.Once
	closeError      error
}

func powershell(script string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	executable := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	process := exec.CommandContext(ctx, executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new();"+script)
	process.Env = append(os.Environ(), "PSModulePath="+filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "Modules"))
	process.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := process.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("Windows 网络操作失败：%s", strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}

type defaultNetwork struct {
	Index   int    `json:"index"`
	Gateway string `json:"gateway"`
	IPv6    string `json:"ipv6"`
}

func networkState() (defaultNetwork, error) {
	output, err := powershell(`$r=Get-NetRoute -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore | Where-Object {$_.InterfaceAlias -notlike 'Orbi*' -and $_.State -eq 'Alive'} | Sort-Object @{Expression={$_.RouteMetric+$_.InterfaceMetric}},InterfaceIndex | Select-Object -First 1;if(!$r){throw '未找到真实 IPv4 网络出口'};$v=Get-NetRoute -DestinationPrefix '::/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Sort-Object @{Expression={$_.RouteMetric+$_.InterfaceMetric}},InterfaceIndex | Select-Object -First 1;@{index=[int]$r.InterfaceIndex;gateway=[string]$r.NextHop;ipv6=([string]$v.InterfaceIndex+'/'+[string]$v.NextHop)} | ConvertTo-Json -Compress`)
	var state defaultNetwork
	if err == nil {
		err = json.Unmarshal([]byte(output), &state)
	}
	return state, err
}
func primaryNetwork() (string, string, error) {
	state, err := networkState()
	if err != nil {
		return "", "", err
	}
	nic, err := net.InterfaceByIndex(state.Index)
	if err != nil {
		return "", "", err
	}
	if nic.Flags&net.FlagLoopback != 0 || nic.Flags&net.FlagUp == 0 {
		return "", "", fmt.Errorf("真实网络出口不可用")
	}
	addresses, err := nic.Addrs()
	if err != nil {
		return "", "", err
	}
	return strconv.Itoa(state.Index), fmt.Sprint(state, addresses), nil
}
func routePrefixes(name string) ([]netip.Prefix, error) {
	index, err := strconv.Atoi(name)
	if err != nil {
		return nil, err
	}
	nic, err := net.InterfaceByIndex(index)
	if err != nil {
		return nil, err
	}
	addresses, err := nic.Addrs()
	if err != nil {
		return nil, err
	}
	prefixes, err := localPrefixes(addresses)
	if err != nil {
		return nil, err
	}
	state, err := networkState()
	if err != nil {
		return nil, err
	}
	if state.Index != index {
		return nil, fmt.Errorf("网络出口已变化")
	}
	gateway, err := netip.ParseAddr(state.Gateway)
	if err != nil {
		return nil, fmt.Errorf("默认网关无效")
	}
	result := []netip.Prefix{netip.MustParsePrefix("0.0.0.0/1"), netip.MustParsePrefix("128.0.0.0/1"), netip.MustParsePrefix("::/1"), netip.MustParsePrefix("8000::/1")}
	for _, prefix := range prefixes {
		result = append(result, subnetRoutes(prefix, gateway)...)
	}
	return result, nil
}

func openTun() (*tunDevice, error) {
	// 只从辅助程序所在目录加载官方签名驱动，不依赖当前目录或 PATH。
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	library, err := windows.LoadLibraryEx(filepath.Join(filepath.Dir(executable), "wintun.dll"), 0, windows.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|windows.LOAD_LIBRARY_SEARCH_SYSTEM32)
	if err != nil {
		return nil, fmt.Errorf("加载 Wintun 失败：%w", err)
	}
	defer windows.FreeLibrary(library)
	// 固定设备标识避免每次连接生成新的 Windows 网络配置；创建冲突时直接报错。
	guid := windows.GUID{Data1: 0xca78da46, Data2: 0x78b8, Data3: 0x4c41, Data4: [8]byte{0xab, 0x5a, 0x29, 0x8d, 0x38, 0x56, 0x62, 0x65}}
	adapter, err := wintun.CreateAdapter("Orbi", "Wintun", &guid)
	if err != nil {
		return nil, fmt.Errorf("创建 Wintun 网卡失败：%w", err)
	}
	session, err := adapter.StartSession(0x800000)
	if err != nil {
		adapter.Close()
		return nil, err
	}
	tun := &tunDevice{adapter: adapter, session: session}
	luid := adapter.LUID()
	result, _, _ := windows.NewLazySystemDLL("iphlpapi.dll").NewProc("ConvertInterfaceLuidToIndex").Call(uintptr(unsafe.Pointer(&luid)), uintptr(unsafe.Pointer(&tun.index)))
	if result != 0 {
		tun.Close()
		return nil, fmt.Errorf("读取 Wintun 接口索引失败：%d", result)
	}
	// 虚拟点对点链路不进行邻居地址探测；只有源地址就绪后才允许接管路由。
	_, err = powershell(fmt.Sprintf(`$i=%d;Set-NetIPInterface -InterfaceIndex $i -DadTransmits 0 -NlMtuBytes %d -AutomaticMetric Disabled -InterfaceMetric 1 -Forwarding Disabled;Set-NetIPInterface -InterfaceIndex $i -AddressFamily IPv6 -RouterDiscovery Disabled;New-NetIPAddress -InterfaceIndex $i -IPAddress '198.18.0.1' -PrefixLength 30 -PolicyStore ActiveStore | Out-Null;New-NetIPAddress -InterfaceIndex $i -IPAddress 'fdfe:dcba:9876::1' -PrefixLength 126 -PolicyStore ActiveStore | Out-Null;$deadline=[DateTime]::UtcNow.AddSeconds(5);do{$ready=@(Get-NetIPAddress -InterfaceIndex $i | Where-Object {$_.IPAddress -in @('198.18.0.1','fdfe:dcba:9876::1') -and $_.AddressState -eq 'Preferred'});if($ready.Count -eq 2){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline);if($ready.Count -ne 2){throw 'Wintun 地址未就绪'}`, tun.index, tunMTU))
	if err != nil {
		return nil, errors.Join(err, tun.Close())
	}
	return tun, nil
}

// Windows 套接字通过 IP_UNICAST_IF 约束真实出口，无需改动真实网卡路由。
func (t *tunDevice) prepareBypass(string) error { return nil }
func (t *tunDevice) guardDone() <-chan struct{} { return nil }
func (t *tunDevice) install(prefixes []netip.Prefix, check func() error) error {
	if err := check(); err != nil {
		return err
	}
	var script strings.Builder
	for _, prefix := range prefixes {
		// 前缀来自 netip，仅包含地址与掩码，索引来自系统 API。
		fmt.Fprintf(&script, "New-NetRoute -InterfaceIndex %d -DestinationPrefix '%s' -NextHop '%s' -RouteMetric 1 -PolicyStore ActiveStore | Out-Null;", t.index, prefix, map[bool]string{true: "::", false: "0.0.0.0"}[prefix.Addr().Is6()])
	}
	if _, err := powershell(script.String()); err != nil {
		return err
	}
	return check()
}
func (t *tunDevice) Read(packet []byte) (int, error) {
	t.readMu.Lock()
	defer t.readMu.Unlock()
	for !t.closed.Load() {
		data, err := t.session.ReceivePacket()
		if err == nil {
			n := copy(packet, data)
			truncated := n != len(data)
			t.session.ReleaseReceivePacket(data)
			if truncated {
				return n, io.ErrShortBuffer
			}
			return n, nil
		}
		if !errors.Is(err, windows.ERROR_NO_MORE_ITEMS) {
			return 0, err
		}
		if _, err = windows.WaitForSingleObject(t.session.ReadWaitEvent(), 1000); err != nil {
			return 0, err
		}
	}
	return 0, os.ErrClosed
}
func (t *tunDevice) Write(packet []byte) (int, error) {
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	if t.closed.Load() {
		return 0, os.ErrClosed
	}
	if len(packet) == 0 {
		return 0, nil
	}
	if len(packet) > 65535 {
		return 0, fmt.Errorf("Wintun 报文过长")
	}
	buffer, err := t.session.AllocateSendPacket(len(packet))
	if errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
		// 环形队列已满时丢弃当前 IP 包，由传输层重试，不阻塞协议栈定时器。
		return len(packet), nil
	}
	if err != nil {
		return 0, err
	}
	copy(buffer, packet)
	t.session.SendPacket(buffer)
	return len(packet), nil
}
func (t *tunDevice) Close() error {
	t.once.Do(func() {
		t.closed.Store(true)
		windows.SetEvent(t.session.ReadWaitEvent())
		t.readMu.Lock()
		defer t.readMu.Unlock()
		t.writeMu.Lock()
		defer t.writeMu.Unlock()
		t.session.End()
		// WintunCloseAdapter 删除本次创建的适配器；其 ActiveStore 路由随接口一起释放。
		t.closeError = t.adapter.Close()
	})
	return t.closeError
}
