//go:build darwin

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// 仅在预定的系统目录安装，不沿符号链接写文件，也不使用用户可写的程序作为常驻服务。
func secureRootDirectory(path string, mode os.FileMode) error {
	created := false
	if err := os.Mkdir(path, mode); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	} else if err == nil {
		created = true
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 || info.Sys().(*syscall.Stat_t).Uid != 0 {
		return fmt.Errorf("系统辅助服务目录的所有者或权限无效：%s", path)
	}
	if created {
		return os.Chmod(path, mode)
	}
	return nil
}
func writeRootFile(path string, data []byte, mode os.FileMode) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".network-tun-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	defer file.Close()
	if _, err = file.Write(data); err != nil {
		return err
	}
	if err = file.Chmod(mode); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(temp, path)
}
func launchDaemonPlist(uid int) []byte {
	return []byte(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>` + serviceLabel + `</string>
<key>ProgramArguments</key><array><string>` + serviceExecutable + `</string><string>--service</string><string>--owner-uid</string><string>` + strconv.Itoa(uid) + `</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>ExitTimeOut</key><integer>40</integer>
<key>ProcessType</key><string>Background</string>
<key>UserName</key><string>root</string>
<key>Umask</key><integer>63</integer>
</dict></plist>
`)
}
func stopInstalledService() error {
	_, err := serviceExchange("prepare-install")
	if err != nil && !errors.Is(err, errServiceInstall) {
		return err
	}
	if _, err = command("/bin/launchctl", "bootout", "system/"+serviceLabel); err != nil {
		if _, active := command("/bin/launchctl", "print", "system/"+serviceLabel); active == nil {
			_, _ = serviceExchange("cancel-install")
			return err
		}
	}
	return nil
}
func installService(uid int) error {
	if os.Geteuid() != 0 || uid <= 0 {
		return fmt.Errorf("安装系统辅助服务需要管理员授权和有效用户")
	}
	// 检查固定父目录，已有目录权限不合格时拒绝，不替用户修改系统目录权限。
	for _, path := range []string{"/Library", "/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", serviceDirectory} {
		if err := secureRootDirectory(path, 0755); err != nil {
			return err
		}
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(executable)
	if err != nil {
		return err
	}
	if err = stopInstalledService(); err != nil {
		return err
	}
	if err = writeRootFile(serviceExecutable, data, 0755); err != nil {
		return err
	}
	if err = writeRootFile(servicePlist, launchDaemonPlist(uid), 0644); err != nil {
		return err
	}
	if _, err = command("/bin/launchctl", "enable", "system/"+serviceLabel); err != nil {
		return err
	}
	if _, err = command("/bin/launchctl", "bootstrap", "system", servicePlist); err != nil {
		return err
	}
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if err = checkService(); err == nil {
			fmt.Println("虚拟网卡系统辅助服务已安装，后续开启无需重复授权")
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("系统辅助服务已安装但尚未就绪：%w", err)
}
func removeService() error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("移除系统辅助服务需要管理员授权")
	}
	if err := stopInstalledService(); err != nil {
		return err
	}
	// 只移除本功能创建的固定文件；不清理客户端配置、证书、日志或历史记录。
	for _, path := range []string{servicePlist, serviceExecutable, serviceSocket} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	for _, path := range []string{serviceDirectory, serviceRunDirectory} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	fmt.Println("虚拟网卡系统辅助服务已移除")
	return nil
}
