//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime/pprof"
	"runtime/trace"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.getoutline.org/sdk/network/lwip2transport"
	"golang.getoutline.org/sdk/network/packetrelay"
	"golang.getoutline.org/sdk/transport"
	"golang.org/x/sys/unix"
)

const tunLiveLocal = "198.19.254.1"
const tunLiveTarget = "198.19.254.2"
const utunMaxPendingPacketsOption = 16 // macOS 公开的 utun 待处理队列选项，仅用于隔离诊断。

// 只允许测试 TCP 到回环 sink；意外 UDP 不会发往正在运行的代理或物理网络。
type tunLiveRejectUDP struct{}

func (tunLiveRejectUDP) NewAssociation() (packetrelay.PacketSender, packetrelay.PacketReceiver, error) {
	return nil, nil, fmt.Errorf("隔离测量不接收 UDP")
}

type tunLiveEvent struct {
	StartNS int64  `json:"开始纳秒"`
	EndNS   int64  `json:"结束纳秒"`
	Bytes   int    `json:"返回字节"`
	Payload int    `json:"TCP载荷字节,omitempty"`
	Seq     uint32 `json:"TCP序号,omitempty"`
	ACK     uint32 `json:"TCP确认号,omitempty"`
	Flags   byte   `json:"TCP标志,omitempty"`
	Failed  bool   `json:"调用失败,omitempty"`
}

// 累计字节数同时作为 8 字节回复内容，可与双向 TCP 字节流逐块对齐。
// source 与 sink 各自只写所属时点，全部块完成且收到结果后才统一读取。
type tunLiveBlock struct {
	CumulativeBytes  int   `json:"累计上传字节"`
	SourceFirstWrite int64 `json:"source首个Write开始纳秒"`
	SourceLastWrite  int64 `json:"source最后Write返回纳秒"`
	SourceReplyStart int64 `json:"source回复Read开始纳秒"`
	SourceReplyEnd   int64 `json:"source回复Read返回纳秒"`
	SinkReadEnd      int64 `json:"sink收到块尾纳秒"`
	SinkReplyStart   int64 `json:"sink回复Write开始纳秒"`
	SinkReplyEnd     int64 `json:"sink回复Write返回纳秒"`
}

// 各操作使用独立记录锁，锁和切片追加均位于被测调用计时区间之外。
// 记录仍会增加整体工作量；NETWORK_TUN_LIVE_SAMPLES=0 可测无逐包记录的基线。
type tunLiveSamples struct {
	mu     sync.Mutex
	base   time.Time
	events []tunLiveEvent
}

func (s *tunLiveSamples) add(start, end time.Time, n int, err error, packet []byte) {
	event := tunLiveEvent{StartNS: start.Sub(s.base).Nanoseconds(), EndNS: end.Sub(s.base).Nanoseconds(), Bytes: n, Failed: err != nil}
	if len(packet) >= 40 && packet[0]>>4 == 4 && packet[9] == 6 {
		header := int(packet[0]&15) * 4
		if header >= 20 && len(packet) >= header+20 {
			tcp := packet[header:]
			event.Payload = max(0, int(binary.BigEndian.Uint16(packet[2:]))-header-int(tcp[12]>>4)*4)
			event.Seq, event.ACK = binary.BigEndian.Uint32(tcp[4:]), binary.BigEndian.Uint32(tcp[8:])
			event.Flags = tcp[13]
		}
	}
	s.mu.Lock()
	s.events = append(s.events, event)
	s.mu.Unlock()
}

type tunLiveMeasuredTUN struct {
	tun           *tunDevice
	reads, writes *tunLiveSamples
}

func (m tunLiveMeasuredTUN) Read(buffer []byte) (int, error) {
	started := time.Now()
	n, err := m.tun.Read(buffer)
	finished := time.Now()
	m.reads.add(started, finished, n, err, buffer[:max(0, n)])
	return n, err
}

