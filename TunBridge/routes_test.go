package main

import (
	"net"
	"net/netip"
	"slices"
	"strings"
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

func TestScopedInterfaceRouteRequiresExactDirectPrefix(t *testing.T) {
	base := "destination: 10.0.0.0\nmask: 255.255.0.0\ninterface: en0\nflags: <UP,DONE,CLONING,STATIC,IFSCOPE>\n"
	prefix := netip.MustParsePrefix("10.0.0.0/16")
	cases := []struct {
		name   string
		output string
		valid  bool
	}{
		{"已有正确作用域直连路由", base, true},
		{"普通接口路由不能冒充作用域路由", strings.Replace(base, ",IFSCOPE", "", 1), false},
		{"作用域默认路由不能冒充局域网路由", strings.ReplaceAll(strings.Replace(base, "10.0.0.0", "default", 1), "255.255.0.0", "default"), false},
		{"更泛网段不能冒充精确前缀", strings.Replace(base, "255.255.0.0", "255.0.0.0", 1), false},
		{"主机克隆路由不能冒充网段", strings.ReplaceAll(strings.Replace(base, "10.0.0.0", "10.0.0.7", 1), "255.255.0.0", "255.255.255.255"), false},
		{"其他接口不能复用", strings.Replace(base, "en0", "en1", 1), false},
		{"绕网关的路由不能复用", strings.Replace(base, "UP,", "UP,GATEWAY,", 1), false},
		{"拒绝路由不能复用", strings.Replace(base, "UP,", "UP,REJECT,", 1), false},
		{"黑洞路由不能复用", strings.Replace(base, "UP,", "UP,BLACKHOLE,", 1), false},
		{"未启用路由不能复用", strings.Replace(base, "UP,", "", 1), false},
		{"非法掩码不能复用", strings.Replace(base, "255.255.0.0", "255.0.255.0", 1), false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if got := scopedInterfaceRoute(test.output, prefix, "en0"); got != test.valid {
				t.Fatalf("已有路由判断错误：结果=%v，期望=%v", got, test.valid)
			}
		})
	}
	ipv6 := "destination: 2001:db8::\nmask: ffff:ffff:ffff:ffff::\ninterface: en0\nflags: <UP,STATIC,IFSCOPE>\n"
	if !scopedInterfaceRoute(ipv6, netip.MustParsePrefix("2001:db8::/64"), "en0") {
		t.Fatal("已有 IPv6 作用域直连路由应当复用")
	}
}
