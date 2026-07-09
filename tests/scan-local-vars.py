#!/usr/bin/env python3
"""Tara: bash scriptlerde 'local' ile bildirilen ama govdede kullanilmayan degiskenler."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = list((ROOT / "templates/scripts").glob("*.sh"))

# Bilinen kasitli kisaltmalar (tek harf / standart)
ALLOW_SHORT = {"c", "m", "w", "i", "f", "sf", "ok", "dd", "svc", "val", "hp"}

SUSPICIOUS_SUFFIXES = (
    "_use", "_di", "_colo", "colo", "targe", "rollbac", "servic",
    "deploymen", "healt", "switc", "restar", "upstrea",
)

issues: list[str] = []


def scan_file(path: Path) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    func_name = "<top>"
    func_start = 0
    declared: dict[str, int] = {}

    def flush_func(end: int) -> None:
        nonlocal declared, func_name, func_start
        if not declared:
            return
        body = "\n".join(lines[func_start:end])
        for var, decl_line in declared.items():
            escaped = re.escape(var)
            use_pat = re.compile(rf"\${escaped}\b|(?<![A-Za-z0-9_]){escaped}=")
            if not use_pat.search(body):
                issues.append(
                    f"{path.name}:{decl_line}: '{var}' local bildirildi ama "
                    f"fonksiyon '{func_name}' icinde kullanilmiyor"
                )
            for suf in SUSPICIOUS_SUFFIXES:
                if var.endswith(suf) or var == suf.strip("_"):
                    issues.append(
                        f"{path.name}:{decl_line}: supheli kesik isim '{var}' "
                        f"(fonksiyon: {func_name})"
                    )

    for i, line in enumerate(lines, 1):
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{", line)
        if m:
            flush_func(i - 1)
            func_name = m.group(1)
            func_start = i
            declared = {}
            continue

        if re.match(r"^\}\s*$", line) and func_name != "<top>":
            flush_func(i)
            func_name = "<top>"
            func_start = i
            declared = {}
            continue

        lm = re.match(r"^\s*local\s+(.+)$", line)
        if lm and func_name != "<top>":
            decl_part = lm.group(1).split("#")[0].strip()
            for chunk in re.split(r"\s*;\s*", decl_part):
                chunk = chunk.strip()
                if not chunk:
                    continue
                for token in chunk.split():
                    name = token.split("=")[0].strip()
                    if name and name not in ALLOW_SHORT and re.match(
                        r"^[a-zA-Z_][a-zA-Z0-9_]*$", name
                    ):
                        declared.setdefault(name, i)

    flush_func(len(lines))


for p in SCRIPTS:
    scan_file(p)

if issues:
    print("BULGU:", len(issues))
    for item in issues:
        print(" -", item)
    sys.exit(1)

print("local degisken taramasi: supheli kesik isim veya kullanilmayan local YOK")
print(f"Taranan: {len(SCRIPTS)} script")
