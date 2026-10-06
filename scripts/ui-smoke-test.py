#!/usr/bin/env python3
"""通过 UI 控制协议验证真实 HTTP/3 转发、认证失败和退出清理。"""
import http.client
import http.server
import json
import os
import pathlib
import queue
import socket
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
JAVA = os.environ.get("UI_TEST_JAVA", "java")
JAR = os.environ.get("UI_TEST_JAR", str(ROOT / "ClientG/target/clientG-1.0-SNAPSHOT.jar"))


def main():
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), smoke.Origin)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    processes = []
    try:
        with tempfile.TemporaryDirectory(prefix="network-ui-smoke-") as temporary:
            base = pathlib.Path(temporary)
            cert = ROOT / "ClientG/src/test/resources/tls/localhost.crt"
            config = base / "server.properties"
            config.write_text(f"bind=127.0.0.1\nport=0\npassword=ui-test-secret\ntls.cert={cert}\ntls.key={cert.with_suffix('.key')}\n")
            server_port = smoke.launch(ROOT / "Server/target/Server-1.0-SNAPSHOT.jar", config, "HTTP/3 代理服务端已监听", processes)
            client = subprocess.Popen([JAVA, "--enable-native-access=ALL-UNNAMED", "-Dlog4j.configurationFile=log4j2-ui.xml", "-jar", JAR, "--ui"],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=base)
            processes.append(client)
            events = queue.Queue()
            diagnostics = []
            threading.Thread(target=lambda: [events.put(json.loads(line)) for line in client.stdout], daemon=True).start()
            threading.Thread(target=lambda: [diagnostics.append(line) for line in client.stderr], daemon=True).start()
            assert events.get(timeout=15)["event"] == "ready"
            sequence = 0

            def command(name, **data):
                nonlocal sequence
                sequence += 1
                request_id = str(sequence)
                client.stdin.write(json.dumps({"id": request_id, "command": name, **data}) + "\n")
                client.stdin.flush()
                while True:
                    event = events.get(timeout=20)
                    if event.get("id") == request_id:
                        assert event["ok"], event
                        return event.get("status")

            with socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                port = reserved.getsockname()[1]
            values = {"server.host": "127.0.0.1", "server.port": str(server_port),
                      "password": "ui-test-secret", "tls.ca": str(cert), "tls.serverName": "localhost"}
            def start(rules=""):
                return command("start", configuration={"version": 1, "local": {"port": port, "routesInline": rules},
                    "defaultConnectionId": "test", "connections": [{"id": "test", "name": "测试", "config": values}]})
            state = start()
            assert state["running"] and state["connection"] == "idle"

            def request(tunnel=False, expected=200):
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                try:
                    if tunnel:
                        connection.set_tunnel("127.0.0.1", origin.server_port)
                    connection.request("GET", "/" if tunnel else f"http://127.0.0.1:{origin.server_port}/")
                    response = connection.getresponse()
                    assert response.status == expected, response.status
                    payload = response.read()
                    if expected == 200:
                        assert payload == smoke.PAYLOAD
                finally:
                    connection.close()

            request()
            request(tunnel=True)
            assert command("status")["connection"] == "connected"
            command("stop")
            values["password"] = "incorrect-test-password"
            start()
            request(expected=502)
            assert "验证失败" in command("status")["error"]
            command("stop")
            # 错误密码下仍能访问命中直连规则的本地目标。
            start("127.0.0.1")
            request()
            assert command("status")["connection"] == "idle"
            client.stdin.close()
            assert client.wait(timeout=10) == 0
            with socket.socket() as check:
                assert check.connect_ex(("127.0.0.1", port)) != 0
            assert not any("ui-test-secret" in line or "incorrect-test-password" in line for line in diagnostics)
            print("UI 控制联调通过：HTTP、CONNECT、真实状态、认证失败、直连规则及退出资源清理。")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
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
