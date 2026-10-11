//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func serviceTestRequest(t *testing.T, service *tunService, request serviceRequest) serviceReply {
	t.Helper()
	// macOS 的 Unix 套接字路径长度有限，使用短临时目录。
	directory, err := os.MkdirTemp("/tmp", "network-service-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	path := filepath.Join(directory, "s")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.AcceptUnix()
		if err == nil {
			service.handle(conn)
		}
	}()
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	uid, pid, err := peerIdentity(conn)
	if err != nil || uid != os.Getuid() || pid != os.Getpid() {
		t.Fatalf("本机对端身份不符：用户=%d，进程=%d，错误=%v", uid, pid, err)
	}
	if err = json.NewEncoder(conn).Encode(request); err != nil {
		t.Fatal(err)
	}
	var reply serviceReply
	if err = json.NewDecoder(conn).Decode(&reply); err != nil {
		t.Fatal(err)
	}
	<-done
	return reply
}
func TestServiceRejectsOtherUserCommandsAndMismatchedBuild(t *testing.T) {
	service := &tunService{uid: os.Getuid(), digest: "测试构建", ctx: context.Background()}
	reply := serviceTestRequest(t, service, serviceRequest{Action: "status"})
	if reply.Error != "" || reply.Digest != service.digest {
		t.Fatalf("状态读取失败：%+v", reply)
	}
	for _, request := range []serviceRequest{
		{Action: "exec", Endpoint: "/bin/sh"},
		{Action: "start", Digest: "其他构建", Endpoint: "/tmp/control.json", Ticket: strings.Repeat("t", 36)},
		{Action: "start", Digest: service.digest, Endpoint: "相对路径", Ticket: strings.Repeat("t", 36)},
		{Action: "start", Digest: service.digest, Endpoint: "/tmp/control.json", Ticket: ""},
	} {
		if reply = serviceTestRequest(t, service, request); reply.Error == "" {
			t.Fatalf("无效操作未被拒绝：%+v", request)
		}
	}
	if os.Getuid() != 0 {
		service.uid++
		if reply = serviceTestRequest(t, service, serviceRequest{Action: "status"}); reply.Error == "" {
			t.Fatal("其他用户未被拒绝")
		}
		service.uid--
		if reply = serviceTestRequest(t, service, serviceRequest{Action: "prepare-install"}); reply.Error == "" {
			t.Fatal("普通用户可阻止服务接收请求")
		}
	}
}
func TestServiceRejectsConcurrentSessionsAndPublicDiscovery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control.json")
	data, _ := json.Marshal(map[string]any{"url": "http://127.0.0.1:9090", "apiVersion": 1, "token": strings.Repeat("x", 32)})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	service := &tunService{uid: os.Getuid(), digest: "测试构建", ctx: context.Background(), active: true}
	request := serviceRequest{Action: "start", Digest: service.digest, Endpoint: path, Ticket: strings.Repeat("t", 36)}
	if reply := serviceTestRequest(t, service, request); !strings.Contains(reply.Error, "正在运行") {
		t.Fatalf("并发会话未被拒绝：%+v", reply)
	}
	service.active = false
	service.draining = true
	if reply := serviceTestRequest(t, service, request); !strings.Contains(reply.Error, "等待更新") {
		t.Fatalf("更新中仍接受会话：%+v", reply)
	}
	service.draining = false
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if reply := serviceTestRequest(t, service, request); !strings.Contains(reply.Error, "权限无效") {
		t.Fatalf("公开发现文件未被拒绝：%+v", reply)
	}
}
func TestServiceClientRequiresDirectParentAndInstallRequiresRoot(t *testing.T) {
	if err := runServiceClient("/tmp/control.json", strings.Repeat("x", 36), 1); err == nil {
		t.Fatal("客户端接受了错误的父进程")
	}
	if os.Getuid() != 0 {
		if err := installService(os.Getuid()); err == nil {
			t.Fatal("普通用户安装服务未被拒绝")
		}
		if err := removeService(); err == nil {
			t.Fatal("普通用户移除服务未被拒绝")
		}
	}
	command := exec.Command("/usr/bin/plutil", "-lint", "-")
	command.Stdin = strings.NewReader(string(launchDaemonPlist(501)))
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("系统服务配置无效：%v，%s", err, output)
	}
}
