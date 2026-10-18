package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"syscall"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--route-guard" {
		if err := runRouteGuard(); err != nil {
			fmt.Fprintln(os.Stderr, "路由清理失败：", err)
			os.Exit(1)
		}
		return
	}
	endpoint := flag.String("control-file", "", "内核发现文件")
	service := flag.Bool("service", false, "运行已安装的系统辅助服务")
	install := flag.Bool("install-service", false, "安装或更新系统辅助服务")
	remove := flag.Bool("remove-service", false, "移除系统辅助服务")
	client := flag.Bool("client", false, "通过系统辅助服务启动虚拟网卡")
	status := flag.Bool("service-status", false, "检查系统辅助服务及组件版本")
	owner := flag.Int("owner-pid", 0, "客户端进程 ID")
	uid := flag.Int("owner-uid", -1, "客户端用户 ID")
	ticket := flag.String("ticket", "", "单次启动标识")
	flag.Parse()
	var serviceErr error
	switch {
	case *service:
		serviceErr = runService(*uid)
	case *install:
		serviceErr = installService(*uid)
	case *remove:
		serviceErr = removeService()
	case *client:
		serviceErr = runServiceClient(*endpoint, *ticket, *owner)
	case *status:
		serviceErr = checkService()
	default:
		goto session
	}
	if serviceErr != nil {
		fmt.Fprintln(os.Stderr, "系统辅助服务操作失败：", serviceErr)
		if errors.Is(serviceErr, errServiceInstall) {
			os.Exit(78)
		}
		os.Exit(1)
	}
	return
session:
	if os.Geteuid() != 0 || *owner <= 1 || *uid < 0 || *endpoint == "" {
		fmt.Fprintln(os.Stderr, "虚拟网卡需要管理员授权和完整启动参数")
		os.Exit(1)
	}
	if syscall.Kill(*owner, 0) != nil {
		fmt.Fprintln(os.Stderr, "客户端进程已退出："+strconv.Itoa(*owner))
		os.Exit(1)
	}
	control, err := loadControl(*endpoint, *uid)
	if err == nil {
		err = run(control, *owner, *ticket)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "虚拟网卡运行失败：", err)
		os.Exit(1)
	}
}
