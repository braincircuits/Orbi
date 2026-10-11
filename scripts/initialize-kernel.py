#!/usr/bin/env python3
"""通过内核管理接口初始化新的 SQLite 数据库；密码从标准输入读取。"""
import argparse
import http.client
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description="初始化内核数据库，不读取或迁移旧配置")
    parser.add_argument("--jar", required=True, type=pathlib.Path)
    parser.add_argument("--db", required=True, type=pathlib.Path)
    parser.add_argument("--ca", required=True, type=pathlib.Path)
    parser.add_argument("--username", default="")
    args = parser.parse_args()
    if args.db.exists():
        raise SystemExit("拒绝覆盖已有数据库")
    if not args.jar.is_file():
        raise SystemExit("找不到内核 JAR，请先执行 mvn -DskipTests package")
    password = input().strip()
    if not password:
        raise SystemExit("初始化密码不能为空")
    java = str(pathlib.Path(os.environ["JAVA_HOME"]) / "bin/java") if os.environ.get("JAVA_HOME") else "java"
    with tempfile.TemporaryDirectory(prefix="network-initialize-") as temporary:
        endpoint = pathlib.Path(temporary) / "control.json"
        process = subprocess.Popen([java, "--enable-native-access=ALL-UNNAMED", "-jar", str(args.jar.resolve()),
            "--web", "--db", str(args.db.resolve()), "--port", "0", "--endpoint-file", str(endpoint)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=temporary)
        output = []
        reader = threading.Thread(target=lambda: output.extend(process.stdout), daemon=True)
        reader.start()
        try:
            deadline = time.monotonic() + 20
            while not endpoint.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("内核初始化启动失败：" + "".join(output).replace(password, "***"))
                time.sleep(0.05)
            access = json.loads(endpoint.read_text())
            profile = {"protocol": "http3", "server.host": "127.0.0.1", "server.port": 4433,
                       "password": password, "tls.ca": os.path.relpath(args.ca.resolve(), args.db.resolve().parent),
                       "tls.serverName": "localhost"}
            if args.username:
                profile["username"] = args.username
            connection = http.client.HTTPConnection(access["url"].removeprefix("http://"), timeout=15)
            try:
                connection.request("PUT", "/api/v1/config", json.dumps({"version": 1,
                    "local": {"bind": "127.0.0.1", "port": 8080}, "defaultConnectionId": "default",
                    "connections": [{"id": "default", "name": "默认连接", "config": profile}]}),
                    {"Authorization": "Bearer " + access["token"], "Content-Type": "application/json", "If-Match": "0"})
                response = connection.getresponse()
                body = response.read().decode()
                if response.status != 200:
                    raise RuntimeError("初始化配置失败：" + body.replace(password, "***"))
            finally:
                connection.close()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            reader.join(timeout=2)
            process.stdout.close()
    print("内核数据库已初始化：" + str(args.db))


if __name__ == "__main__":
    main()
