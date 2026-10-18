package main

import (
	"flag"
	"fmt"
	"os"

	"golang.org/x/sys/windows"
)

func main() {
	endpoint := flag.String("control-file", "", "内核发现文件")
	ticket := flag.String("ticket", "", "单次启动标识")
	owner := flag.Int("owner-pid", 0, "客户端进程 ID")
	flag.Parse()
	if !windows.GetCurrentProcessToken().IsElevated() || *owner <= 1 || *endpoint == "" || *ticket == "" {
		fmt.Fprintln(os.Stderr, "虚拟网卡需要管理员授权和完整启动参数")
		os.Exit(1)
	}
	if !ownerAlive(*owner) {
		fmt.Fprintln(os.Stderr, "客户端进程已退出")
		os.Exit(1)
	}
	control, err := loadControl(*endpoint, *owner)
	if err == nil {
		err = run(control, *owner, *ticket)
	}
	if err != nil {
		if control != nil {
			// 网卡创建前失败也要撤销本次授权，并将具体原因保留在内核状态中。
			_ = control.call("finish", map[string]any{"session": *ticket, "error": err.Error()}, nil)
		}
		fmt.Fprintln(os.Stderr, "虚拟网卡运行失败：", err)
		os.Exit(1)
	}
}
