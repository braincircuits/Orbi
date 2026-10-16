//go:build darwin

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const serviceLabel = "com.blacicada.network-tun"
const serviceDirectory = "/Library/PrivilegedHelperTools/" + serviceLabel
const serviceExecutable = serviceDirectory + "/network-tun"
const servicePlist = "/Library/LaunchDaemons/" + serviceLabel + ".plist"
const serviceRunDirectory = "/private/var/run/" + serviceLabel
const serviceSocket = serviceRunDirectory + "/control.sock"

var errServiceInstall = errors.New("请安装或更新虚拟网卡系统辅助服务")

type serviceRequest struct {
	Action   string `json:"action"`
	Digest   string `json:"digest,omitempty"`
	Endpoint string `json:"endpoint,omitempty"`
	Ticket   string `json:"ticket,omitempty"`
}
type serviceReply struct {
	Digest string `json:"digest,omitempty"`
	Error  string `json:"error,omitempty"`
}

func executableDigest() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err = io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// 身份来自内核提供的 Unix 套接字凭据，不信任请求中的用户或进程编号。
func peerIdentity(conn *net.UnixConn) (uid, pid int, err error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var lookup error
	err = raw.Control(func(fd uintptr) {
		var cred *unix.Xucred
		cred, lookup = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if lookup != nil {
			return
		}
		uid = int(cred.Uid)
		pid, lookup = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	})
	return uid, pid, errors.Join(err, lookup)
}

func dialService() (*net.UnixConn, error) {
	connection, err := net.DialTimeout("unix", serviceSocket, 3*time.Second)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED) {
			return nil, errServiceInstall
		}
		return nil, fmt.Errorf("连接系统辅助服务失败：%w", err)
	}
	conn := connection.(*net.UnixConn)
	uid, _, err := peerIdentity(conn)
	if err != nil || uid != 0 {
		conn.Close()
		return nil, fmt.Errorf("系统辅助服务身份无效")
	}
	return conn, nil
}

func serviceExchange(action string) (serviceReply, error) {
	conn, err := dialService()
	if err != nil {
		return serviceReply{}, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if err = json.NewEncoder(conn).Encode(serviceRequest{Action: action}); err != nil {
		return serviceReply{}, err
	}
	var response serviceReply
	if err = json.NewDecoder(io.LimitReader(conn, 16384)).Decode(&response); err != nil {
		return response, err
	}
	if response.Error != "" {
		return response, errors.New(response.Error)
	}
	return response, nil
}

func checkService() error {
	response, err := serviceExchange("status")
	if err != nil {
		return err
	}
	digest, err := executableDigest()
	if err != nil {
		return err
	}
	if response.Digest != digest {
		return errServiceInstall
	}
	return nil
}

// 非特权客户端只提交固定格式请求，持续持有连接；界面退出后关闭连接以清理本次 TUN。
func runServiceClient(endpoint, ticket string, owner int) error {
	if owner <= 1 || os.Getppid() != owner {
		return fmt.Errorf("虚拟网卡客户端的父进程无效")
	}
	conn, err := dialService()
	if err != nil {
		return err
	}
	defer conn.Close()
	digest, err := executableDigest()
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				conn.Close()
				return
			case <-ticker.C:
				if os.Getppid() != owner || syscall.Kill(owner, 0) != nil {
					conn.Close()
					return
				}
			}
		}
	}()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err = json.NewEncoder(conn).Encode(serviceRequest{Action: "start", Digest: digest, Endpoint: endpoint, Ticket: ticket}); err != nil {
		return err
	}
	decoder := json.NewDecoder(io.LimitReader(conn, 32768))
	var response serviceReply
	if err = decoder.Decode(&response); err != nil {
		return err
	}
	if response.Error != "" {
		return errors.New(response.Error)
	}
	conn.SetDeadline(time.Time{})
	if err = decoder.Decode(&response); err != nil {
		return fmt.Errorf("系统辅助服务连接已中断：%w", err)
	}
	if response.Error != "" {
		return errors.New(response.Error)
	}
	return nil
}

type tunService struct {
	uid              int
	digest           string
	mutex            sync.Mutex
	active, draining bool
	ctx              context.Context
}

