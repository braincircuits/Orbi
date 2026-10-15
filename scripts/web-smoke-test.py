#!/usr/bin/env python3
"""通过真实内核验证 Web 控制、HTTP/2 与 HTTP/3 转发、热更新和退出。"""
import http.client
import http.server
import json
import os
import pathlib
import subprocess
import sys
import sqlite3
import shutil
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
            program_directory = base / "程序目录"
            program_directory.mkdir()
            executable = pathlib.Path(native) if native else ROOT / "ClientG/target/clientG-1.0-SNAPSHOT.jar"
            copied = program_directory / executable.name
            shutil.copy2(executable, copied)
            if native:
                for pattern in ("*.dylib", "*.so", "*.dll"):
                    for library in executable.parent.glob(pattern):
                        shutil.copy2(library, program_directory / library.name)
            command = [str(copied)] if native else [os.environ.get("UI_TEST_JAVA", "java"), "--enable-native-access=ALL-UNNAMED", "-jar", str(copied)]
            arguments = [*command, "--web", "--port", "0", "--endpoint-file", str(endpoint)]
            diagnostics = []

            def launch_kernel():
                process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=base)
                processes.append(process)
                threading.Thread(target=lambda: diagnostics.extend(process.stdout), daemon=True).start()
                deadline = time.monotonic() + 15
                while not endpoint.exists():
                    assert process.poll() is None, "代理内核启动失败：" + "".join(diagnostics)
                    assert time.monotonic() < deadline, "管理接口启动超时"
                    time.sleep(0.05)
                return process, json.loads(endpoint.read_text())

            process, access = launch_kernel()
            database_file = program_directory / "kernel.db"
            assert database_file.is_file(), "数据库必须位于程序同目录"
            assert not (base / "kernel.db").exists(), "数据库不应创建在启动工作目录"
            duplicate = subprocess.run(arguments, cwd=base, capture_output=True, text=True, timeout=15)
            assert duplicate.returncode != 0 and "数据库已被其他内核实例占用" in duplicate.stdout + duplicate.stderr
            assert json.loads(endpoint.read_text()) == access, "第二个实例不得覆盖管理发现文件"
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
            exported = api("GET", "/routing/export")
            api("PUT", "/routing/direct-rules", {"rules": ""})
            api("POST", "/routing/import", {"document": exported, "strategy": "replace"})
            assert api("GET", "/routing/export") == exported
            with sqlite3.connect(database_file) as database:
                assert database.execute("SELECT direct_rules FROM routing").fetchone()[0] == "127.0.0.0/8"
                assert database.execute("SELECT revision FROM metadata").fetchone()[0] == revision
            api("POST", "/proxy/stop")
            assert api("GET", "/health")["ready"]
            api("POST", "/kernel/shutdown")
            assert process.wait(timeout=10) == 0
            assert not endpoint.exists()
            saved_revision = revision
            process, access = launch_kernel()
            address = access["url"].removeprefix("http://")
            state = api("GET", "/status")
            assert revision == saved_revision and not state["running"], "重启必须恢复配置版本并保持转发停止"
            assert api("GET", "/routing/export") == exported
            assert len(api("GET", "/profiles")) == 2
            api("POST", "/kernel/shutdown")
            assert process.wait(timeout=10) == 0
            assert not endpoint.exists()
            assert not any(access["token"] in line or "web-test-secret" in line for line in diagnostics)
            print("Web 联调通过：" + ("AOT 原生内核" if native else "JAR 内核") + "、HTTP/2、HTTP/3、HTTP/CONNECT、异步诊断、热更新、SQLite 自动保存、程序同目录默认路径、独占运行、重启恢复、路由导入导出及退出清理。")
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