func (m tunLiveMeasuredTUN) Write(packet []byte) (int, error) {
	started := time.Now()
	n, err := m.tun.Write(packet)
	finished := time.Now()
	m.writes.add(started, finished, n, err, packet)
	return n, err
}

// 生产 device 没有 ReaderFrom，包装只保留 Writer，不改变 forwardPackets 的 io.Copy 路径。
type tunLiveMeasuredStack struct {
	writer  io.Writer
	samples *tunLiveSamples
}

func (m tunLiveMeasuredStack) Write(packet []byte) (int, error) {
	started := time.Now()
	n, err := m.writer.Write(packet)
	finished := time.Now()
	m.samples.add(started, finished, n, err, packet)
	return n, err
}

func tunLiveRouteFields(output string) map[string]string {
	fields := make(map[string]string)
	for _, line := range strings.Split(output, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if ok {
			fields[key] = strings.TrimSpace(value)
		}
	}
	return fields
}

func openIsolatedLiveTUN(t *testing.T) (*tunDevice, func(), int, int) {
	t.Helper()
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	existing := make(map[string]bool)
	for _, nic := range interfaces {
		existing[nic.Name] = true
		addresses, err := nic.Addrs()
		if err != nil {
			t.Fatal(err)
		}
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err == nil && (ip.String() == tunLiveLocal || ip.String() == tunLiveTarget) {
				t.Fatalf("测试地址已被接口 %s 使用，拒绝覆盖", nic.Name)
			}
		}
	}
	for _, address := range []string{tunLiveLocal, tunLiveTarget} {
		output, err := command("/sbin/route", "-n", "get", "-inet", address)
		if err != nil {
			t.Fatalf("无法核对测试地址已有路由：%v", err)
		}
		if tunLiveRouteFields(output)["destination"] == address {
			t.Fatalf("测试地址 %s 已有精确主机路由，拒绝覆盖", address)
		}
	}
	// 仅复用生产设备的逐包读写；openTun 会配置正式地址，因此这里独立创建控制套接字。
	fd, err := unix.Socket(unix.AF_SYSTEM, unix.SOCK_DGRAM, 2)
	if err != nil {
		t.Fatal(err)
	}
	owned := true
	defer func() {
		if owned {
			unix.Close(fd)
		}
	}()
	unix.CloseOnExec(fd)
	var info unix.CtlInfo
	copy(info.Name[:], "com.apple.net.utun_control")
	if err = unix.IoctlCtlInfo(fd, &info); err != nil {
		t.Fatal(err)
	}
	if err = unix.Connect(fd, &unix.SockaddrCtl{ID: info.Id}); err != nil {
		t.Fatal(err)
	}
	// 先读系统原值，默认不修改，便于与生产设置做单变量对照。
	defaultPending, err := unix.GetsockoptInt(fd, 2, utunMaxPendingPacketsOption)
	if err != nil {
		t.Fatalf("读取 utun 待处理队列长度失败：%v", err)
	}
	if pending := ackMeasurementSize(t, "NETWORK_TUN_LIVE_PENDING", 0, 1, 1024); pending != 0 {
		if err = unix.SetsockoptInt(fd, 2, utunMaxPendingPacketsOption, pending); err != nil {
			t.Fatalf("设置 utun 待处理队列长度失败：%v", err)
		}
	}
	actualPending, err := unix.GetsockoptInt(fd, 2, utunMaxPendingPacketsOption)
	if err != nil {
		t.Fatalf("复核 utun 待处理队列长度失败：%v", err)
	}
	name, err := unix.GetsockoptString(fd, 2, 2)
	if err != nil {
		t.Fatal(err)
	}
	name = strings.TrimRight(name, "\x00")
	if !strings.HasPrefix(name, "utun") || existing[name] {
		t.Fatalf("新测试接口名称无效或已经存在：%s", name)
	}
	if err = unix.SetNonblock(fd, true); err != nil {
		t.Fatal(err)
	}
	tun := &tunDevice{file: os.NewFile(uintptr(fd), name), name: name}
	owned = false
	closeOnce := sync.OnceFunc(func() {
		// 未调用 install/prepareBypass；关闭自有接口即可清除其自动生成的点对点主机路由。
		if err := tun.Close(); err != nil {
			t.Errorf("关闭隔离 utun 失败：%v", err)
		}
	})
	t.Cleanup(closeOnce)
	// /32 点对点只影响这两个测试地址，不添加默认路由、局域网路由或 IPv6 接管路由。
	if _, err = command("/sbin/ifconfig", name, "inet", tunLiveLocal, tunLiveTarget, "netmask", "255.255.255.255", "mtu", strconv.Itoa(tunMTU), "up"); err != nil {
		t.Fatal(err)
	}
	nic, err := net.InterfaceByName(name)
	if err != nil || nic.MTU != tunMTU {
		t.Fatalf("隔离接口 MTU 未按预期生效：接口=%v，错误=%v", nic, err)
	}
	output, err := command("/sbin/route", "-n", "get", "-inet", tunLiveTarget)
	fields := tunLiveRouteFields(output)
	if err != nil || fields["destination"] != tunLiveTarget || fields["interface"] != name || !strings.Contains(fields["flags"], "HOST") || strings.Contains(fields["flags"], "GATEWAY") {
		t.Fatalf("独立测试主机路由未正确指向新接口：%v，%s", err, output)
	}
	t.Logf("独立测试接口=%s 本机地址=%s/32 测试目标=%s/32 待处理队列原值=%d 实际值=%d", name, tunLiveLocal, tunLiveTarget, defaultPending, actualPending)
	return tun, closeOnce, defaultPending, actualPending
}

