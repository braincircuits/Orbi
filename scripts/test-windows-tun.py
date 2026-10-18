#!/usr/bin/env python3
"""在独立数据库中验证完整内核/Wintun 会话，通过系统 UAC 授权后临时接管流量。"""
import argparse
import http.client
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bundle", type=Path, help="已打包的 Windows 应用目录")
parser.add_argument("--http-url", required=True, help="验证真实出口的可访问 HTTP 地址")
parser.add_argument("--bind-only", type=int, metavar="接口索引", help="仅验证真实接口的内核出口绑定，不创建网卡或修改路由")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
bundle = args.bundle.resolve()
url = urllib.parse.urlsplit(args.http_url)
if os.name != "nt" or url.scheme != "http" or not url.hostname or url.username:
    raise SystemExit("请在 Windows 上提供不含凭据的 HTTP 测试地址")

def probe():
    connection = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=10)
    try:
        connection.request("HEAD", url.path or "/", headers={"Connection": "close"})
        response = connection.getresponse()
        response.read()
        return response.status
    finally:
        connection.close()

baseline = probe()
directory = Path(tempfile.mkdtemp(prefix="windows-tun-live-", dir=root / "target"))
endpoint = directory / "control.json"
report = {"success": False, "baselineHttpStatus": baseline}
java = bundle / "proxy/runtime/bin/java.exe"
native = bundle / "proxy/network-core.exe"
kernel_command = [str(native)] if native.is_file() else [str(java), "--enable-native-access=ALL-UNNAMED", "-jar", str(bundle / "proxy/client.jar")]
launcher = None
control = None
revision = 0
client = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def api(method, path, body=None):
    global revision
    request = urllib.request.Request(control["url"] + "/api/v1" + path,
        data=None if body is None else json.dumps(body).encode(), method=method,
        headers={"Authorization": "Bearer " + control["token"], "Content-Type": "application/json", "If-Match": f'"{revision}"'})
    with client.open(request, timeout=8) as response:
        result = json.load(response)
    revision = result.get("revision", revision)
    return result["data"]

def wait_state(expected, seconds=100):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = api("GET", "/status")["tun"]
        if state["state"] == expected:
            return state
        if state["state"] == "failed":
            raise RuntimeError("TUN 会话失败：" + state["error"])
        if launcher and launcher.poll() is not None and expected == "running":
            raise RuntimeError("管理员测试入口已提前退出，请查看本次诊断日志")
        time.sleep(0.2)
    raise TimeoutError("等待 TUN 状态超时：" + expected)

with (directory / "kernel.log").open("wb") as output:
    kernel = subprocess.Popen([*kernel_command,
        "--web", "--db", str(directory / "kernel.db"), "--port", "0", "--endpoint-file", str(endpoint)], stdout=output, stderr=subprocess.STDOUT, cwd=directory)
    try:
        for _ in range(150):
            if endpoint.exists():
                control = json.loads(endpoint.read_text(encoding="utf-8"))
                break
            if kernel.poll() is not None:
                raise RuntimeError("测试内核已退出")
            time.sleep(0.1)
        if not control:
            raise TimeoutError("测试内核启动超时")
        api("GET", "/config")
        api("PATCH", "/settings", {"port": 0})
        api("PUT", "/routing/mode", {"mode": "direct"})
        api("POST", "/proxy/start")
        ticket = api("POST", "/tun/request", {"engine": "outline"})["ticket"]
        if args.bind_only is not None:
            prepared = api("POST", "/tun/prepare", {"interface": str(args.bind_only), "ticket": ticket})
            api("POST", "/tun/heartbeat", {"session": prepared["session"], "ready": True})
            host, port = prepared["proxy"].rsplit(":", 1)
            connection = http.client.HTTPConnection(host, int(port), timeout=10)
            try:
                connection.request("HEAD", args.http_url, headers={"Connection": "close"})
                response = connection.getresponse()
                response.read()
                report["boundHttpStatus"] = response.status
                if response.status != baseline:
                    raise RuntimeError("真实接口绑定后 HTTP 状态与基线不同")
            finally:
                connection.close()
                api("POST", "/tun/finish", {"session": prepared["session"], "error": ""})
            report["success"] = True
            print("内核真实接口 JNI 绑定与 HTTP 转发通过，未创建网卡或修改路由", flush=True)
            raise SystemExit(0)
        helper = bundle / "proxy/network-tun.exe"
        command = directory / "run-live.cmd"
        log = directory / "wintun.log"
        # 先由普通用户创建日志，提权进程只截断写入，保留调用者的文件所有权与读取权限。
        log.write_bytes(b"")
        test = root / "target/tun.test.exe"
        # 第一个测试检查两个组件的保留网段，随后启动真实内核会话；共用一次 UAC 授权。
        commands = ["@echo off", "chcp 65001 >nul",
            subprocess.list2cmdline([str(test), "-test.run", "TestWindowsWintunLive", "-orbi-wintun-live", "-test.v", "-test.timeout", "120s"]) + f' > "{log}" 2>&1',
            "if errorlevel 1 exit /b 1",
            subprocess.list2cmdline([str(helper), "--control-file", str(endpoint), "--ticket", ticket, "--owner-pid", str(kernel.pid)]) + f' >> "{log}" 2>&1']
        command.write_text("\r\n".join(commands) + "\r\n", encoding="utf-8")
        environment = dict(os.environ, ORBI_LIVE_COMMAND=str(command))
        print("独立测试内核已就绪，等待系统管理员授权…", flush=True)
        launcher = subprocess.Popen(["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
            """$ErrorActionPreference='Stop';$p=Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c',('"'+$env:ORBI_LIVE_COMMAND+'"')) -Verb RunAs -WindowStyle Hidden -PassThru -Wait;exit $p.ExitCode"""], env=environment)
        status = wait_state("running")
        report["interfaceIndex"] = status["interfaceIndex"]
        print("完整 TUN 会话已启动，正在验证真实网络出口…", flush=True)
        report["tunHttpStatus"] = probe()
        if report["tunHttpStatus"] != baseline:
            raise RuntimeError("接管后 HTTP 状态与基线不同")
        api("POST", "/tun/stop")
        wait_state("off", 30)
        launcher.wait(timeout=15)
        if launcher.returncode != 0:
            raise RuntimeError("TUN 辅助进程退出失败")
        report["success"] = True
        print("完整 TUN 会话、真实出口绑定和正常清理均已通过", flush=True)
    finally:
        # 授权超时后撤销一次性入口，防止稍后确认时启动已经失效的测试。
        if launcher and not report["success"]:
            command.write_text("@echo off\r\nexit /b 1\r\n", encoding="ascii")
        if control:
            try:
                api("POST", "/tun/stop")
                api("POST", "/kernel/shutdown")
            except (OSError, ValueError):
                pass
        try:
            kernel.wait(timeout=20)
        except subprocess.TimeoutExpired:
            kernel.terminate()
            kernel.wait(timeout=10)
        (directory / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"测试报告：{directory / 'result.json'}", flush=True)
