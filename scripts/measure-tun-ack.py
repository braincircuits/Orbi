#!/usr/bin/env python3
"""启动隔离的真实 Java 代理，测量 ACK、转发吞吐和 CPU，不注入 ACK 延迟。"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[1]
    jar = Path(os.environ.get("NETWORK_ACK_JAR", root / "ClientG/target/clientG-1.0-SNAPSHOT.jar")).resolve()
    if not jar.is_file():
        raise RuntimeError("请先构建客户端 JAR，再执行 ACK 测量")
    transport = os.environ.get("NETWORK_ACK_TRANSPORT", "kqueue")
    source = root / "ClientG/src/test/java/com/blacicada/manual/TunRelayProbe.java"
    timeout = max(90, int(os.environ.get("NETWORK_ACK_MIB", "64")) // 4 + 10)
    with tempfile.TemporaryDirectory(prefix="ack-kernel-", dir=root / "target") as temporary:
        directory = Path(temporary)
        with (directory / "kernel.log").open("w+") as log:
            process = subprocess.Popen([
                "java", "--enable-native-access=ALL-UNNAMED", "--class-path", str(jar),
                str(source), transport,
            ], cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            buffered = b""

            def snapshot(request=True):
                nonlocal buffered
                if request:
                    process.stdin.write("采样\n".encode())
                    process.stdin.flush()
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    # 不混用文本预读和 fd 可读事件，日志与快照同批到达时也能完整取出。
                    if b"\n" not in buffered:
                        if not selector.select(max(0, deadline - time.monotonic())):
                            break
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            break
                        buffered += chunk
                        continue
                    raw, buffered = buffered.split(b"\n", 1)
                    line = raw.decode("utf-8", errors="replace")
                    if line.startswith("测量快照："):
                        return json.loads(line.removeprefix("测量快照："))
                    log.write(line + "\n")
                log.flush()
                log.seek(0)
                raise RuntimeError("测试代理未返回采样：" + log.read())

            try:
                ready = snapshot(False)
                environment = dict(os.environ, NETWORK_ACK_MEASURE="1", NETWORK_ACK_PROXY=ready["address"])
                print("测量链路：测试 TCP 报文 → 数据报套接字模拟 TUN 双向 I/O → lwIP → Go → 本机 TCP → Java → TCP 接收端；不添加 ACK 延迟。", flush=True)
                print("Java 传输：" + ready["transport"] + "；输出模式：" + os.environ.get("NETWORK_ACK_OUTPUT", "协议栈回调") + "；报文模式：" + os.environ.get("NETWORK_ACK_PATTERN", "满 MSS"), flush=True)
                # 首轮让独立 Java 进程预热；随后三轮保持同一进程，分别统计 CPU 和隧道可见性。
                for iteration in range(4):
                    before = snapshot()
                    started = time.monotonic()
                    active = 0
                    command = [sys.argv[1], "-test.run=^TestTCPActualACKLatency$", "-test.v", "-test.count=1", f"-test.timeout={timeout}s"]
                    print("正在预热…" if iteration == 0 else f"正在测量第 {iteration} 轮…", flush=True)
                    with subprocess.Popen(command, env=environment) as measure:
                        try:
                            while measure.poll() is None:
                                active = max(active, snapshot()["activeTunnels"])
                                if time.monotonic() - started > timeout + 5:
                                    raise RuntimeError("转发测量超时")
                                time.sleep(0.1)
                        finally:
                            if measure.poll() is None:
                                measure.kill()
                        if measure.wait() != 0:
                            raise RuntimeError("转发测量未通过")
                    after = snapshot()
                    count = after["sentBytes"] - before["sentBytes"]
                    expected = int(environment.get("NETWORK_ACK_MIB", "64")) * 1024 * 1024
                    if count != expected or active == 0:
                        raise RuntimeError(f"流量统计或实时隧道验证失败：已发送={count}，期望={expected}，可见隧道={active}")
                    cpu_seconds = (after["cpuNanos"] - before["cpuNanos"]) / 1e9
                    print("Java 测量：" + json.dumps({
                        "iteration": iteration, "warmup": iteration == 0, "cpu_seconds": cpu_seconds,
                        "cpu_ms_per_MB": cpu_seconds * 1000 / (count / 1e6), "sent_bytes": count,
                        "visible_tunnels": active,
                    }, ensure_ascii=False), flush=True)
            finally:
                selector.close()
                process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
