"""验证初始化错误不回显密码、认证令牌或原始协议内容。"""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
import traceback
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "initialize-kernel.py"
SPEC = importlib.util.spec_from_file_location("initialize_kernel", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class InitializeKernelTest(unittest.TestCase):
    def test_unknown_options_do_not_echo_credentials(self):
        output = io.StringIO()
        with mock.patch("sys.argv", [str(SCRIPT), "--jar", "unused.jar", "--db", "unused.db", "--ca", "unused.crt", "--password=unregistered-cli-secret"]), \
             contextlib.redirect_stderr(output):
            with self.assertRaises(SystemExit) as raised:
                MODULE.main()
        self.assertNotEqual(raised.exception.code, 0)
        self.assertNotIn("unregistered-cli-secret", output.getvalue())

    def test_invalid_discovery_does_not_echo_credentials(self):
        secret = "unknown-management-token-012345678901234567890"
        with tempfile.TemporaryDirectory() as directory:
            endpoint = Path(directory) / "control.json"
            for address in ("http://[" + secret, "http://user:" + secret + "@127.0.0.1:9090",
                            "http://127.0.0.1:9090/?token=" + secret):
                with self.subTest(address=address):
                    endpoint.write_text(json.dumps({"apiVersion": 1, "url": address, "token": secret}))
                    with self.assertRaises(RuntimeError) as raised:
                        MODULE.load_access(endpoint)
                    self.assertNotIn(secret, "".join(traceback.format_exception(raised.exception)))
            endpoint.write_text(json.dumps({"apiVersion": 1, "url": "http://127.0.0.1:9090", "token": secret}))
            self.assertEqual(MODULE.load_access(endpoint), ("127.0.0.1:9090", secret))

    def test_invalid_authorization_token_is_rejected_before_request(self):
        secret = "unknown-management-token-012345678901234567890"
        with tempfile.TemporaryDirectory() as directory:
            endpoint = Path(directory) / "control.json"
            for token in (secret + "\ninjected", secret + "\rinjected", secret + "\x00", secret + "中文", secret + " "):
                with self.subTest(token=repr(token)):
                    endpoint.write_text(json.dumps({"apiVersion": 1, "url": "http://127.0.0.1:9090", "token": token}))
                    with self.assertRaises(RuntimeError) as raised:
                        MODULE.load_access(endpoint)
                    self.assertNotIn(secret, "".join(traceback.format_exception(raised.exception)))

    def test_startup_output_and_http_errors_are_not_reprinted(self):
        secret = "unknown-reflected-credential"
        for mode in ("startup", "http", "protocol", "success"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                jar = root / "client.jar"
                jar.touch()
                process = mock.Mock(stdout=io.StringIO("Bearer " + secret), returncode=1)
                process.poll.return_value = 1 if mode == "startup" else None

                def start(arguments, **_):
                    if mode != "startup":
                        endpoint = Path(arguments[arguments.index("--endpoint-file") + 1])
                        endpoint.write_text(json.dumps({"apiVersion": 1, "url": "http://127.0.0.1:9090", "token": "x" * 32}))
                    return process

                connection = mock.Mock()
                connection.getresponse.return_value.status = 403
                connection.getresponse.return_value.read.return_value = ("Bearer " + secret).encode()
                if mode == "success":
                    connection.getresponse.return_value.status = 200
                if mode == "protocol":
                    connection.getresponse.side_effect = MODULE.http.client.BadStatusLine(secret)
                with mock.patch.object(MODULE.subprocess, "Popen", side_effect=start), \
                     mock.patch.object(MODULE.http.client, "HTTPConnection", return_value=connection), \
                     mock.patch("builtins.input", return_value="test-password"), \
                     mock.patch("sys.argv", [str(SCRIPT), "--jar", str(jar), "--db", str(root / "kernel.db"), "--ca", str(root / "ca.crt")]):
                    if mode == "success":
                        output = io.StringIO()
                        with contextlib.redirect_stdout(output):
                            MODULE.main()
                        self.assertIn("内核数据库已初始化", output.getvalue())
                        self.assertNotIn(secret, output.getvalue())
                        self.assertEqual(json.loads(connection.request.call_args.args[2])["connections"][0]["config"]["password"], "test-password")
                    else:
                        with self.assertRaises(RuntimeError) as raised:
                            MODULE.main()
                        rendered = "".join(traceback.format_exception(raised.exception))
                        self.assertNotIn(secret, rendered)
                        self.assertIn("初始化", str(raised.exception))
                        if mode == "http":
                            self.assertIn("403", str(raised.exception))
