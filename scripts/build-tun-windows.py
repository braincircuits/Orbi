#!/usr/bin/env python3
"""在 Windows 上构建并测试双组件 TUN，只修改独立的依赖副本。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
mode = sys.argv[1] if len(sys.argv) > 1 else "build"
if mode not in ("build", "--test", "--build-test-binary"):
    raise SystemExit("Windows 支持 build、--test 和 --build-test-binary")
go = os.environ.get("GO", "go")
env = dict(os.environ, CGO_ENABLED="1")
if env.get("CC") and Path(env["CC"]).is_file():
    configured = env["CC"]
    env["CC"] = f'"{configured}"'
    if Path(configured).name.lower() in ("zig", "zig.exe"):
        env["CC"] += ' cc -target x86_64-windows-gnu'
if not env.get("CC"):
    zig = shutil.which("zig")
    compiler = shutil.which("gcc") or shutil.which("clang")
    if compiler:
        env["CC"] = f'"{compiler}"'
    elif zig:
        env["CC"] = f'"{zig}" cc -target x86_64-windows-gnu'
    else:
        raise SystemExit("请设置 CC，或将 Zig、GCC、Clang 加入 PATH，以构建 Outline SDK")

def run(*args, **kwargs):
    return subprocess.run(args, cwd=root / "TunBridge", env=env, check=True, **kwargs)

target = root / "target"
target.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="tun-build-", dir=target) as directory:
    work = Path(directory)
    run(go, "mod", "download", "github.com/eycorsican/go-tun2socks")
    dependency = json.loads(run(go, "list", "-m", "-json", "github.com/eycorsican/go-tun2socks", capture_output=True, text=True, encoding="utf-8").stdout)
    if dependency["Version"] != "v1.16.11":
        raise SystemExit("TUN 依赖版本已变化，必须先复核补丁")
    copied = work / "go-tun2socks"
    shutil.copytree(dependency["Dir"], copied)
    for file in copied.rglob("*"):
        if file.is_file():
            file.chmod(0o600)
            if file.suffix in (".go", ".c", ".h"):
                file.write_bytes(file.read_bytes().replace(b"\r\n", b"\n"))
    patch = shutil.which("patch")
    if not patch:
        raise SystemExit("未找到 patch，请将 Git for Windows 的 usr/bin 加入 PATH")
    source = (root / "TunBridge/patches/go-tun2socks-v1.16.11.patch").read_bytes().replace(b"\r\n", b"\n")
    run(patch, "--binary", "--batch", "--fuzz=0", "-p1", "-d", str(copied), input=source)
    modfile = work / "tun.mod"
    shutil.copy2(root / "TunBridge/go.mod", modfile)
    shutil.copy2(root / "TunBridge/go.sum", work / "tun.sum")
    run(go, "mod", "edit", f"-modfile={modfile}", f"-replace=github.com/eycorsican/go-tun2socks={copied.as_posix()}")
    options = (f"-modfile={modfile}", "-mod=readonly")
    if mode == "--test":
        print("正在测试 Windows TUN 双组件…", flush=True)
        run(go, "test", *options, "-timeout", "120s", "./...")
    elif mode == "--build-test-binary":
        run(go, "test", *options, "-c", "-o", str(target / "tun.test.exe"), ".")
    else:
        print("正在构建 Windows TUN 双组件…", flush=True)
        run(go, "build", *options, "-trimpath", "-o", str(target / "network-tun.exe"), ".")
        print(f"辅助程序已生成：{target / 'network-tun.exe'}")
