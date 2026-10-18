#!/usr/bin/env python3
"""生成可独立运行的 Windows x64 应用包，保留已有发布目录与用户数据。"""
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
if sys.argv[1:] not in ([], ["--native"]) or os.name != "nt":
    raise SystemExit("用法：在 Windows 运行 sh scripts/package-windows.sh [--native]")
native = sys.argv[1:] == ["--native"]
stamp = datetime.now(timezone(timedelta(hours=8))).strftime("%Y%m%d-%H%M%S")
destination = root / "release/ui" / f"Orbi-{stamp}"
if destination.exists():
    raise SystemExit(f"产物已存在，停止打包：{destination}")
jdk = Path(os.environ.get("JDK_HOME") or os.environ.get("JAVA_HOME", ""))
wintun = Path(os.environ.get("WINTUN_HOME", ""))
driver = wintun / "bin/amd64/wintun.dll"
if not (jdk / "bin/jlink.exe").is_file() or not driver.is_file() or not (wintun / "LICENSE.txt").is_file():
    raise SystemExit("请在 build.local.properties 配置 Java 25 和官方 Wintun 解压目录")

def run(*args, cwd=root):
    # Windows 的 mvn/flutter 是批处理入口，使用 cmd 并保持参数边界。
    if str(args[0]).lower().endswith((".bat", ".cmd")):
        args = (os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", subprocess.list2cmdline(args))
    subprocess.run(args, cwd=cwd, check=True)

def tool(name, default):
    value = os.environ.get(name) or shutil.which(default)
    if not value:
        raise SystemExit(f"找不到构建工具：{default}")
    # 配置沿用 macOS 的无后缀路径时，明确选择 Windows 的批处理入口。
    if Path(str(value) + ".bat").exists():
        value += ".bat"
    elif Path(str(value) + ".cmd").exists():
        value += ".cmd"
    return value

print("正在校验官方 Wintun 数字签名…", flush=True)
driver_env = dict(os.environ, ORBI_WINTUN_DLL=str(driver))
system = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0"
driver_env["PSModulePath"] = str(system / "Modules")
subprocess.run([str(system / "powershell.exe"), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                "$s=Get-AuthenticodeSignature -LiteralPath $env:ORBI_WINTUN_DLL;if($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notlike '*WireGuard*'){throw 'Wintun 数字签名无效'}"], env=driver_env, check=True)
if native:
    run("sh", "scripts/build-native.sh")
else:
    run(tool("MVN", "mvn.cmd"), "-B", "-ntp", "-DskipTests", "package")
run("sh", "scripts/build-tun.sh")
run(tool("FLUTTER", "flutter.bat"), "build", "windows", "--release", cwd=root / "ui")
source = root / "ui/build/windows/x64/runner/Release"
# 忽略构建目录遗留的旧 Flutter data；新包只从 resources/flutter 读取静态资源。
shutil.copytree(source, destination, ignore=lambda directory, names: {"data"} if Path(directory) == source else set())
(destination / "data").mkdir()
proxy = destination / "proxy"
proxy.mkdir()
if native:
    native_directory = root / "ClientG/target/native"
    shutil.copy2(native_directory / "network-core.exe", proxy / "network-core.exe")
    for library in native_directory.glob("*.dll"):
        shutil.copy2(library, proxy / library.name)
else:
    shutil.copy2(root / "ClientG/target/clientG-1.0-SNAPSHOT.jar", proxy / "client.jar")
shutil.copy2(root / "target/network-tun.exe", proxy / "network-tun.exe")
shutil.copy2(driver, proxy / "wintun.dll")
shutil.copy2(wintun / "LICENSE.txt", proxy / "Wintun-LICENSE.txt")
if not native:
    run(str(jdk / "bin/jlink.exe"), "--add-modules", "java.se,jdk.httpserver,jdk.jfr,jdk.unsupported,jdk.crypto.ec,jdk.naming.dns",
        "--strip-debug", "--no-header-files", "--no-man-pages", "--output", str(proxy / "runtime"))
# Flutter 的动态 C++ 运行库随应用分发，无需另一台电脑预先安装 Visual Studio。
vswhere = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
vsroot = Path(subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-property", "installationPath"], text=True).strip())
runtimes = sorted((vsroot / "VC/Redist/MSVC").glob("*/x64/Microsoft.VC*.CRT"))
if not runtimes:
    raise SystemExit("找不到 Visual C++ 可分发运行库")
for library in runtimes[-1].glob("*.dll"):
    shutil.copy2(library, destination / library.name)
for module, jar in (("client", "ClientG/target/clientG-1.0-SNAPSHOT.jar"), ("server", "Server/target/Server-1.0-SNAPSHOT.jar")):
    directory = root / "release" / module
    directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / jar, directory / f"{module}.jar")
kernel_description = "AOT 原生客户端内核（无需 Java）" if native else "Java 25 与客户端内核"
(destination / "使用说明.txt").write_text("启动 Orbi.exe。开启 TUN 时需要在 Windows 授权窗口选择“是”。\n关闭主窗口后保留托盘，托盘菜单“退出 Orbi”会停止内核并清理 TUN。\n配置、数据库、证书和日志保存在 Orbi.exe 同级的 data 文件夹中。\n移动时携带整个程序文件夹；升级时保留 data，程序文件夹需要可写。\nWindows 不再自动读取 AppData 中的旧数据；现有配置需显式迁移。\n" + f"应用包已内置{kernel_description}、双组件 TUN 与官方签名 Wintun。\n", encoding="utf-8")
print(f"Windows 应用已生成：{destination / 'Orbi.exe'}")
print(f"所在目录：{destination.parent}")
