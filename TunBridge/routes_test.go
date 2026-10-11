package main

import (
	"net/netip"
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
