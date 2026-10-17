package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestControlErrorsDoNotEchoResponseCredentials(t *testing.T) {
	const secret = "unregistered-password-secret"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprintf(w, `{"error":{"message":"Bearer %s"}}`, secret)
	}))
	defer server.Close()
	client := &controlClient{base: server.URL, token: strings.Repeat("x", 32), client: server.Client()}
	err := client.call("prepare", map[string]string{"ticket": "test-ticket"}, nil)
	if err == nil || strings.Contains(err.Error(), secret) || !strings.Contains(err.Error(), "403") {
		t.Fatalf("错误应保留状态码但不能带出响应原文：%v", err)
	}
}

func TestControlDoesNotFollowRedirectsWithCredentials(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if requests == 1 {
			http.Redirect(w, r, "/leak?token=redirect-token-secret", http.StatusFound)
			return
		}
		fmt.Fprint(w, `{"data":{}}`)
	}))
	defer server.Close()
	path := filepath.Join(t.TempDir(), "control.json")
	data, _ := json.Marshal(map[string]any{"url": server.URL, "token": strings.Repeat("x", 32), "apiVersion": 1})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	client, err := loadControl(path, os.Getuid())
	if err != nil {
		t.Fatal(err)
	}
	err = client.call("prepare", map[string]string{"ticket": "test-ticket"}, nil)
	if err == nil || !strings.Contains(err.Error(), "302") || strings.Contains(err.Error(), "redirect-token-secret") {
		t.Fatalf("重定向必须作为固定状态错误返回：%v", err)
	}
	if requests != 1 {
		t.Fatalf("携带凭据的请求不应跟随重定向：请求数=%d", requests)
	}
}

func TestControlDiscoveryRequiresPrivateOwnedLoopbackFile(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "control.json")
	write := func(address string) {
		t.Helper()
		body, _ := json.Marshal(map[string]any{"url": address, "apiVersion": 1, "token": strings.Repeat("x", 32)})
		if err := os.WriteFile(path, body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("http://127.0.0.1:9090")
	if _, err := loadControl(path, os.Getuid()); err != nil {
		t.Fatal(err)
	}
	if _, err := loadControl(path, os.Getuid()+1); err == nil {
		t.Fatal("错误的文件所有者未被拒绝")
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadControl(path, os.Getuid()); err == nil {
		t.Fatal("可被其他用户读取的发现文件未被拒绝")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := loadControl(link, os.Getuid()); err == nil {
		t.Fatal("符号链接未被拒绝")
	}
	for _, address := range []string{"http://example.com:9090", "https://127.0.0.1:9090", "http://127.0.0.1:9090/private", "http://user@127.0.0.1:9090"} {
		write(address)
		if _, err := loadControl(path, os.Getuid()); err == nil {
			t.Fatalf("错误管理地址未被拒绝：%s", address)
		}
	}
}