func (s *tunService) handle(conn *net.UnixConn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	reply := func(err error) {
		response := serviceReply{Digest: s.digest}
		if err != nil {
			response.Error = err.Error()
		}
		conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_ = json.NewEncoder(conn).Encode(response)
	}
	uid, pid, err := peerIdentity(conn)
	if err != nil || (uid != s.uid && uid != 0) {
		reply(fmt.Errorf("当前用户未获准使用此系统辅助服务"))
		return
	}
	var request serviceRequest
	if err = json.NewDecoder(io.LimitReader(conn, 16384)).Decode(&request); err != nil {
		reply(fmt.Errorf("辅助服务请求格式无效"))
		return
	}
	if request.Action == "status" {
		reply(nil)
		return
	}
	if request.Action == "prepare-install" || request.Action == "cancel-install" {
		if uid != 0 {
			reply(fmt.Errorf("更新辅助服务需要管理员授权"))
			return
		}
		s.mutex.Lock()
		if s.active {
			err = fmt.Errorf("请先关闭虚拟网卡，再更新或移除辅助服务")
		} else {
			s.draining = request.Action == "prepare-install"
		}
		s.mutex.Unlock()
		reply(err)
		return
	}
	if request.Action != "start" || uid != s.uid || pid <= 1 || request.Digest != s.digest || len(request.Ticket) < 16 || len(request.Ticket) > 128 || !strings.HasPrefix(request.Endpoint, "/") {
		reply(fmt.Errorf("辅助服务启动请求无效或组件版本不一致"))
		return
	}
	// 先检查发现文件，再启动固定的 root 所有程序；请求不能指定命令、环境变量或任意路由。
	if _, err = loadControl(request.Endpoint, uid); err != nil {
		reply(err)
		return
	}
	s.mutex.Lock()
	if s.active || s.draining {
		s.mutex.Unlock()
		reply(fmt.Errorf("系统辅助服务正在运行虚拟网卡或等待更新"))
		return
	}
	s.active = true
	s.mutex.Unlock()
	release := func() { s.mutex.Lock(); s.active = false; s.mutex.Unlock() }
	child := exec.Command(serviceExecutable, "--control-file", request.Endpoint, "--ticket", request.Ticket,
		"--owner-pid", strconv.Itoa(pid), "--owner-uid", strconv.Itoa(uid))
	child.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", "TMPDIR=/private/tmp"}
	// 会话另建进程组，服务异常退出时保留会话及路由清理进程完成退出清理的机会。
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var output limitedServiceLog
	child.Stderr = &output
	if err = child.Start(); err != nil {
		release()
		reply(fmt.Errorf("启动虚拟网卡会话失败：%w", err))
		return
	}
	reply(nil)
	conn.SetDeadline(time.Time{})
	disconnected := make(chan struct{})
	go func() { var b [1]byte; _, _ = conn.Read(b[:]); close(disconnected) }()
	done := make(chan error, 1)
	go func() { done <- child.Wait() }()
	select {
	case err = <-done:
	case <-disconnected:
		err = stopServiceWorker(child, done)
	case <-s.ctx.Done():
		err = stopServiceWorker(child, done)
	}
	if err != nil {
		err = fmt.Errorf("虚拟网卡会话结束：%s（%v）", strings.TrimSpace(output.text), err)
	}
	// 退出通知到达界面后即可启动下一会话，先释放服务占用再发送通知。
	release()
	reply(err)
}

type limitedServiceLog struct{ text string }

func (l *limitedServiceLog) Write(data []byte) (int, error) {
	if len(l.text) < 8192 {
		l.text += string(data[:min(len(data), 8192-len(l.text))])
	}
	return len(data), nil
}
func stopServiceWorker(child *exec.Cmd, done <-chan error) error {
	_ = child.Process.Signal(syscall.SIGTERM)
	select {
	case err := <-done:
		return err
	case <-time.After(30 * time.Second):
		_ = child.Process.Kill()
		return <-done
	}
}

func runService(uid int) error {
	if os.Geteuid() != 0 || uid <= 0 {
		return fmt.Errorf("系统辅助服务需要管理员权限和有效用户")
	}
	if err := secureRootDirectory(serviceRunDirectory, 0755); err != nil {
		return err
	}
	// launchd 的 umask 为 0077；目录允许遍历，访问控制由下面的 0600 套接字负责。
	if err := os.Chmod(serviceRunDirectory, 0755); err != nil {
		return err
	}
	if info, err := os.Lstat(serviceSocket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return fmt.Errorf("辅助服务套接字路径被非套接字占用")
		}
		if err = os.Remove(serviceSocket); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// 监听创建到设置所有者之间，套接字不向其他本机用户开放。
	previous := unix.Umask(0077)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: serviceSocket, Net: "unix"})
	unix.Umask(previous)
	if err != nil {
		return err
	}
	defer listener.Close()
	if err = os.Chown(serviceSocket, uid, 0); err != nil {
		return err
	}
	if err = os.Chmod(serviceSocket, 0600); err != nil {
		return err
	}
	digest, err := executableDigest()
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	go func() { <-ctx.Done(); listener.Close() }()
	service := &tunService{uid: uid, digest: digest, ctx: ctx}
	var workers sync.WaitGroup
	defer func() { cancel(); workers.Wait() }()
	// 限制同时等待请求的连接，避免同用户错误程序无限创建处理线程。
	slots := make(chan struct{}, 16)
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		select {
		case slots <- struct{}{}:
			workers.Add(1)
			go func() { defer workers.Done(); defer func() { <-slots }(); service.handle(conn) }()
		default:
			conn.Close()
		}
	}
}
