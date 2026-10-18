package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"time"
)

type controlClient struct {
	base, token string
	client      *http.Client
}

func loadControl(path string, uid int) (*controlClient, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || validateControlFile(path, info, uid) != nil {
		return nil, fmt.Errorf("内核发现文件的所有者或权限无效")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return nil, fmt.Errorf("内核发现文件在读取前发生变化")
	}
	var config struct {
		URL     string `json:"url"`
		Token   string `json:"token"`
		Version int    `json:"apiVersion"`
	}
	if err = json.NewDecoder(io.LimitReader(file, 16384)).Decode(&config); err != nil {
		return nil, fmt.Errorf("内核发现文件格式无效")
	}
	address, err := url.Parse(config.URL)
	if err != nil || address.Scheme != "http" || address.Hostname() != "127.0.0.1" || address.Port() == "" || address.User != nil || address.RawQuery != "" || address.Fragment != "" || (address.Path != "" && address.Path != "/") || config.Version != 1 || len(config.Token) < 32 {
		return nil, fmt.Errorf("只允许访问本机 API v1 内核")
	}
	return &controlClient{base: "http://" + address.Host, token: config.Token, client: &http.Client{
		Timeout: 4 * time.Second, Transport: &http.Transport{Proxy: nil},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}
func (c *controlClient) call(path string, body any, result any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("内核请求数据格式无效")
	}
	request, err := http.NewRequest(http.MethodPost, c.base+"/api/v1/tun/"+path, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("内核请求地址无效")
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("Content-Type", "application/json")
	response, err := c.client.Do(request)
	if err != nil {
		return fmt.Errorf("访问内核失败，请检查本机管理接口")
	}
	defer response.Body.Close()
	// 原始响应和解析错误可能带有认证信息，仅记录可信的数值状态码。
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("内核拒绝虚拟网卡操作（HTTP %d）", response.StatusCode)
	}
	var envelope struct {
		Data json.RawMessage `json:"data"`
	}
	if err = json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&envelope); err != nil {
		return fmt.Errorf("内核响应格式无效")
	}
	if result != nil {
		if err = json.Unmarshal(envelope.Data, result); err != nil {
			return fmt.Errorf("内核响应字段无效")
		}
	}
	return nil
}

func run(control *controlClient, owner int, ticket string) (failure error) {
	name, networkStamp, err := primaryNetwork()
	if err != nil {
		return err
	}
	prefixes, err := routePrefixes(name)
	if err != nil {
		return err
	}
	var prepared struct {
		Session string `json:"session"`
		Proxy   string `json:"proxy"`
		Engine  string `json:"engine"`
	}
	if err = control.call("prepare", map[string]any{"interface": name, "ticket": ticket}, &prepared); err != nil {
		return err
	}
	defer func() {
		message := ""
		if failure != nil {
			message = failure.Error()
		}
		if err := control.call("finish", map[string]any{"session": prepared.Session, "error": message}, nil); err != nil {
			failure = errors.Join(failure, err)
		}
	}()
	ctx, cancel := signal.NotifyContext(context.Background(), terminationSignals()...)
	defer cancel()
	dialer := localDialer{proxy: prepared.Proxy}
	tun, err := openTun()
	if err != nil {
		return err
	}
	device, stopped, err := startForwarding(prepared.Engine, ctx, dialer, tun)
	if err != nil {
		return errors.Join(err, tun.Close())
	}
	// 先关闭虚拟网卡以唤醒读取，再关闭转发组件，最后通知 Java 恢复出口并退出工作进程。
	defer func() { cancel(); failure = errors.Join(failure, tun.Close(), device.Close()) }()
	// 数据转发已经就绪后再接管路由；任意失败都按相反顺序释放。
	check := func() error {
		var heartbeat struct {
			Stop bool `json:"stop"`
		}
		if err := control.call("heartbeat", map[string]any{"session": prepared.Session, "ready": false}, &heartbeat); err != nil {
			return err
		}
		if heartbeat.Stop || ctx.Err() != nil || !ownerAlive(owner) {
			return fmt.Errorf("虚拟网卡启动已取消")
		}
		return nil
	}
	if err = check(); err != nil {
		return err
	}
	if err = tun.prepareBypass(name); err != nil {
		return err
	}
	if err = tun.install(prefixes, check); err != nil {
		return err
	}
	guardDone := tun.guardDone()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		var heartbeat struct {
			Stop bool `json:"stop"`
		}
		if err = control.call("heartbeat", map[string]any{"session": prepared.Session, "ready": true}, &heartbeat); err != nil {
			return err
		}
		if heartbeat.Stop {
			return nil
		}
		select {
		case <-guardDone:
			return fmt.Errorf("路由清理进程已退出")
		case <-ctx.Done():
			return nil
		case err := <-stopped:
			if err == nil {
				return fmt.Errorf("虚拟网卡数据通道已结束")
			}
			return err
		case <-ticker.C:
			if !ownerAlive(owner) {
				return nil
			}
			current, stamp, err := primaryNetwork()
			if err != nil || current != name || stamp != networkStamp {
				return fmt.Errorf("网络出口已变化，虚拟网卡已关闭，请重新开启")
			}
		}
	}
}
