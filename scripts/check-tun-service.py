#!/usr/bin/env python3
"""验证已安装的系统辅助服务可重复使用；在启动标识校验处取消，不创建虚拟网卡或修改路由。"""
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import secrets
import stat
import subprocess
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser(description="验证系统辅助服务的权限及无重复提权启动")
    parser.add_argument("helper", type=pathlib.Path, help="应用包中的 network-tun 路径")
    helper = parser.parse_args().helper.resolve()
    installed = pathlib.Path("/Library/PrivilegedHelperTools/com.blacicada.network-tun/network-tun")
    for path in [installed, pathlib.Path("/Library/LaunchDaemons/com.blacicada.network-tun.plist")]:
        info = path.stat()
        assert info.st_uid == 0 and stat.S_IMODE(info.st_mode) & 0o022 == 0, "系统文件权限不正确"
    with helper.open("rb") as source, installed.open("rb") as target:
        assert hashlib.file_digest(source, "sha256").digest() == hashlib.file_digest(target, "sha256").digest(), "已安装辅助程序与应用版本不一致"
    requests = []

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            requests.append(self.path)
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            data = json.dumps({"error": {"message": "验证用启动标识已撤销"}}, ensure_ascii=False).encode()
            self.send_response(409)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Endpoint)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="network-service-check-") as directory:
            endpoint = pathlib.Path(directory) / "control.json"
            endpoint.write_text(json.dumps({"apiVersion": 1, "url": f"http://127.0.0.1:{server.server_port}", "token": secrets.token_hex(32)}))
            endpoint.chmod(0o600)
            for index in range(2):
                status = subprocess.run([str(helper), "--service-status"], capture_output=True, text=True, timeout=8)
                assert status.returncode == 0, status.stderr
                result = subprocess.run([str(helper), "--client", "--control-file", str(endpoint), "--ticket", "0" * 36,
                                         "--owner-pid", str(os.getpid())], capture_output=True, text=True, timeout=15)
                assert result.returncode != 0 and "HTTP 409" in result.stderr, result.stderr
                print(f"第 {index + 1} 次无提权启动通过：系统服务运行会话进程，并在失效启动标识处停止。")
            assert requests == ["/api/v1/tun/prepare"] * 2, "验证流程不应执行路由接管"
            print("系统文件权限、组件一致性及重复使用均验证通过；未创建虚拟网卡或修改路由。")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
