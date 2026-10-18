package main

import (
	"fmt"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

func validateControlFile(path string, _ os.FileInfo, pid int) error {
	token := windows.GetCurrentProcessToken()
	if pid > 0 {
		process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
		if err != nil {
			return err
		}
		defer windows.CloseHandle(process)
		if err = windows.OpenProcessToken(process, windows.TOKEN_QUERY, &token); err != nil {
			return err
		}
		defer token.Close()
	}
	user, err := token.GetTokenUser()
	if err != nil {
		return err
	}
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	if owner == nil || !owner.Equals(user.User.Sid) {
		return fmt.Errorf("发现文件不属于客户端用户")
	}
	// 提权后仍只接受当前用户的发现文件，防止其他会话借助辅助程序安装路由。
	current, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	if !owner.Equals(current.User.Sid) {
		return fmt.Errorf("客户端和辅助程序不属于同一用户")
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if acl == nil || acl.AceCount == 0 {
		return fmt.Errorf("发现文件缺少私有访问权限")
	}
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			return err
		}
		if ace.Header.AceType == windows.ACCESS_DENIED_ACE_TYPE {
			continue
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return fmt.Errorf("发现文件包含不支持的访问控制条目")
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.Equals(owner) && !sid.IsWellKnown(windows.WinLocalSystemSid) && !sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) {
			return fmt.Errorf("其他用户能够访问内核发现文件")
		}
	}
	return nil
}

func ownerAlive(pid int) bool {
	process, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(process)
	state, err := windows.WaitForSingleObject(process, 0)
	return err == nil && state == uint32(windows.WAIT_TIMEOUT)
}
func terminationSignals() []os.Signal { return []os.Signal{os.Interrupt} }
