#!/usr/bin/env python3
"""通过真实内核验证 Web 控制、HTTP/2 与 HTTP/3 转发、热更新和退出。"""
import http.client
import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time
from importlib.util import spec_from_file_location, module_from_spec

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = spec_from_file_location("smoke", ROOT / "scripts/smoke-test.py")
smoke = module_from_spec(spec)
spec.loader.exec_module(smoke)


def main():
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), smoke.Origin)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    processes = []
    try:
        with tempfile.TemporaryDirectory(prefix="network-web-smoke-") as temporary:
            base = pathlib.Path(temporary)
            cert = ROOT / "ClientG/src/test/resources/tls/localhost.crt"
            profile_ports = {}
            for protocol in ("http2", "http3"):
                settings = base / (protocol + ".properties")
                settings.write_text(f"bind=127.0.0.1\nport=0\nprotocols={protocol}\npassword=web-test-secret\ntls.cert={cert}\ntls.key={cert.with_suffix('.key')}\n")
                profile_ports[protocol] = smoke.launch(ROOT / "Server/target/Server-1.0-SNAPSHOT.jar", settings,
                    "HTTP/2 代理服务端已监听" if protocol == "http2" else "HTTP/3 代理服务端已监听", processes)
            endpoint = base / "control.json"
            native = os.environ.get("NATIVE_CORE")
            command = [native] if native else [os.environ.get("UI_TEST_JAVA", "java"), "--enable-native-access=ALL-UNNAMED",
                "-jar", str(ROOT / "ClientG/target/clientG-1.0-SNAPSHOT.jar")]
            process = subprocess.Popen([*command, "--web", "--config", str(base / "kernel.json"),
                "--port", "0", "--endpoint-file", str(endpoint)], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=base)
            processes.append(process)
            diagnostics = []
            threading.Thread(target=lambda: diagnostics.extend(process.stdout), daemon=True).start()
            deadline = time.monotonic() + 15
            while not endpoint.exists():
                assert process.poll() is None, "代理内核启动失败：" + "".join(diagnostics)
                assert time.monotonic() < deadline, "管理接口启动超时"
                time.sleep(0.05)
            access = json.loads(endpoint.read_text())
            address = access["url"].removeprefix("http://")
            revision = 0

            def api(method, path, data=None, expected=200):
                nonlocal revision
                connection = http.client.HTTPConnection(address, timeout=10)
                try:
                    connection.request(method, "/api/v1" + path, None if data is None else json.dumps(data),
                        {"Authorization": "Bearer " + access["token"], "Content-Type": "application/json", "If-Match": str(revision)})
                    response = connection.getresponse()
                    body = response.read().decode()
                    assert response.status == expected, (response.status, body)
                    assert "web-test-secret" not in body
                    result = json.loads(body)
                    revision = result.get("revision", revision)
                    return result["data"]
                finally:
                    connection.close()

            assert api("GET", "/health")["ready"]
            for protocol, port in profile_ports.items():
                api("POST", "/profiles", {"id": protocol, "name": protocol, "config": {"protocol": protocol,
                    "server.host": "127.0.0.1", "server.port": port, "password": "web-test-secret",
                    "tls.ca": str(cert), "tls.serverName": "localhost"}}, 201)
            api("PATCH", "/settings", {"port": 0, "routesInline": ""})
            state = api("POST", "/proxy/start")
            proxy_port = int(state["address"].rsplit(":", 1)[1])

            def request(tunnel=False):
                connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=10)
                try:
                    if tunnel:
                        connection.set_tunnel("127.0.0.1", origin.server_port)
                    connection.request("GET", "/" if tunnel else f"http://127.0.0.1:{origin.server_port}/")
                    response = connection.getresponse()
                    assert response.status == 200
                    assert response.read() == smoke.PAYLOAD
                finally:
                    connection.close()

            for protocol in ("http2", "http3"):
                api("PUT", "/routing/default", {"profileId": protocol})
                request()
                request(tunnel=True)
                assert api("GET", "/status")["connection"] == "connected"
                job = api("POST", f"/profiles/{protocol}/tests", {"target": f"127.0.0.1:{origin.server_port}"}, 202)
                deadline = time.monotonic() + 15
                while job["state"] not in ("succeeded", "failed", "cancelled"):
                    assert time.monotonic() < deadline, "连接诊断超时"
                    time.sleep(0.05)
                    job = api("GET", "/operations/" + job["id"])
                assert job["state"] == "succeeded", job
            api("PUT", "/routing/direct-rules", {"rules": "127.0.0.0/8"})
            api("PATCH", "/profiles/http3", {"config": {"password": "incorrect-password"}})
            request(tunnel=True)
            api("POST", "/config/save")
            assert json.loads((base / "kernel.json").read_text())["local"]["routesInline"] == "127.0.0.0/8"
            api("POST", "/proxy/stop")
            assert api("GET", "/health")["ready"]
            api("POST", "/kernel/shutdown")
            assert process.wait(timeout=10) == 0
            assert not endpoint.exists()
            assert not any(access["token"] in line or "web-test-secret" in line for line in diagnostics)
            print("Web 联调通过：" + ("AOT 原生内核" if native else "JAR 内核") + "、HTTP/2、HTTP/3、HTTP/CONNECT、异步诊断、热更新、配置保存及退出清理。")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        origin.shutdown()
        origin.server_close()


if __name__ == "__main__":
    main()
