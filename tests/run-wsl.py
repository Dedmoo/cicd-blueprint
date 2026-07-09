#!/usr/bin/env python3
"""WSL test runner: copies scripts to /tmp with LF line endings and runs all tests."""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent
DST = Path("/tmp/cicd-bp-test")


def copy_tree(rel: str) -> None:
    src_dir = SRC / rel
    if not src_dir.is_dir():
        return
    for src_file in src_dir.rglob("*"):
        if not src_file.is_file():
            continue
        dst_file = DST / src_file.relative_to(SRC)
        dst_file.parent.mkdir(parents=True, exist_ok=True)
        data = re.sub(rb"\r\n", b"\n", src_file.read_bytes())
        dst_file.write_bytes(data)
        if src_file.suffix in (".sh", ".py") or src_file.name.endswith(".sh"):
            dst_file.chmod(0o755)


def copy_scripts() -> None:
    if DST.exists():
        shutil.rmtree(DST)
    for pattern in (
        "templates/scripts/*.sh",
        "tests/*.sh",
        "tests/*.py",
        "templates/.github/workflows/*.yml",
        ".github/workflows/*.yml",
    ):
        for src_file in SRC.glob(pattern):
            rel = src_file.relative_to(SRC)
            dst_file = DST / rel
            dst_file.parent.mkdir(parents=True, exist_ok=True)
            data = re.sub(rb"\r\n", b"\n", src_file.read_bytes())
            dst_file.write_bytes(data)
            dst_file.chmod(0o755)
    copy_tree("tests/fixtures")


def run(cmd: list[str], check: bool = True) -> int:
    print(f"\n>>> {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=DST)
    if check and result.returncode != 0:
        print(f"FAILED (exit {result.returncode}): {' '.join(cmd)}")
        sys.exit(result.returncode)
    return result.returncode


def main() -> None:
    copy_scripts()
    os.chdir(DST)
    run(["python3", "tests/scan-local-vars.py"])
    run(["bash", "tests/static-check.sh"])
    run(["sudo", "bash", "tests/state-test.sh"])
    run(["sudo", "bash", "tests/remote-sim-setup.sh"])
    run(["bash", "tests/e2e-full.sh"])
    print("\n=== ALL TESTS PASSED ===")


if __name__ == "__main__":
    main()
