"""验证构建配置解析、环境变量优先级以及子进程继承。"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


LOADER = Path(__file__).resolve().parents[1] / "build-tools.sh"


class BuildToolsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "build.local.properties"
        self.env = {key: value for key, value in os.environ.items()
                    if key not in {"JDK_HOME", "JAVA_HOME", "MVN", "GO", "FLUTTER", "GRAALVM_HOME"}}

    def load(self, text=None, env=None):
        if text is not None:
            self.config.write_bytes(text.encode())
        # 用独立子进程读取结果，验证父入口选定的路径确实被导出。
        script = '''set -eu
. "$1"
load_build_tools "$2"
sh -c 'printf "%s\\n" "$JDK_HOME" "${JAVA_HOME:-}" "$MVN" "$GO" "$FLUTTER" "$GRAALVM_HOME"'
'''
        return subprocess.run(["sh", "-c", script, "构建配置测试", str(LOADER), str(self.root)],
                              cwd="/", env=self.env if env is None else env,
                              capture_output=True, text=True, timeout=5)

    def test_missing_config_uses_defaults(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["", "", "mvn", "go", "flutter", ""])

    def test_paths_crlf_and_child_environment(self):
        result = self.load("  # 注释\r\njava.home = tools/JDK 25 \r\nmaven.bin=~/maven/bin/mvn\r\n"
                           "go.bin=/工具/go/bin/go\r\nflutter.bin=tools/flutter/bin/flutter\r\ngraalvm.home=")
        self.assertEqual(result.returncode, 0, result.stderr)
        jdk = str(self.root / "tools/JDK 25")
        self.assertEqual(result.stdout.splitlines(), [jdk, jdk, str(Path.home() / "maven/bin/mvn"),
                         "/工具/go/bin/go", str(self.root / "tools/flutter/bin/flutter"), jdk])

    def test_environment_overrides_config(self):
        env = dict(self.env, JDK_HOME="/环境/jdk", JAVA_HOME="/次选/jdk", MVN="custom-mvn",
                   GO="custom-go", FLUTTER="custom-flutter", GRAALVM_HOME="/环境/graal")
        result = self.load("java.home=/配置/jdk\nmaven.bin=/配置/mvn\ngo.bin=/配置/go\n"
                           "flutter.bin=/配置/flutter\ngraalvm.home=/配置/graal", env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["/环境/jdk", "/环境/jdk", "custom-mvn",
                                                     "custom-go", "custom-flutter", "/环境/graal"])

    def test_java_home_environment_overrides_config(self):
        result = self.load("java.home=/配置/jdk", dict(self.env, JAVA_HOME="/环境/java"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:2], ["/环境/java", "/环境/java"])

    def test_invalid_config_is_rejected(self):
        for text in ("go.bin=/one\ngo.bin=/two", "unknown=value", "缺少等号"):
            with self.subTest(text=text):
                result = self.load(text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("构建配置错误", result.stderr)

    def test_values_are_not_executed(self):
        marker = self.root / "不应创建"
        value = f"/工具/$(touch {marker})=bin # 原文"
        result = self.load(f"go.bin={value}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[3], value)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
