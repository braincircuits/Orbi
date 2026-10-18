package main

import (
	"fmt"
	"os"
	"syscall"
)

func validateControlFile(_ string, info os.FileInfo, uid int) error {
	if info.Mode().Perm()&0077 != 0 || info.Sys().(*syscall.Stat_t).Uid != uint32(uid) {
		return fmt.Errorf("内核发现文件的所有者或权限无效")
	}
	return nil
}
func ownerAlive(pid int) bool { return syscall.Kill(pid, 0) == nil }
func terminationSignals() []os.Signal {
	return []os.Signal{os.Interrupt, syscall.SIGTERM, syscall.SIGHUP}
}
