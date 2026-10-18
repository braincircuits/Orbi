#!/usr/bin/env python3
"""从无关工作目录启动真实便携界面，验证目录移动、证书和配置恢复。"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request

if os.name != "nt":
    raise SystemExit("此测试仅适用于 Windows")
root = Path(__file__).resolve().parent.parent
client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
windows = ctypes.WinDLL("kernel32", use_last_error=True)
windows.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
windows.OpenProcess.restype = ctypes.c_void_p
windows.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
windows.CloseHandle.argtypes = [ctypes.c_void_p]
user = ctypes.WinDLL("user32", use_last_error=True)
window_callback = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
user.EnumWindows.argtypes = [window_callback, ctypes.c_void_p]
user.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
user.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
user.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
user.GetSystemMenu.argtypes = [ctypes.c_void_p, ctypes.c_int]
user.GetSystemMenu.restype = ctypes.c_void_p
user.GetMenuState.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
user.GetMenuState.restype = ctypes.c_uint
QUIT_COMMAND = 0x1f00


def find_window(process):
    found = []
    @window_callback
    def visit(window, _):
        pid = ctypes.c_uint32()
        user.GetWindowThreadProcessId(window, ctypes.byref(pid))
        name = ctypes.create_unicode_buffer(128)
        user.GetClassNameW(window, name, len(name))
        if pid.value == process.pid and name.value == "FLUTTER_RUNNER_WIN32_WINDOW":
            found.append(window)
        return 1
    user.EnumWindows(visit, None)
    return found[0] if len(found) == 1 else None


def wait_until_ready(process, timeout=30):
    # 菜单启用状态来自界面的 locked 值；内核接口就绪不代表界面初始化已完成。
    deadline = time.monotonic() + timeout
    while True:
        if process.poll() is not None:
            raise RuntimeError("测试界面在就绪前退出")
        window = find_window(process)
        menu = user.GetSystemMenu(window, False) if window else None
        state = user.GetMenuState(menu, QUIT_COMMAND, 0) if menu else 0xffffffff
        if state != 0xffffffff and not state & 3:
            return window
        if time.monotonic() >= deadline:
            raise TimeoutError("等待测试界面就绪超时：退出菜单未启用")
        time.sleep(0.1)


def request_exit(window):
    # 调用与托盘共用的正常退出流程，强制终止会掩盖 Flutter 宿主析构时的崩溃。
    if not user.PostMessageW(window, 0x0112, QUIT_COMMAND, 0):
        raise RuntimeError("无法调用测试副本的正常退出入口")


def main(bundle):
    with tempfile.TemporaryDirectory(prefix="portable-host-", dir=root / "target") as temporary:
        base = Path(temporary)
        application = base / "原位置 程序"
        shutil.copytree(bundle.resolve(), application,
                        ignore=lambda directory, names: {"data"} if Path(directory) == bundle.resolve() else set())
        outside = base / "无关工作目录"
        outside.mkdir()
        certificate = "certs/localhost.crt"
        (application / "data/certs").mkdir(parents=True)
        shutil.copy2(root / "ClientG/src/test/resources/tls/localhost.crt", application / "data" / certificate)
        (application / "data/appearance.json").write_text('{"themeMode":"dark"}', encoding="utf-8")
        for attempt in range(2):
            assert (application / "resources/flutter/flutter_assets").is_dir()
            endpoint = application / "data/run/control.json"
            process = subprocess.Popen([str(application / "Orbi.exe")], cwd=outside)
            access = None
            revision = 0

            def api(method, path, data=None):
                nonlocal revision
                request = urllib.request.Request(access["url"] + "/api/v1" + path, method=method,
                    data=None if data is None else json.dumps(data).encode(),
                    headers={"Authorization": "Bearer " + access["token"], "Content-Type": "application/json", "If-Match": f'"{revision}"'})
                with client.open(request, timeout=10) as response:
                    result = json.load(response)
                revision = result.get("revision", revision)
                return result["data"]

            try:
                deadline = time.monotonic() + 30
                while not endpoint.exists():
                    if process.poll() is not None:
                        raise RuntimeError("便携界面在生成控制接口前退出")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("程序同级 data 中未生成控制接口，请检查资源路径与启动错误")
                    time.sleep(0.1)
                access = json.loads(endpoint.read_text(encoding="utf-8"))
                assert api("GET", "/health")["ready"]
                config = api("GET", "/config")
                if attempt == 0:
                    config["local"].update(port=0, routingMode="direct")
                    config["connections"] = [{"id": "portable", "name": "便携测试", "config": {
                        "protocol": "http2", "server.host": "127.0.0.1", "server.port": "1",
                        "password": "portable-only-test", "tls.ca": certificate}}]
                    config["defaultConnectionId"] = "portable"
                    api("PUT", "/config", config)
                else:
                    assert config["connections"][0]["name"] == "便携测试"
                    resolved = Path(config["connections"][0]["config"]["tls.ca"])
                    assert resolved.is_file() and resolved.is_relative_to(application / "data")
                assert (application / "data/kernel.db").is_file()
                assert not (outside / "kernel.db").exists()
                assert not (outside / "logc").exists()
                assert json.loads((application / "data/appearance.json").read_text())["themeMode"] == "dark"
                print(f"真实界面启动通过：第 {attempt + 1} 次，工作目录独立，data 与证书路径正确", flush=True)
            finally:
                try:
                    if process.poll() is None:
                        try:
                            window = wait_until_ready(process)
                            exit_started = time.monotonic()
                            request_exit(window)
                            process.wait(timeout=15)
                            print(f"正常退出耗时：{(time.monotonic() - exit_started) * 1000:.0f} 毫秒", flush=True)
                        except BaseException:
                            # 仅在测试失败时回收本次副本，不把强制终止算作通过。
                            if process.poll() is None:
                                process.terminate()
                                process.wait(timeout=10)
                            raise
                    if process.returncode != 0:
                        raise RuntimeError(f"测试界面异常退出：{process.returncode:#x}")
                    if endpoint.exists():
                        raise RuntimeError("界面退出后控制接口文件仍存在")
                finally:
                    if access:
                        handle = windows.OpenProcess(0x100000, 0, access["pid"])
                        if handle:
                            try:
                                if endpoint.exists():
                                    api("POST", "/kernel/shutdown")
                                if windows.WaitForSingleObject(handle, 15000) != 0:
                                    raise RuntimeError("测试内核退出超时")
                            finally:
                                windows.CloseHandle(handle)
            if attempt == 0:
                moved = base / "移动后 程序"
                application.rename(moved)
                application = moved
        print("Windows 真实便携应用验证通过：资源加载、程序同级数据、独立工作目录、移动后配置及证书恢复", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    main(parser.parse_args().bundle)
