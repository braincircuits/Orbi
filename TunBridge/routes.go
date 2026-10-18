package main

import (
	"net"
	"net/netip"
)

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
