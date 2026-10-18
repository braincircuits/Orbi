"""使用已安装的 MSVC 编译 Windows 出口绑定 JNI，不执行 AOT 编译。"""
import os
from pathlib import Path
import subprocess
import shutil
import sys


def msvc_environment():
    locator = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
    root = subprocess.check_output([str(locator), "-latest", "-products", "*", "-requires",
                                    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
                                   text=True, encoding="utf-8").strip()
    if not root:
        raise RuntimeError("未找到 Visual Studio C++ 构建工具")
    initializer = Path(root) / "VC/Auxiliary/Build/vcvars64.bat"
    output = subprocess.check_output(f'call "{initializer}" >nul && set', shell=True,
                                     text=True, encoding="utf-8", errors="replace")
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line and not line.startswith("="))


def build(java_home, destination):
    root = Path(__file__).resolve().parents[1]
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    source = root / "ProxyCommon/src/main/native/windows_network.cpp"
    library = destination / "orbi-network.dll"
    if library.exists() and library.stat().st_mtime >= source.stat().st_mtime:
        return
    command = ["cl.exe", "/nologo", "/utf-8", "/LD", "/EHsc", "/O2", "/MT",
               "/I" + str(Path(java_home) / "include"), "/I" + str(Path(java_home) / "include/win32"),
               str(source), "/Fe:" + str(library), "/link", "Ws2_32.lib"]
    environment = msvc_environment()
    compiler = shutil.which("cl.exe", path=environment.get("Path", environment.get("PATH")))
    if not compiler: raise RuntimeError("未找到 MSVC 编译器")
    command[0] = compiler
    subprocess.run(command, env=environment, cwd=destination, check=True)
    print("Windows 出口绑定库已生成：" + str(library))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])
