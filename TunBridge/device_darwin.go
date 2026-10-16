//go:build darwin

package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// 与 lwIP 补丁的虚拟 MTU 一致；物理出口由独立套接字按真实网卡重新分段。
const tunMTU = 8192

type tunDevice struct {
	file   *os.File
	name   string
	routes []netip.Prefix
	bypass [][]string
	guard  *routeGuard
	// 组件分别串行读取和写入，两个方向各自复用缓冲区。
	readBuffer, writeBuffer []byte
}

func command(program string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, program, args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("系统网络操作失败：%s %v：%s", program, args, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}

// 读取系统网络服务的主接口，避免被本进程安装的细分默认路由干扰。
func primaryState(family string) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	query := exec.CommandContext(ctx, "/usr/sbin/scutil")
	query.Stdin = strings.NewReader("show State:/Network/Global/" + family + "\n")
	output, err := query.Output()
	text := string(output)
	if err != nil {
		return nil, err
	}
	fields := make(map[string]string)
	for _, line := range strings.Split(text, "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(line), ":")
		if found {
			fields[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return fields, nil
}
func primaryNetwork() (string, string, error) {
	fields, err := primaryState("IPv4")
	if err != nil {
		return "", "", err
	}

	name := fields["PrimaryInterface"]
	if name == "" || strings.HasPrefix(name, "utun") || name == "lo0" {
		return "", "", fmt.Errorf("未找到可接管的真实网络出口，请先关闭其他 VPN")
	}
	nic, err := net.InterfaceByName(name)
	if err != nil {
		return "", "", err
	}
	addresses, err := nic.Addrs()
	if err != nil {
		return "", "", err
	}
	ipv6, err := primaryState("IPv6")
	if err != nil {
		return "", "", err
	}
	return name, fmt.Sprint(fields["Router"], ipv6["PrimaryInterface"], ipv6["Router"], addresses), nil
}

func openTun() (*tunDevice, error) {
	fd, err := unix.Socket(unix.AF_SYSTEM, unix.SOCK_DGRAM, 2)
	if err != nil {
		return nil, fmt.Errorf("创建 utun 失败：%w", err)
	}
	ok := false
	defer func() {
		if !ok {
			unix.Close(fd)
		}
	}()
	unix.CloseOnExec(fd)
	var info unix.CtlInfo
	copy(info.Name[:], "com.apple.net.utun_control")
	if err = unix.IoctlCtlInfo(fd, &info); err != nil {
		return nil, err
	}
	if err = unix.Connect(fd, &unix.SockaddrCtl{ID: info.Id}); err != nil {
		return nil, err
	}
	name, err := unix.GetsockoptString(fd, 2, 2)
	if err != nil {
		return nil, err
	}
	name = strings.TrimRight(name, "\x00")
	if !strings.HasPrefix(name, "utun") {
		return nil, fmt.Errorf("系统返回的虚拟网卡名称无效")
	}
	if err = unix.SetNonblock(fd, true); err != nil {
		return nil, err
	}
	tun := &tunDevice{file: os.NewFile(uintptr(fd), name), name: name}
	ok = true // 文件对象从此独占描述符的关闭责任。
	if _, err = command("/sbin/ifconfig", name, "inet", "198.18.0.1", "198.18.0.1", "netmask", "255.255.255.252", "mtu", strconv.Itoa(tunMTU), "up"); err != nil {
		tun.Close()
		return nil, err
	}
	if _, err = command("/sbin/ifconfig", name, "inet6", "fdfe:dcba:9876::1", "prefixlen", "126"); err != nil {
		tun.Close()
		return nil, err
	}
	ok = true
	return tun, nil
}

// 将真实接口的本地网段也细分接管，直连业务仍交给 Java 规则判断；回环及本机地址保留系统路由。
func routePrefixes(name string) ([]netip.Prefix, error) {
	result := []netip.Prefix{netip.MustParsePrefix("0.0.0.0/1"), netip.MustParsePrefix("128.0.0.0/1"), netip.MustParsePrefix("::/1"), netip.MustParsePrefix("8000::/1")}
	prefixes, err := interfacePrefixes(name)
	if err != nil {
		return nil, err
	}
	state, err := primaryState("IPv4")
	if err != nil {
		return nil, err
	}
	gateway, err := netip.ParseAddr(state["Router"])
	if err != nil {
		return nil, fmt.Errorf("默认网关无效：%w", err)
	}
	seen := map[netip.Prefix]bool{}
	for _, prefix := range prefixes {
		for _, p := range subnetRoutes(prefix, gateway) {
			if !seen[p] {
				result = append(result, p)
				seen[p] = true
			}
		}
	}
	return result, nil
}

func interfacePrefixes(name string) ([]netip.Prefix, error) {
	nic, err := net.InterfaceByName(name)
	if err != nil {
		return nil, err
	}
	addresses, err := nic.Addrs()
	if err != nil {
		return nil, err
	}
	return localPrefixes(addresses)
}

// TUN 接管与真实接口作用域路由使用同一组本地网段，忽略链路本地地址和主机地址。
func localPrefixes(addresses []net.Addr) ([]netip.Prefix, error) {
	var result []netip.Prefix
	seen := map[netip.Prefix]bool{}
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err != nil {
			return nil, err
		}
		prefix = prefix.Masked()
		if prefix.Addr().IsLinkLocalUnicast() || prefix.Bits() == 0 || prefix.Bits() >= prefix.Addr().BitLen() || seen[prefix] {
			continue
		}
		result = append(result, prefix)
		seen[prefix] = true
	}
	return result, nil
}

// 保留网关的原始链路路由，否则 macOS 即使绑定真实接口，也可能无法解析下一跳。
func subnetRoutes(prefix netip.Prefix, gateway netip.Addr) []netip.Prefix {
	var result []netip.Prefix
	var split func(netip.Prefix)
	split = func(p netip.Prefix) {
		if p.Bits() == p.Addr().BitLen() {
			if p.Addr() != gateway {
				result = append(result, p)
			}
			return
		}
		left := netip.PrefixFrom(p.Addr(), p.Bits()+1)
		bits := p.Addr().AsSlice()
		bits[p.Bits()/8] |= byte(1 << (7 - uint(p.Bits()%8)))
		rightAddr, _ := netip.AddrFromSlice(bits)
		for _, half := range []netip.Prefix{left, netip.PrefixFrom(rightAddr, p.Bits()+1)} {
			if half.Contains(gateway) {
				split(half)
			} else {
				result = append(result, half)
			}
		}
	}
	split(prefix.Masked())
	return result
}

// 为绑定真实接口的出口保留默认及局域网作用域路由，只管理本进程新增的条目。
func (t *tunDevice) prepareBypass(name string) error {
	for _, family := range []string{"IPv4", "IPv6"} {
		state, err := primaryState(family)
		if err != nil {
			return err
		}
		if state["PrimaryInterface"] != name || state["Router"] == "" {
			continue
		}
		gateway := state["Router"]
		option := "-inet"
		if family == "IPv6" {
			option = "-inet6"
			address, err := netip.ParseAddr(gateway)
			if err != nil {
				return fmt.Errorf("IPv6 网关无效：%w", err)
			}
			if address.IsLinkLocalUnicast() && address.Zone() == "" {
				gateway += "%" + name
			}
		}
		current, err := command("/sbin/route", "-n", "get", option, "-ifscope", name, "default")
		if err == nil && strings.Contains(current, "IFSCOPE") {
			if !strings.Contains(current, "gateway: "+gateway) {
				return fmt.Errorf("真实接口的现有作用域默认路由与系统网关不一致")
			}
			continue
		}
		args := []string{option, "-net", "default", gateway, "-ifscope", name}
		if err := t.addBypass(args); err != nil {
			return err
		}
	}
	prefixes, err := interfacePrefixes(name)
	if err != nil {
		return err
	}
	for _, prefix := range prefixes {
		option := "-inet"
		if prefix.Addr().Is6() {
			option = "-inet6"
		}
		current, err := command("/sbin/route", "-n", "get", option, "-net", prefix.String(), "-ifscope", name)
		if err == nil && scopedInterfaceRoute(current, prefix, name) {
			continue
		}
		// 完整前缀仅供绑定真实接口的出口使用；普通应用仍命中更细的 TUN 路由。
		args := []string{option, "-net", prefix.String(), "-interface", name, "-ifscope", name}
		if err := t.addBypass(args); err != nil {
			return err
		}
	}
	return nil
}

func (t *tunDevice) addBypass(args []string) error {
	if t.guard == nil {
		var err error
		t.guard, err = startRouteGuard()
		if err != nil {
			return err
		}
	}
	if err := t.guard.add(args); err != nil {
		return err
	}
	// 只补做已确认成功创建的路由清理，不删除发生冲突的已有路由。
	t.bypass = append(t.bypass, args)
	return nil
}

func scopedInterfaceRoute(output string, prefix netip.Prefix, name string) bool {
	fields := make(map[string]string)
	for _, line := range strings.Split(output, "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(line), ":")
		if found {
			fields[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	destination, err := netip.ParseAddr(fields["destination"])
	if err != nil || destination != prefix.Addr() || fields["interface"] != name {
		return false
	}
	mask, err := netip.ParseAddr(fields["mask"])
	if err != nil {
		return false
	}
	ones, bits := net.IPMask(mask.AsSlice()).Size()
	if ones != prefix.Bits() || bits != prefix.Addr().BitLen() {
		return false
	}
	flags := map[string]bool{}
	for _, flag := range strings.Split(strings.Trim(fields["flags"], "<>"), ",") {
		flags[strings.TrimSpace(flag)] = true
	}
	// 带 ifscope 的查询也可能返回非作用域路由，或退回网关及主机路由，必须逐项核对。
	return flags["UP"] && flags["IFSCOPE"] && !flags["GATEWAY"] && !flags["REJECT"] && !flags["BLACKHOLE"]
}

func (t *tunDevice) install(prefixes []netip.Prefix, check func() error) error {
	for _, prefix := range prefixes {
		if err := check(); err != nil {
			return err
		}
		family := "-inet"
		if prefix.Addr().Is6() {
			family = "-inet6"
		}
		if _, err := command("/sbin/route", "-n", "add", family, "-net", prefix.String(), "-interface", t.name); err != nil {
			return err
		}
		t.routes = append(t.routes, prefix)
	}
	return nil
}
func (t *tunDevice) Read(packet []byte) (int, error) {
	if cap(t.readBuffer) < len(packet)+4 {
		t.readBuffer = make([]byte, len(packet)+4)
	}
	buffer := t.readBuffer[:len(packet)+4]
	n, err := t.file.Read(buffer)
	if err != nil {
		return 0, err
	}
	if n < 5 {
		return 0, fmt.Errorf("utun 报文过短")
	}
	family := binary.BigEndian.Uint32(buffer[:4])
	if family != unix.AF_INET && family != unix.AF_INET6 {
		return 0, fmt.Errorf("utun 地址族不支持")
	}
	return copy(packet, buffer[4:n]), nil
}
func (t *tunDevice) Write(packet []byte) (int, error) {
	if len(packet) == 0 {
		return 0, nil
	}
	family := uint32(unix.AF_INET)
	if packet[0]>>4 == 6 {
		family = unix.AF_INET6
	} else if packet[0]>>4 != 4 {
		return 0, fmt.Errorf("IP 版本不支持")
	}
	if cap(t.writeBuffer) < len(packet)+4 {
		t.writeBuffer = make([]byte, len(packet)+4)
	}
	buffer := t.writeBuffer[:len(packet)+4]
	binary.BigEndian.PutUint32(buffer, family)
	copy(buffer[4:], packet)
	n, err := t.file.Write(buffer)
	if err == nil && n != len(buffer) {
		err = io.ErrShortWrite
	}
	return max(0, n-4), err
}
func (t *tunDevice) Close() error {
	// 只删除本进程成功添加的路由；关闭 utun 也会由系统清除其接口路由。
	var failure error
	for i := len(t.routes) - 1; i >= 0; i-- {
		prefix := t.routes[i]
		family := "-inet"
		if prefix.Addr().Is6() {
			family = "-inet6"
		}
		_, err := command("/sbin/route", "-n", "delete", family, "-net", prefix.String(), "-interface", t.name)
		failure = errors.Join(failure, err)
	}
	t.routes = nil
	failure = errors.Join(failure, t.file.Close())
	if t.guard != nil {
		if err := t.guard.close(); err != nil {
			failure = errors.Join(failure, err)
			for i := len(t.bypass) - 1; i >= 0; i-- {
				// 只在守护进程失败时重试自身曾请求的路由清理。
				command("/sbin/route", append([]string{"-n", "delete"}, t.bypass[i]...)...)
			}
		}
	}
	t.bypass = nil
	return failure
}