func tunLiveSummary(events []tunLiveEvent, begin, end int64) map[string]any {
	var durations []int64
	var totalNS, totalBytes int64
	failed := 0
	payloads := make(map[int]int)
	for _, event := range events {
		if event.EndNS < begin || event.EndNS > end {
			continue
		}
		duration := event.EndNS - event.StartNS
		durations = append(durations, duration)
		totalNS += duration
		totalBytes += int64(event.Bytes)
		if event.Failed {
			failed++
		}
		if event.Payload > 0 {
			payloads[event.Payload]++
		}
	}
	result := map[string]any{"调用数": len(durations), "失败数": failed, "返回字节": totalBytes, "TCP载荷尺寸分布": payloads}
	if len(durations) != 0 {
		sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
		result["调用耗时纳秒"] = map[string]any{"平均": float64(totalNS) / float64(len(durations)), "p50": durations[len(durations)/2], "p95": durations[len(durations)*95/100], "p99": durations[len(durations)*99/100], "最大": durations[len(durations)-1]}
	}
	return result
}

// 需显式开启并由测试执行者授予管理员权限；默认的单元测试不会创建接口或改路由。
// 真实链路：普通 macOS TCP → 独立 utun → forwardPackets → SDK/lwIP → 本机 TCP sink。
// 不包含 Java、物理网卡、Windows、RDP 或文件系统，隔离吞吐不能代表实际复制速度。
func TestTUNLiveContinuousWrite(t *testing.T) {
	if os.Getenv("NETWORK_TUN_LIVE") != "1" {
		t.Skip("按需测量真实独立 utun，默认不运行")
	}
	if os.Geteuid() != 0 {
		t.Fatal("真实 utun 测量需要显式管理员执行，本测试不会自行提权")
	}
	total := ackMeasurementSize(t, "NETWORK_TUN_LIVE_MIB", 64, 1, 512) * 1024 * 1024
	blockSize, mode := total, "连续写入"
	if value := os.Getenv("NETWORK_TUN_LIVE_BLOCK"); value != "" {
		if value != "269536" {
			t.Fatal("NETWORK_TUN_LIVE_BLOCK 仅支持 269536；不设置时保持连续写入")
		}
		blockSize, mode = 269536, "逐块确认"
	}
	blocks := make([]tunLiveBlock, (total+blockSize-1)/blockSize)
	for i := range blocks {
		blocks[i].CumulativeBytes = min(total, (i+1)*blockSize)
	}
	timeout := time.Duration(ackMeasurementSize(t, "NETWORK_TUN_LIVE_TIMEOUT", 60, 5, 300)) * time.Second
	sampling := os.Getenv("NETWORK_TUN_LIVE_SAMPLES") != "0"
	parent := os.Getenv("NETWORK_TUN_LIVE_DIR")
	if parent == "" || !filepath.IsAbs(parent) {
		t.Fatal("NETWORK_TUN_LIVE_DIR 必须指定 target 诊断目录的绝对路径")
	}
	if err := os.MkdirAll(parent, 0700); err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(parent, "utun-live-")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("隔离测量输出目录：%s", directory)
	tun, closeTun, defaultPending, actualPending := openIsolatedLiveTUN(t)
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	deadline := time.Now().Add(timeout)
	if err := listener.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	port := uint16(listener.Addr().(*net.TCPAddr).Port)
	target := netip.AddrPortFrom(netip.MustParseAddr(tunLiveTarget), port)
	dialed := make(chan *net.TCPConn, 1)
	dialer := transport.FuncStreamDialer(func(ctx context.Context, address string) (transport.StreamConn, error) {
		parsed, err := netip.ParseAddrPort(address)
		if err != nil || parsed.Addr().Unmap() != target.Addr() || parsed.Port() != target.Port() {
			return nil, fmt.Errorf("拒绝转发隔离目标之外的 TCP：%s", address)
		}
		conn, err := (&net.Dialer{Deadline: deadline}).DialContext(ctx, "tcp4", listener.Addr().String())
		if err != nil {
			return nil, err
		}
		tcp := conn.(*net.TCPConn)
		if err := tcp.SetDeadline(deadline); err != nil {
			tcp.Close()
			return nil, err
		}
		select {
		case dialed <- tcp:
			return tcp, nil
		default:
			tcp.Close()
			return nil, fmt.Errorf("隔离测量只允许一条转发连接")
		}
	})
	device, err := lwip2transport.ConfigureDeviceWithRelay(dialer, tunLiveRejectUDP{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { device.Close() })
	base := time.Now()
	samples := make(map[string]*tunLiveSamples)
	for _, name := range []string{"TUN.Read", "stack.Write", "TUN.Write", "source.Write"} {
		capacity := 0
		if sampling {
			capacity = total/700 + 4096
		}
		samples[name] = &tunLiveSamples{base: base, events: make([]tunLiveEvent, 0, capacity)}
	}
	var stopped <-chan error
	if sampling {
		stopped = forwardPackets(tunLiveMeasuredStack{device, samples["stack.Write"]}, tunLiveMeasuredTUN{tun, samples["TUN.Read"], samples["TUN.Write"]})
	} else {
		stopped = forwardPackets(device, tun)
	}
	// 先关闭文件唤醒 Read/Write，再关闭栈；不等待仍打开的 utun 读取结束。
	t.Cleanup(func() {
		closeTun()
		device.Close()
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
			t.Error("隔离转发循环未及时退出")
		}
	})
	received := make(chan error, 1)
	go func() {
		conn, err := listener.AcceptTCP()
		if err != nil {
			received <- err
			return
		}
		defer conn.Close()
		if err := conn.SetDeadline(deadline); err != nil {
			received <- err
			return
		}
		buffer := make([]byte, 65536)
		count := 0
		for i := range blocks {
			block := &blocks[i]
			for count < block.CumulativeBytes {
				n, err := conn.Read(buffer[:min(len(buffer), block.CumulativeBytes-count)])
				count += n
				if count == block.CumulativeBytes {
					block.SinkReadEnd = time.Since(base).Nanoseconds()
				}
				for _, value := range buffer[:n] {
					if value != 57 {
						received <- fmt.Errorf("隔离传输内容校验失败")
						return
					}
				}
				if err != nil {
					received <- fmt.Errorf("隔离接收未完成：%d/%d：%w", count, total, err)
					return
				}
			}
			// 一收满立即回复累计字节数；连续模式只回复最终一次，分块模式每块回复一次。
			var response [8]byte
			binary.BigEndian.PutUint64(response[:], uint64(count))
			block.SinkReplyStart = time.Since(base).Nanoseconds()
			n, err := conn.Write(response[:])
			block.SinkReplyEnd = time.Since(base).Nanoseconds()
			if err == nil && n != len(response) {
				err = io.ErrShortWrite
			}
			if err != nil {
				received <- err
				return
			}
		}
		received <- nil
	}()
	conn, err := (&net.Dialer{Deadline: deadline, LocalAddr: &net.TCPAddr{IP: net.ParseIP(tunLiveLocal)}}).DialContext(context.Background(), "tcp4", target.String())
	if err != nil {
		t.Fatal(err)
	}
	source := conn.(*net.TCPConn)
	t.Cleanup(func() { source.Close() })
	if err := source.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	select {
	case downstream := <-dialed:
		t.Cleanup(func() { downstream.Close() })
	case <-time.After(time.Until(deadline)):
		t.Fatal("隔离 lwIP 转发连接建立超时")
	}
	stopProfiles := sync.OnceFunc(func() {})
	for _, profile := range []string{"CPU", "TRACE"} {
		if os.Getenv("NETWORK_TUN_LIVE_"+profile) != "1" {
			continue
		}
		file, err := os.OpenFile(filepath.Join(directory, strings.ToLower(profile)+".out"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			t.Fatal(err)
		}
		var stop func()
		if profile == "CPU" {
			err, stop = pprof.StartCPUProfile(file), pprof.StopCPUProfile
		} else {
			err, stop = trace.Start(file), trace.Stop
		}
		if err != nil {
			file.Close()
			t.Fatal(err)
		}
		prior := stopProfiles
		stopProfiles = sync.OnceFunc(func() { stop(); file.Close(); prior() })
		t.Cleanup(stopProfiles)
	}
	payload := bytes.Repeat([]byte{57}, 1645)
	started := time.Now()
	sent := 0
	var writePhaseNS, replyWaitNS int64
	var writesFinished time.Time
	for i := range blocks {
		block := &blocks[i]
		firstWrite := true
		for sent < block.CumulativeBytes {
			want := min(len(payload), block.CumulativeBytes-sent)
			var at time.Time
			if sampling || firstWrite {
				at = time.Now()
			}
			if firstWrite {
				block.SourceFirstWrite = at.Sub(base).Nanoseconds()
				firstWrite = false
			}
			n, err := source.Write(payload[:want])
			sent += n
			var returned time.Time
			if sampling || sent == block.CumulativeBytes {
				returned = time.Now()
			}
			if sampling {
				samples["source.Write"].add(at, returned, n, err, nil)
			}
			if err != nil || n != want {
				t.Fatalf("普通 TCP 写入失败：字节=%d/%d 错误=%v", n, want, err)
			}
			if sent == block.CumulativeBytes {
				writesFinished = returned
				block.SourceLastWrite = returned.Sub(base).Nanoseconds()
			}
		}
		var response [8]byte
		block.SourceReplyStart = time.Since(base).Nanoseconds()
		_, err := io.ReadFull(source, response[:])
		block.SourceReplyEnd = time.Since(base).Nanoseconds()
		if err != nil {
			t.Fatal(err)
		}
		if binary.BigEndian.Uint64(response[:]) != uint64(block.CumulativeBytes) {
			t.Fatalf("第 %d 块回复的累计字节数不符", i+1)
		}
		writePhaseNS += block.SourceLastWrite - block.SourceFirstWrite
		replyWaitNS += block.SourceReplyEnd - block.SourceReplyStart
	}
	if err := <-received; err != nil {
		t.Fatal(err)
	}
	finished := time.Now()
	stopProfiles()
	begin, end := started.Sub(base).Nanoseconds(), finished.Sub(base).Nanoseconds()
	summaries := make(map[string]any)
	for name, sample := range samples {
		sample.mu.Lock()
		summaries[name] = tunLiveSummary(sample.events, begin, end)
		if sampling {
			file, err := os.OpenFile(filepath.Join(directory, name+".json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if err == nil {
				err = json.NewEncoder(file).Encode(sample.events)
				file.Close()
			}
			if err != nil {
				sample.mu.Unlock()
				t.Fatal(err)
			}
		}
		sample.mu.Unlock()
	}
	result := map[string]any{
		"接口": tun.name, "来源": source.LocalAddr().String(), "目标": target.String(), "sink": listener.Addr().String(),
		"虚拟MTU": tunMTU,
		"模式":    mode, "块大小字节": blockSize, "块数": len(blocks), "逐块时点": blocks,
		"utun待处理队列默认值": defaultPending, "utun待处理队列实际值": actualPending,
		"数据字节": total, "每次请求写入字节": len(payload), "内容已校验": true, "逐包记录": sampling,
		"基准epoch纳秒": base.UnixNano(), "传输起点相对纳秒": begin, "完整接收确认相对纳秒": end,
		"source全部Write耗时纳秒":  writePhaseNS,
		"source首写至末写耗时纳秒":    writesFinished.Sub(started).Nanoseconds(),
		"source回复Read等待合计纳秒": replyWaitNS,
		"写入并收到完整确认耗时纳秒":      finished.Sub(started).Nanoseconds(),
		"完整接收吞吐MB每秒":         float64(total) / finished.Sub(started).Seconds() / 1e6,
		"CPU采样":              os.Getenv("NETWORK_TUN_LIVE_CPU") == "1", "Go执行跟踪": os.Getenv("NETWORK_TUN_LIVE_TRACE") == "1",
		"操作统计": summaries,
		"解释边界": []string{
			"普通 TCP socket 与转发器处于同一 Go 进程；不包含 Java、物理链路、Windows、文件读取或加密，不能替代真实复制速度。",
			"可选逐块确认只是隔离测试协议：收到并校验 269536 字节后立即回复 8 字节累计计数，发送端收到后立即继续，不模拟实际应用语义或添加延迟。",
			"source全部Write耗时是各块首个 Write 开始到末个 Write 返回的墙钟耗时之和，排除块间等待；连续模式只有一块。逐块时点和逐包事件共用单调纳秒基准。",
			"TUN.Read 完整耗时包含等待下一报文、系统调用和缓冲复制，不代表纯内核处理或 CPU 时间。",
			"stack.Write 完整耗时包含同步输出回调中的 TUN.Write，两者嵌套，不能直接相加。",
			"source.Write 返回仅表示普通 TCP socket 接受数据；最终吞吐另等接收端内容校验和完整字节数响应。",
			"记录、时钟、锁以及可选 trace/pprof 会增加负载；关闭逐包记录与分析器后重复才可判断观测开销。",
			"原始事件使用同一单调时间基准，含握手；操作统计选取结束时刻在传输窗口内的调用，首个阻塞 Read 可能始于窗口之前。",
		},
	}
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "summary.json"), append(data, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	t.Logf("隔离真实 utun %s完成：字节=%d 块数=%d 写入阶段合计=%s 回复等待合计=%s 完整接收确认=%s 吞吐=%.2f MB/s；不代表 Windows App 复制速度", mode, total, len(blocks), time.Duration(writePhaseNS), time.Duration(replyWaitNS), finished.Sub(started), float64(total)/finished.Sub(started).Seconds()/1e6)
}
