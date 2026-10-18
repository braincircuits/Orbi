"""验证 Windows 便携迁移的数据完整性、冲突保护与运行锁。"""
from contextlib import closing
import importlib.util
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("portable_migration", Path(__file__).resolve().parents[1] / "migrate-windows-data.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


@unittest.skipUnless(os.name == "nt", "仅验证 Windows 迁移")
class WindowsDataMigrationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="orbi-migration-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "旧数据"
        self.source.mkdir()
        self.bundle = self.root / "便携程序"
        self.bundle.mkdir()
        (self.bundle / "Orbi.exe").touch()
        (self.bundle / "data").mkdir()
        self.certificate = self.root / "外部 CA.crt"
        self.certificate.write_bytes(b"public-certificate-test")
        with closing(sqlite3.connect(self.source / "kernel.db")) as database:
            database.executescript("PRAGMA application_id=1313166423; PRAGMA user_version=1;"
                "CREATE TABLE profiles(id TEXT PRIMARY KEY,name TEXT);"
                "CREATE TABLE profile_settings(profile_id TEXT,key TEXT,value TEXT);"
                "CREATE TABLE history(value INTEGER); INSERT INTO history VALUES(42);")
            database.execute("INSERT INTO profiles VALUES('test','原连接')")
            database.executemany("INSERT INTO profile_settings VALUES('test',?,?)",
                                [("tls.ca", str(self.certificate)), ("password", "private-test")])
            database.commit()
        (self.source / "ui.json").write_text('{"tunEngine":"tun2socks"}')
        (self.source / "appearance.json").write_text('{"themeMode":"dark"}')
        (self.source / "run").mkdir()
        (self.source / "run/control.json").write_text("过期发现文件")
        (self.source / "kernel.db.lock").touch()
        (self.source / "launch.lock").touch()

    def test_relocation_preserves_database_and_imports_certificate_without_changing_source(self):
        original = (self.source / "kernel.db").read_bytes()
        result = migration.migrate(self.source, self.bundle)
        self.assertEqual(result["profiles"], 1)
        moved = self.root / "移动后的程序"
        self.bundle.rename(moved)
        with closing(sqlite3.connect(moved / "data/kernel.db")) as database:
            values = dict(database.execute("SELECT key,value FROM profile_settings"))
            self.assertFalse(Path(values["tls.ca"]).is_absolute())
            self.assertEqual((moved / "data" / values["tls.ca"]).read_bytes(), self.certificate.read_bytes())
            self.assertEqual(values["password"], "private-test")
            self.assertEqual(database.execute("SELECT value FROM history").fetchone()[0], 42)
        self.assertEqual((self.source / "kernel.db").read_bytes(), original)
        self.assertTrue((moved / "data/ui.json").exists())
        self.assertTrue((moved / "data/appearance.json").exists())
        self.assertFalse((moved / "data/run").exists())
        self.assertFalse((moved / "data/kernel.db.lock").exists())

    def test_existing_destination_is_never_overwritten(self):
        existing = self.bundle / "data/ui.json"
        existing.write_text("保留目标内容")
        with self.assertRaisesRegex(RuntimeError, "已有内容"):
            migration.migrate(self.source, self.bundle)
        self.assertEqual(existing.read_text(), "保留目标内容")

    def test_running_kernel_lock_prevents_migration(self):
        import msvcrt
        with (self.source / "kernel.db.lock").open("r+b") as stream:
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            try:
                with self.assertRaisesRegex(RuntimeError, "仍在运行"):
                    migration.migrate(self.source, self.bundle)
            finally:
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
        self.assertFalse(any((self.bundle / "data").iterdir()))

    def test_missing_certificate_leaves_source_and_destination_untouched(self):
        self.certificate.unlink()
        with self.assertRaises(OSError):
            migration.migrate(self.source, self.bundle)
        self.assertFalse(any((self.bundle / "data").iterdir()))
        self.assertTrue((self.source / "kernel.db").exists())


if __name__ == "__main__":
    unittest.main()
