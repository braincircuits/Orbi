"""验证真实便携应用测试按界面状态等待，不依赖固定初始化时长。"""
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


@unittest.skipUnless(os.name == "nt", "仅验证 Windows 宿主")
class WindowsPortableReadyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "portable_host", Path(__file__).resolve().parents[1] / "test-windows-portable.py")
        cls.host = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.host)

    def setUp(self):
        self.elapsed = 0
        self.process = SimpleNamespace(poll=Mock(return_value=None))
        self.user = Mock()
        self.user.GetSystemMenu.return_value = 7
        self.user.GetMenuState.return_value = 0
        self.window = self.enterContext(patch.object(self.host, "find_window", return_value=17))
        self.enterContext(patch.object(self.host, "user", self.user))
        self.enterContext(patch.object(self.host, "time", SimpleNamespace(
            monotonic=lambda: self.elapsed, sleep=self.advance)))

    def advance(self, seconds):
        self.elapsed += seconds

    def test_ready_window_has_no_fixed_delay(self):
        self.assertEqual(self.host.wait_until_ready(self.process), 17)
        self.assertEqual(self.elapsed, 0)

    def test_initialization_longer_than_one_second_waits_until_enabled(self):
        self.user.GetMenuState.side_effect = lambda *_: 3 if self.elapsed < 3 else 0
        self.assertEqual(self.host.wait_until_ready(self.process, timeout=5), 17)
        self.assertGreaterEqual(self.elapsed, 3)

    def test_busy_or_missing_command_times_out(self):
        for state in (1, 3, 0xffffffff):
            with self.subTest(state=state):
                self.elapsed = 0
                self.user.GetMenuState.return_value = state
                with self.assertRaisesRegex(TimeoutError, "退出菜单未启用"):
                    self.host.wait_until_ready(self.process, timeout=0.3)

    def test_waits_for_window_before_reading_menu(self):
        self.window.side_effect = lambda _: 17 if self.elapsed >= 2 else None
        self.assertEqual(self.host.wait_until_ready(self.process), 17)
        self.assertGreaterEqual(self.elapsed, 2)
        self.user.GetSystemMenu.assert_called_once_with(17, False)

    def test_early_process_exit_fails_without_waiting(self):
        self.process.poll.return_value = 1
        with self.assertRaisesRegex(RuntimeError, "就绪前退出"):
            self.host.wait_until_ready(self.process)
        self.assertEqual(self.elapsed, 0)


if __name__ == "__main__":
    unittest.main()
