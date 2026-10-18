package main

import (
	"golang.org/x/sys/windows"
	"os"
	"testing"
)

func setTestDACL(t *testing.T, path, extra string) {
	t.Helper()
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	descriptor, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;" + user.User.Sid.String() + ")" + extra)
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := descriptor.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err = windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
		t.Fatal(err)
	}
}
func privateTestFile(t *testing.T, path string) { setTestDACL(t, path, "") }
func assertDiscoveryPermissions(t *testing.T, path string) {
	t.Helper()
	if _, err := loadControl(path, os.Getpid()); err != nil {
		t.Fatal(err)
	}
	setTestDACL(t, path, "(A;;FR;;;WD)")
	if _, err := loadControl(path, os.Getpid()); err == nil {
		t.Fatal("Everyone 可读的发现文件未被拒绝")
	}
	privateTestFile(t, path)
	if _, err := loadControl(path, 0x7fffffff); err == nil {
		t.Fatal("无效的客户端进程未被拒绝")
	}
}
