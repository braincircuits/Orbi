package main

import (
	"net"
	"net/netip"
	"slices"
	"testing"
)

func TestSubnetRoutesPreserveGatewayAndCaptureOtherHosts(t *testing.T) {
	prefix := netip.MustParsePrefix("10.0.0.0/24")
	gateway := netip.MustParseAddr("10.0.0.1")
	routes := subnetRoutes(prefix, gateway)
	for ip := prefix.Addr(); prefix.Contains(ip); ip = ip.Next() {
		covered := 0
		for _, route := range routes {
			if route.Contains(ip) {
				covered++
			}
		}
		expected := 1
		if ip == gateway {
			expected = 0
		}
		if covered != expected {
			t.Fatalf("地址接管范围错误：%s，匹配数量=%d", ip, covered)
		}
	}
	for _, route := range subnetRoutes(netip.MustParsePrefix("2001:db8::/64"), gateway) {
		if route.Bits() != 65 {
			t.Fatal("IPv6 直连网段未正确细分")
		}
	}
}

func TestLocalPrefixesMaskDeduplicateAndFilter(t *testing.T) {
	addresses := []net.Addr{
		&net.IPNet{IP: net.ParseIP("10.0.0.6"), Mask: net.CIDRMask(16, 32)},
		&net.IPNet{IP: net.ParseIP("10.0.0.8"), Mask: net.CIDRMask(16, 32)},
		&net.IPNet{IP: net.ParseIP("2001:db8::1234"), Mask: net.CIDRMask(64, 128)},
		&net.IPNet{IP: net.ParseIP("2001:db8::5678"), Mask: net.CIDRMask(64, 128)},
		&net.IPNet{IP: net.ParseIP("169.254.1.2"), Mask: net.CIDRMask(16, 32)},
		&net.IPNet{IP: net.ParseIP("fe80::1234"), Mask: net.CIDRMask(64, 128)},
		&net.IPNet{IP: net.ParseIP("10.0.0.6"), Mask: net.CIDRMask(32, 32)},
		&net.IPNet{IP: net.ParseIP("2001:db8::1234"), Mask: net.CIDRMask(128, 128)},
		&net.IPNet{IP: net.ParseIP("0.0.0.0"), Mask: net.CIDRMask(0, 32)},
	}
	got, err := localPrefixes(addresses)
	want := []netip.Prefix{netip.MustParsePrefix("10.0.0.0/16"), netip.MustParsePrefix("2001:db8::/64")}
	if err != nil || !slices.Equal(got, want) {
		t.Fatalf("本地网段筛选或去重错误：结果=%v，错误=%v", got, err)
	}
	if _, err := localPrefixes([]net.Addr{&net.IPAddr{IP: net.ParseIP("10.0.0.6")}}); err == nil {
		t.Fatal("缺少掩码的接口地址应当返回错误")
	}
}
