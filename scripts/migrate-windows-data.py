#!/usr/bin/env python3
"""显式迁移当前 Windows SQLite 数据到便携包；不覆盖目标、不删除源数据。"""
from contextlib import ExitStack, closing, contextmanager
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile


@contextmanager
def source_lock(path):
    import msvcrt
    if not path.exists():
        yield
        return
    with path.open("r+b") as stream:
        try:
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            raise RuntimeError("旧版仍在运行，请从托盘退出 Orbi 后再迁移") from None
        try:
            yield
        finally:
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


def migrate(source, bundle):
    if os.name != "nt":
        raise RuntimeError("此迁移入口仅适用于 Windows")
    source, bundle = Path(source).resolve(strict=True), Path(bundle).resolve(strict=True)
    destination = bundle / "data"
    if not (bundle / "Orbi.exe").is_file():
        raise RuntimeError("目标不是 Windows Orbi 应用目录")
    if source == destination or source in destination.parents or destination in source.parents:
        raise RuntimeError("源目录和目标目录不能相同或相互包含")
    if destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        raise RuntimeError("目标 data 已有内容，停止迁移以免覆盖")
    database = source / "kernel.db"
    settings = source / "database.properties"
    if settings.exists():
        # 当前界面生成的 SQLite 启动配置只包含 type/path 两项。
        values = dict(line.split("=", 1) for line in settings.read_text(encoding="utf-8").splitlines()
                      if line.strip() and not line.lstrip().startswith("#"))
        if values.get("type") != "sqlite" or set(values) != {"type", "path"}:
            raise RuntimeError("此一次性迁移入口仅处理 SQLite，请先核对数据库选择")
        # 解码界面写出的 properties 路径转义，不执行配置中的任何内容。
        value = values["path"]
        result, index = [], 0
        while index < len(value):
            char = value[index]
            if char == "\\":
                index += 1
                if index == len(value):
                    raise RuntimeError("数据库路径转义无效")
                char = value[index]
                if char == "u":
                    char = chr(int(value[index + 1:index + 5], 16))
                    index += 4
                else:
                    char = {"n": "\n", "r": "\r", "t": "\t", "f": "\f"}.get(char, char)
            result.append(char)
            index += 1
        database = (source / "".join(result)).resolve(strict=True)
    if not database.is_file():
        raise RuntimeError("找不到待迁移的 SQLite 数据库")
    with ExitStack() as locks:
        locks.enter_context(source_lock(source / "launch.lock"))
        locks.enter_context(source_lock(database.with_name(database.name + ".lock")))
        stage = Path(tempfile.mkdtemp(prefix=".data-migration-", dir=bundle))
        try:
            identity = subprocess.check_output(["whoami", "/user", "/fo", "csv", "/nh"], text=True).strip()
            import csv
            sid = next(csv.reader([identity]))[1]
            subprocess.run(["icacls", str(stage), "/inheritance:r", "/grant:r", f"*{sid}:(OI)(CI)F"],
                           stdout=subprocess.DEVNULL, check=True)
            for name in ("ui.json", "appearance.json"):
                if (source / name).is_file():
                    shutil.copy2(source / name, stage / name)
            if (source / "logc").is_dir():
                shutil.copytree(source / "logc", stage / "logc")
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as original, \
                    closing(sqlite3.connect(stage / "kernel.db")) as copied:
                if original.execute("PRAGMA application_id").fetchone()[0] != 0x4E455457 or original.execute("PRAGMA user_version").fetchone()[0] != 1:
                    raise RuntimeError("不是当前版本的 Orbi 数据库，停止迁移")
                original.backup(copied)
                certificates = copied.execute("SELECT profile_id,value FROM profile_settings WHERE key='tls.ca' AND value<>''").fetchall()
                for profile_id, value in certificates:
                    certificate = (database.parent / value).resolve(strict=True)
                    content = certificate.read_bytes()
                    relative = "certs/" + hashlib.sha256(content).hexdigest() + ".crt"
                    target = stage / relative
                    target.parent.mkdir(exist_ok=True)
                    target.write_bytes(content)
                    copied.execute("UPDATE profile_settings SET value=? WHERE profile_id=? AND key='tls.ca'", (relative, profile_id))
                copied.commit()
                if copied.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise RuntimeError("迁移后的数据库完整性检查未通过")
                profile_count = copied.execute("SELECT COUNT(*) FROM profiles").fetchone()[0]
            if settings.exists():
                (stage / "database.properties").write_text("type=sqlite\npath=kernel.db\n", encoding="utf-8")
            if destination.exists():
                destination.rmdir()
            stage.rename(destination)
        except BaseException:
            # 只清理本次在目标包内创建的暂存目录，始终保留原数据。
            if stage.exists() and stage.resolve().parent == bundle and stage.name.startswith(".data-migration-"):
                shutil.rmtree(stage)
            raise
    return {"dataDirectory": str(destination), "profiles": profile_count, "certificateReferences": len(certificates), "sourcePreserved": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = migrate(args.source, args.bundle)
    except (OSError, RuntimeError, sqlite3.Error, ValueError) as error:
        raise SystemExit(f"迁移停止：{error}") from None
    print("数据迁移完成：" + json.dumps(result, ensure_ascii=False))
