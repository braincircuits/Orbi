package main

import (
	"os"
	"path/filepath"
	"testing"
)

func privateTestFile(t *testing.T, path string) { t.Helper() }
func assertDiscoveryPermissions(t *testing.T, path string) {
	t.Helper()
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
	link := filepath.Join(filepath.Dir(path), "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := loadControl(link, os.Getuid()); err == nil {
		t.Fatal("符号链接未被拒绝")
	}
}
