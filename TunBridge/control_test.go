package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
