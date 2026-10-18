#!/usr/bin/env python3
"""使用 GraalVM 与 MSVC 将 Windows 客户端内核编译为独立程序。"""
import os
from pathlib import Path
import subprocess
import sys

from importlib.util import module_from_spec, spec_from_file_location

root = Path(__file__).resolve().parent.parent
spec = spec_from_file_location("windows_network", root / "scripts/build-windows-network.py")
network = module_from_spec(spec)
spec.loader.exec_module(network)

if os.name != "nt" or len(sys.argv) > 2:
    raise SystemExit("用法：在 Windows 运行 sh scripts/build-native.sh [输出路径]")
graal = Path(os.environ.get("GRAALVM_HOME", ""))
compiler = graal / "bin/native-image.cmd"
if not compiler.is_file():
    raise SystemExit("请在 build.local.properties 的 graalvm.home 配置包含 native-image 的 GraalVM 25")
output = Path(sys.argv[1] if len(sys.argv) == 2 else root / "ClientG/target/native/network-core.exe").resolve()
output.parent.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ)
environment.update(network.msvc_environment())
environment["JAVA_HOME"] = str(graal)
environment["PATH"] = str(graal / "bin") + os.pathsep + environment.get("Path", environment.get("PATH", ""))

def batch(program, *arguments):
    subprocess.run([os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c",
                    subprocess.list2cmdline([str(program), *map(str, arguments)])],
                   cwd=root, env=environment, check=True)

maven = os.environ.get("MVN", "mvn.cmd")
if Path(maven + ".cmd").is_file():
    maven += ".cmd"
print("正在构建代理内核 JAR…", flush=True)
batch(maven, "-B", "-ntp", *(["-o"] if os.environ.get("MAVEN_OFFLINE") == "1" else []), "-DskipTests", "package")
print("正在使用 GraalVM 编译 Windows 原生代理内核…", flush=True)
batch(compiler, "-J-Xmx6g", "--parallelism=6", "--no-fallback", "-march=compatibility",
      "--enable-native-access=ALL-UNNAMED",
      "--initialize-at-run-time=io.netty,org.apache.logging.log4j,com.lmax.disruptor,com.blacicada.common.WindowsSocketBinding",
      "-jar", root / "ClientG/target/clientG-1.0-SNAPSHOT.jar", "-o", output)
print(f"原生代理内核已生成：{output}", flush=True)
print(f"所在目录：{output.parent}", flush=True)
