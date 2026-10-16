package main

import "testing"

func TestRouteGuardAcceptsOnlyScopedDefaultsAndDirectPrefixes(t *testing.T) {
	cases := []struct {
		name  string
		args  []string
		valid bool
	}{
		{"IPv4 默认路由", []string{"-inet", "-net", "default", "10.0.0.1", "-ifscope", "en0"}, true},
		{"IPv6 默认路由", []string{"-inet6", "-net", "default", "fe80::1%en0", "-ifscope", "en0"}, true},
		{"IPv4 直连网段", []string{"-inet", "-net", "10.0.0.0/16", "-interface", "en0", "-ifscope", "en0"}, true},
		{"IPv6 直连网段", []string{"-inet6", "-net", "2001:db8::/64", "-interface", "en0", "-ifscope", "en0"}, true},
		{"空请求", nil, false},
		{"非作用域直连网段", []string{"-inet", "-net", "10.0.0.0/16", "-interface", "en0"}, false},
		{"任意主机路由", []string{"-inet", "-host", "10.0.0.7", "10.0.0.1", "-ifscope", "en0"}, false},
		{"默认路由地址族不符", []string{"-inet6", "-net", "default", "10.0.0.1", "-ifscope", "en0"}, false},
		{"默认路由网关格式无效", []string{"-inet", "-net", "default", "-blackhole", "-ifscope", "en0"}, false},
		{"IPv6 网关作用域不符", []string{"-inet6", "-net", "default", "fe80::1%en1", "-ifscope", "en0"}, false},
		{"默认路由缺少作用域参数", []string{"-inet", "-net", "default", "10.0.0.1", "-interface", "en0"}, false},
		{"直连接口作用域不符", []string{"-inet", "-net", "10.0.0.0/16", "-interface", "en0", "-ifscope", "en1"}, false},
		{"直连路由地址族不符", []string{"-inet6", "-net", "10.0.0.0/16", "-interface", "en0", "-ifscope", "en0"}, false},
		{"未掩码的网段", []string{"-inet", "-net", "10.0.0.6/16", "-interface", "en0", "-ifscope", "en0"}, false},
		{"主机前缀", []string{"-inet", "-net", "10.0.0.7/32", "-interface", "en0", "-ifscope", "en0"}, false},
		{"默认前缀", []string{"-inet", "-net", "0.0.0.0/0", "-interface", "en0", "-ifscope", "en0"}, false},
		{"链路本地前缀", []string{"-inet6", "-net", "fe80::/64", "-interface", "en0", "-ifscope", "en0"}, false},
		{"非法前缀", []string{"-inet", "-net", "非法地址", "-interface", "en0", "-ifscope", "en0"}, false},
		{"虚拟接口", []string{"-inet", "-net", "10.0.0.0/16", "-interface", "utun4", "-ifscope", "utun4"}, false},
		{"回环接口", []string{"-inet", "-net", "10.0.0.0/16", "-interface", "lo0", "-ifscope", "lo0"}, false},
		{"接口名不能作为命令参数", []string{"-inet", "-net", "default", "10.0.0.1", "-ifscope", "-blackhole"}, false},
		{"额外参数", []string{"-inet", "-net", "10.0.0.0/16", "-interface", "en0", "-ifscope", "en0", "-blackhole"}, false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if got := validRouteGuardRequest(test.args, 0); got != test.valid {
				t.Fatalf("路由守护请求判断错误：结果=%v，期望=%v", got, test.valid)
			}
		})
	}
}

func TestRouteGuardLimitsOwnedRouteCount(t *testing.T) {
	args := []string{"-inet", "-net", "10.0.0.0/16", "-interface", "en0", "-ifscope", "en0"}
	if !validRouteGuardRequest(args, maxGuardRoutes-1) {
		t.Fatal("达到上限前应当允许添加最后一条路由")
	}
	if validRouteGuardRequest(args, maxGuardRoutes) {
		t.Fatal("已到上限时必须拒绝新增路由")
	}
}
