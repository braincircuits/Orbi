#!/usr/bin/env python3
"""使用本地 HTTP 目标服务验证客户端和服务端 JAR，无需访问公网。"""
import argparse
import http.client
import http.server
import pathlib
import queue
import re
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD = b"packaged-http3-ok"


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(PAYLOAD)

    def log_message(self, *_):
        pass


def launch(jar, config, marker, processes, captured=None):
    process = subprocess.Popen(
        ["java", "--enable-native-access=ALL-UNNAMED", "-jar", str(jar), str(config)],
        cwd=config.parent, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    processes.append(process)
    lines = queue.Queue()

    def collect():
        for line in process.stdout:
            if captured is not None:
                captured.append(line)
            lines.put(line)
        lines.put(None)

    threading.Thread(target=collect, daemon=True).start()
    output = []
    while True:
        line = lines.get(timeout=15)
        if line is None:
            raise RuntimeError("JAR 在启动完成前退出：\n" + "".join(output))
        output.append(line)
        if marker in line:
            return int(re.search(r":(\d+)\s*$", line).group(1))


def wait_for_log(captured, marker, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(marker in line for line in captured):
            return
        time.sleep(0.05)
    raise AssertionError("未收到预期日志：" + marker + "\n" + "".join(captured))


def main():
    parser = argparse.ArgumentParser(description="验证代理内核与代理服务端 JAR")
    parser.add_argument("--protocol", choices=("http2", "http3"), default="http3")
    protocol = parser.parse_args().protocol
    label = "HTTP/2" if protocol == "http2" else "HTTP/3"
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    processes = []
    server_logs, client_logs = [], []
    try:
        with tempfile.TemporaryDirectory(prefix="http3-packaged-smoke-") as temp:
            base = pathlib.Path(temp)
            cert = ROOT / "ClientG/src/test/resources/tls/localhost.crt"
            key = ROOT / "ClientG/src/test/resources/tls/localhost.key"
            server_config = base / "server.properties"
            server_config.write_text(
                f"protocols={protocol}\nbind=127.0.0.1\nport=0\npassword=smoke-only\ntls.cert={cert}\ntls.key={key}\nidleTimeoutSeconds=10\n"
            )
            udp_port = launch(ROOT / "Server/target/Server-1.0-SNAPSHOT.jar", server_config,
                              f"{label} 代理服务端已监听", processes, server_logs)
            client_config = base / "client.properties"
            client_config.write_text(
                f"protocol={protocol}\nport=0\npassword=smoke-only\nserver.host=127.0.0.1\nserver.port={udp_port}\n"
                f"tls.ca={cert}\ntls.serverName=localhost\nidleTimeoutSeconds=10\n"
            )
            proxy_port = launch(ROOT / "ClientG/target/clientG-1.0-SNAPSHOT.jar", client_config,
                                "本地 HTTP 代理已监听", processes, client_logs)
            origin_port = origin.server_port
            for tunnel in (False, True):
                connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=10)
                try:
                    if tunnel:
                        connection.set_tunnel("127.0.0.1", origin_port)
                    connection.request("GET", "/" if tunnel else f"http://127.0.0.1:{origin_port}/")
                    response = connection.getresponse()
                    assert response.status == 200, response.status
                    assert response.read() == PAYLOAD
                finally:
                    connection.close()
            # 等待真实协议连接空闲断开，验证两端连接日志，避免进程退出影响日志收集。
            for captured, peer in ((server_logs, "代理内核" if protocol == "http2" else "客户端"), (client_logs, "代理服务端" if protocol == "http2" else "服务端")):
                wait_for_log(captured, f"与{peer}的 {label} 连接成功")
                wait_for_log(captured, f"与{peer}的 {label} 连接已断开")
                assert sum(f"与{peer}的 {label} 连接成功" in line for line in captured) == 1
                assert sum(f"与{peer}的 {label} 连接已断开" in line for line in captured) == 1
            assert not any("客户端=null" in line for line in server_logs), "断开日志应保留客户端地址"
            print("JAR 冒烟测试通过：HTTP 转发、CONNECT 及两端连接成功与断开日志均正常。")
    finally:
        for process in reversed(processes):
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        origin.shutdown()
        origin.server_close()


if __name__ == "__main__":
    main()
