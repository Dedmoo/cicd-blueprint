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
        "templates/.github/actions/**",
        ".github/workflows/*.yml",
    ):
        for src_file in SRC.glob(pattern):
            if not src_file.is_file():
                continue
            rel = src_file.relative_to(SRC)
            dst_file = DST / rel
            dst_file.parent.mkdir(parents=True, exist_ok=True)
            data = re.sub(rb"\r\n", b"\n", src_file.read_bytes())
            dst_file.write_bytes(data)
            if src_file.suffix in (".sh", ".py") or src_file.name.endswith(".sh"):
                dst_file.chmod(0o755)
    copy_tree("tests/fixtures")
    copy_tree("docs")
    for extra in ("README.md",):
        src_file = SRC / extra
        if src_file.is_file():
            dst_file = DST / extra
            data = re.sub(rb"\r\n", b"\n", src_file.read_bytes())
            dst_file.write_bytes(data)


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
    os.environ["CICD_TEST_ROOT"] = str(DST)
    stages = [
        ("scan-local-vars", ["python3", "tests/scan-local-vars.py"]),
        ("comprehensive-audit", ["python3", "tests/comprehensive-audit.py"]),
        ("static-check", ["bash", "tests/static-check.sh"]),
        ("contract-test", ["sudo", "bash", "tests/contract-test.sh"]),
        ("state-test", ["sudo", "bash", "tests/state-test.sh"]),
        ("remote-sim-setup", ["sudo", "bash", "tests/remote-sim-setup.sh"]),
        ("e2e-full", ["bash", "tests/e2e-full.sh"]),
    ]
    for name, cmd in stages:
        print(f"\n{'#' * 60}")
        print(f"# STAGE: {name}")
        print(f"{'#' * 60}")
        run(cmd)
    print("\n=== ALL TESTS PASSED ===")


if __name__ == "__main__":
    main()
