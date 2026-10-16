package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"os/exec"
	"strings"
)

const maxGuardRoutes = 64

// 作用域路由由同次授权中的子进程持有；主进程被强制结束时，管道关闭仍会触发清理。
type routeGuard struct {
	input    io.WriteCloser
	requests *json.Encoder
	replies  *json.Decoder
	done     chan struct{}
	failure  error
}

func startRouteGuard() (*routeGuard, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	child := exec.Command(executable, "--route-guard")
	input, err := child.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := child.StdoutPipe()
	if err != nil {
		input.Close()
		return nil, err
	}
	child.Stderr = os.Stderr
	if err = child.Start(); err != nil {
		input.Close()
		output.Close()
		return nil, err
	}
	guard := &routeGuard{input: input, requests: json.NewEncoder(input), replies: json.NewDecoder(output), done: make(chan struct{})}
	go func() { guard.failure = child.Wait(); close(guard.done) }()
	return guard, nil
}
func (g *routeGuard) add(args []string) error {
	if err := g.requests.Encode(args); err != nil {
		return err
	}
	var failure string
	if err := g.replies.Decode(&failure); err != nil {
		return err
	}
	if failure != "" {
		return fmt.Errorf("准备出口路由失败：%s", failure)
	}
	return nil
}
func (g *routeGuard) close() error {
	g.input.Close()
	<-g.done
	return g.failure
}

func runRouteGuard() (failure error) {
	if os.Geteuid() != 0 {
		return fmt.Errorf("路由清理进程需要管理员权限")
	}
	var owned [][]string
	defer func() {
		for i := len(owned) - 1; i >= 0; i-- {
			_, err := command("/sbin/route", append([]string{"-n", "delete"}, owned[i]...)...)
			failure = errors.Join(failure, err)
		}
	}()
	input := json.NewDecoder(io.LimitReader(os.Stdin, 16384))
	output := json.NewEncoder(os.Stdout)
	for {
		var args []string
		if err := input.Decode(&args); err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		if !validRouteGuardRequest(args, len(owned)) {
			return fmt.Errorf("路由清理进程收到无效请求")
		}
		_, err := command("/sbin/route", append([]string{"-n", "add"}, args...)...)
		message := ""
		if err != nil {
			message = err.Error()
		} else {
			owned = append(owned, args)
		}
		if err := output.Encode(message); err != nil {
			return err
		}
	}
}

// 子进程仅接受有数量上限的作用域默认路由和局域网直连路由，不提供任意路由操作入口。
func validRouteGuardRequest(args []string, owned int) bool {
	if owned >= maxGuardRoutes || (len(args) != 6 && len(args) != 7) || (args[0] != "-inet" && args[0] != "-inet6") || args[1] != "-net" {
		return false
	}
	name := args[len(args)-1]
	if name == "" || name == "lo0" || strings.HasPrefix(name, "utun") || strings.HasPrefix(name, "-") || strings.ContainsAny(name, " \t\r\n\x00") {
		return false
	}
	if len(args) == 6 {
		gateway, err := netip.ParseAddr(args[3])
		return args[2] == "default" && args[4] == "-ifscope" && err == nil && gateway.Is4() == (args[0] == "-inet") && (gateway.Zone() == "" || gateway.Zone() == name)
	}
	prefix, err := netip.ParsePrefix(args[2])
	return args[3] == "-interface" && args[4] == name && args[5] == "-ifscope" && err == nil && prefix == prefix.Masked() && prefix.Addr().Is4() == (args[0] == "-inet") && prefix.Bits() > 0 && prefix.Bits() < prefix.Addr().BitLen() && !prefix.Addr().IsLinkLocalUnicast()
}
