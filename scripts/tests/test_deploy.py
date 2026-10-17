"""用本地 SSH 替身验证部署流程，不连接真实服务器。"""

import fcntl
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import termios
import unittest


PROJECT_DIR = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_DIR / "scripts/deploy.sh"


class DeployTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # 执行真实生成的远程 Bash，只把网络传输替换为本地管道。
        ssh = self.bin / "ssh"
        ssh.write_text(f"#!{sys.executable}\n" + '''import json
import os
import subprocess
import sys
import termios
from pathlib import Path
Path(os.environ["SSH_CALLED"]).write_text(json.dumps(sys.argv[1:]))
if "PreferredAuthentications=password" in sys.argv:
    assert "BatchMode=no" in sys.argv
    assert "PasswordAuthentication=yes" in sys.argv
    assert "PubkeyAuthentication=no" in sys.argv
    assert "KbdInteractiveAuthentication=no" in sys.argv
    assert "ControlPath=none" in sys.argv
    assert os.environ["SSH_ASKPASS_REQUIRE"] == "never"
    # 模拟 OpenSSH 从控制终端读取密码，标准输入留给上传文件。
    with open("/dev/tty", "r+b", buffering=0) as tty:
        original = termios.tcgetattr(tty)
        hidden = original.copy()
        hidden[3] &= ~termios.ECHO
        termios.tcsetattr(tty, termios.TCSANOW, hidden)
        try:
            tty.write("测试密码：".encode())
            password = tty.readline().strip()
        finally:
            termios.tcsetattr(tty, termios.TCSANOW, original)
        if password != b"test-only-password":
            sys.exit(255)
mode = os.environ.get("SSH_TEST_MODE", "")
if mode == "连接失败":
    sys.exit(255)
data = sys.stdin.buffer.read()
if mode == "上传损坏":
    data = data[:3]
sys.exit(subprocess.run(sys.argv[-1], shell=True, input=data).returncode)
''', encoding="utf-8")
        ssh.chmod(0o755)
        # macOS 没有 GNU mv -T；测试替身保持文件替换语义，生产脚本仍要求 Linux。
        mv = self.bin / "mv"
        mv.write_text(f"#!{sys.executable}\n" + '''import os
import sys
os.replace(sys.argv[-2], sys.argv[-1])
''', encoding="utf-8")
        mv.chmod(0o755)
        self.source = self.root / "本地 '文件.jar"
        self.source.write_bytes(bytes(range(256)) * 4096)
        self.remote = self.root / "远程 '目录 $(不是命令)"
        self.remote.mkdir()
        self.target = self.remote / "server.jar"
        self.target.write_bytes(b"original")
        self.config = {
            "ssh.host": "test-server", "ssh.user": "deploy", "ssh.port": 2222,
            "local.file": str(self.source), "remote.dir": str(self.remote),
            "remote.name": "server.jar",
            "command.1": "printf '完成' > result",
        }
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SSH_CALLED=str(self.root / "ssh-called"))

    def run_deploy(self, *args, config_text=None, tty_password=None):
        config_path = self.root / "配置.properties"
        if config_text is None:
            config_text = "\n".join(f"{key}={value}" for key, value in self.config.items()) + "\n"
        config_path.write_bytes(config_text.encode("utf-8"))
        command = ["bash", str(SCRIPT), "--config", str(config_path), *args]
        if tty_password is None:
            return subprocess.run(command, env=self.env, cwd=self.root, capture_output=True,
                                  text=True, start_new_session=True, timeout=15)
        master, slave = pty.openpty()
        try:
            def attach_terminal():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            process = subprocess.Popen(command, env=self.env, cwd=self.root, stdin=slave,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, preexec_fn=attach_terminal)
            try:
                self.assertTrue(select.select([master], [], [], 10)[0], "未出现终端密码提示")
                prompt = os.read(master, 4096).decode()
                self.assertIn("测试密码：", prompt)
                os.write(master, (tty_password + "\n").encode())
                stdout, stderr = process.communicate(timeout=15)
                self.assertNotIn(tty_password, stdout + stderr + prompt)
                return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()
        finally:
            os.close(master)
            os.close(slave)

    def test_upload_and_commands_share_context(self):
        self.config["command.1"] = "value='上下文'; mkdir sub; cd sub"
        self.config["command.2"] = "printf '%s' \"$value\" > result"
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_bytes(), self.source.read_bytes())
        self.assertEqual((self.remote / "sub/result").read_text(), "上下文")
        self.assertFalse(list(self.remote.glob(".deploy-upload.*")))

    def test_failed_command_stops_later_commands(self):
        self.config.update({"command.1": "printf '先执行' > first", "command.2": "false",
                            "command.3": "touch should-not-exist"})
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.remote / "first").exists())
        self.assertFalse((self.remote / "should-not-exist").exists())
        self.assertIn("第 2/3 条命令", result.stderr)
        self.assertEqual(self.target.read_bytes(), self.source.read_bytes())

    def test_failed_pipeline_stops_later_commands(self):
        self.config.update({"command.1": "false | cat", "command.2": "touch should-not-exist"})
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("第 1/2 条命令", result.stderr)
        self.assertFalse((self.remote / "should-not-exist").exists())

    def test_target_directory_is_not_overwritten(self):
        self.target.unlink()
        self.target.mkdir()
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("目标文件名已被目录占用", result.stderr)
        self.assertFalse(list(self.target.iterdir()))
        self.assertFalse((self.remote / "result").exists())

    def test_missing_remote_directory_is_created(self):
        self.remote = self.root / "新目录"
        self.config["remote.dir"] = str(self.remote)
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.remote / "server.jar").read_bytes(), self.source.read_bytes())

    def test_damaged_upload_preserves_original_and_skips_commands(self):
        self.env["SSH_TEST_MODE"] = "上传损坏"
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("校验上传文件", result.stderr)
        self.assertEqual(self.target.read_bytes(), b"original")
        self.assertFalse((self.remote / "result").exists())
        self.assertFalse(list(self.remote.glob(".deploy-upload.*")))

    def test_connection_failure_stops_deployment(self):
        self.env["SSH_TEST_MODE"] = "连接失败"
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("255", result.stderr)
        self.assertEqual(self.target.read_bytes(), b"original")
        self.assertFalse((self.remote / "result").exists())

    def test_missing_source_does_not_connect(self):
        self.source.unlink()
        self.assertNotEqual(self.run_deploy().returncode, 0)
        self.assertFalse((self.root / "ssh-called").exists())

    def test_preview_uses_default_source_without_connecting(self):
        del self.config["local.file"]
        self.config["ssh.host"] = "::1"
        result = self.run_deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(PROJECT_DIR / "release/server/server.jar"), result.stdout)
        self.assertFalse((self.root / "ssh-called").exists())

    def test_preview_and_syntax_errors_do_not_echo_command_credentials(self):
        for preview, command in ((True, "TOKEN=deployment-secret; true"),
                                 (False, "TOKEN=deployment-secret; )")):
            with self.subTest(preview=preview):
                self.config["command.1"] = command
                result = self.run_deploy(*(["--dry-run"] if preview else []))
                self.assertEqual(result.returncode == 0, preview)
                self.assertNotIn("deployment-secret", result.stdout + result.stderr)
                self.assertFalse((self.root / "ssh-called").exists())

    def test_unknown_options_do_not_echo_credentials(self):
        result = self.run_deploy("--password=unregistered-cli-secret")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unregistered-cli-secret", result.stdout + result.stderr)
        self.assertFalse((self.root / "ssh-called").exists())

    def test_invalid_config_does_not_connect(self):
        for update in ({"ssh.host": "-oProxyCommand=bad"}, {"ssh.port": "bad"},
                       {"ssh.auth": "invalid"}, {"ssh.auth": ""},
                       {"ssh.auth": "password", "ssh.identityFile": "/unused/key"},
                       {"remote.dir": "relative"}, {"remote.name": "../other"},
                       {"command.1": ""}, {"typo": "value"}, {"command.01": "true"},
                       {"command.0": "true"}, {"command.1000000000": "true"},
                       {"command.1": "echo '未闭合"}):
            with self.subTest(update=update):
                original = self.config.copy()
                self.config.update(update)
                self.assertNotEqual(self.run_deploy().returncode, 0)
                self.assertFalse((self.root / "ssh-called").exists())
                self.config = original

    def test_properties_order_and_literal_values(self):
        # 顺序、CRLF、空白、末行无换行及命令内的等号和注释符共同验证。
        text = "\r\n  # 配置注释\r\n" + "\r\n".join(
            f"  {key} = {value} " for key, value in self.config.items() if not key.startswith("command.")
        ) + "\r\ncommand.10=printf '%s' \"$value\" >> result\r\ncommand.2=value='a=b # 内容'; printf '先执行:' > result"
        result = self.run_deploy(config_text=text)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.remote / "result").read_text(), "先执行:a=b # 内容")
        self.assertLess(result.stdout.index("执行 command.2"), result.stdout.index("执行 command.10"))

    def test_duplicate_and_malformed_properties_do_not_connect(self):
        text = "\n".join(f"{key}={value}" for key, value in self.config.items())
        for extra in ("ssh.host=another", "command.1=true", "缺少等号"):
            with self.subTest(extra=extra):
                self.assertNotEqual(self.run_deploy(config_text=text + "\n" + extra).returncode, 0)
                self.assertFalse((self.root / "ssh-called").exists())

    def test_config_values_do_not_execute_locally(self):
        marker = self.root / "不应创建"
        self.config["remote.dir"] = f"/tmp/$(touch '{marker}')"
        result = self.run_deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / "ssh-called").exists())

    def test_key_authentication_is_noninteractive(self):
        result = self.run_deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.root / "ssh-called").read_text())
        self.assertIn("BatchMode=yes", args)
        self.assertIn("PreferredAuthentications=publickey", args)

    def test_password_preview_does_not_need_terminal_or_connect(self):
        self.config["ssh.auth"] = "password"
        result = self.run_deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("认证方式：密码", result.stdout)
        self.assertFalse((self.root / "ssh-called").exists())

    def test_password_mode_without_terminal_does_not_connect(self):
        self.config["ssh.auth"] = "password"
        result = self.run_deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("密码模式需要本机交互终端", result.stderr)
        self.assertFalse((self.root / "ssh-called").exists())

    def test_password_terminal_input_preserves_upload(self):
        self.config["ssh.auth"] = "password"
        result = self.run_deploy(tty_password="test-only-password")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_bytes(), self.source.read_bytes())
        self.assertEqual((self.remote / "result").read_text(), "完成")
        self.assertNotIn("test-only-password", (self.root / "ssh-called").read_text())

    def test_wrong_password_stops_before_upload(self):
        self.config["ssh.auth"] = "password"
        result = self.run_deploy(tty_password="wrong-password")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("255", result.stderr)
        self.assertEqual(self.target.read_bytes(), b"original")
        self.assertFalse((self.remote / "result").exists())


if __name__ == "__main__":
    unittest.main()
