#!/usr/bin/env python3
"""
Kapsamli denetim: sablon dosyalari, workflow sozlesmeleri, dokuman-kod uyumu,
script kalitesi ve negatif/ pozitif bash testleri. Tum bulgular toplanir; ilk hatada durmaz.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get("CICD_TEST_ROOT", Path(__file__).resolve().parent.parent))
SCRIPTS = ROOT / "templates" / "scripts"
WORKFLOWS = ROOT / "templates" / ".github" / "workflows"
DOCS = ROOT / "docs"
FIXTURES = ROOT / "tests" / "fixtures"

passes: list[str] = []
failures: list[str] = []


def ok(code: str, detail: str = "") -> None:
    msg = f"PASS [{code}] {detail}".rstrip()
    passes.append(msg)
    print(msg)


def fail(code: str, detail: str) -> None:
    msg = f"FAIL [{code}] {detail}"
    failures.append(msg)
    print(msg)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def run_bash(
    script: str,
    *,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    timeout: int = 120,
) -> subprocess.CompletedProcess[str]:
    merged = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "LANG": "C.UTF-8",
    }
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", "-c", script],
        cwd=cwd or ROOT,
        env=merged,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def section(title: str) -> None:
    print(f"\n{'=' * 60}")
    print(title)
    print("=" * 60)


# ---------------------------------------------------------------------------
# A — Sablon envanteri
# ---------------------------------------------------------------------------
def audit_inventory() -> None:
    section("A — Sablon envanteri / template inventory")
    required_scripts = [
        "pipeline.sh",
        "ensure-infra.sh",
        "ssh-remote.sh",
        "setup-host.sh",
        "setup-remote-host.sh",
        "verify-health.sh",
    ]
    for name in required_scripts:
        path = SCRIPTS / name
        if not path.is_file():
            fail("A01", f"eksik script / missing: {path}")
            continue
        if not os.access(path, os.R_OK):
            fail("A02", f"okunamiyor / unreadable: {path}")
            continue
        ok("A01", name)

    required_workflows = [
        "continuous-integration.yml",
        "reusable-dotnet-build.yml",
        "production-deploy.yml",
        "production-rollback.yml",
    ]
    for name in required_workflows:
        path = WORKFLOWS / name
        if path.is_file():
            ok("A03", f"workflow {name}")
        else:
            fail("A03", f"eksik workflow / missing: {name}")

    action = ROOT / "templates" / ".github" / "actions" / "build-test" / "action.yml"
    if action.is_file():
        ok("A04", "build-test action.yml")
    else:
        fail("A04", "build-test action.yml eksik")

    for csproj in (
        FIXTURES / "CicdFixture.Web" / "CicdFixture.Web.csproj",
        FIXTURES / "CicdFixture.Data" / "CicdFixture.Data.csproj",
    ):
        if csproj.is_file():
            ok("A05", csproj.relative_to(ROOT).as_posix())
        else:
            fail("A05", f"fixture eksik / missing: {csproj}")

    mig_dir = FIXTURES / "CicdFixture.Data" / "Migrations"
    if mig_dir.is_dir() and any(mig_dir.glob("*.cs")):
        ok("A06", "EF migration dosyalari mevcut")
    else:
        fail("A06", "EF migration dosyalari yok")


# ---------------------------------------------------------------------------
# B — Script kalitesi
# ---------------------------------------------------------------------------
def audit_script_quality() -> None:
    section("B — Script kalitesi / script quality")
    for path in sorted(SCRIPTS.glob("*.sh")):
        data = read_text(path)
        if data.startswith("#!/usr/bin/env bash"):
            ok("B01", f"{path.name} shebang")
        else:
            fail("B01", f"{path.name} shebang eksik")

        if "set -euo pipefail" in data:
            ok("B02", f"{path.name} set -euo pipefail")
        else:
            fail("B02", f"{path.name} set -euo pipefail yok")

        if b"\r\n" in path.read_bytes():
            fail("B03", f"{path.name} CRLF iceriyor")
        else:
            ok("B03", f"{path.name} LF only")

    ensure = read_text(SCRIPTS / "ensure-infra.sh")
    stale = [
        "yapilandirilmamis / not configured",
        "Duzenlemeden RUN_ENSURE_INFRA",
        "customize this file",
    ]
    for phrase in stale:
        if phrase in ensure:
            fail("B04", f"ensure-infra stub kaldi: {phrase!r}")
    if not any(f.startswith("FAIL [B04]") for f in failures):
        ok("B04", "ensure-infra stub yok (gercek implementasyon)")

    if "run_ef_migration" in ensure and "dotnet ef database update" in ensure:
        ok("B05", "ensure-infra EF migration implementasyonu")
    else:
        fail("B05", "ensure-infra EF migration eksik")

    pipeline = read_text(SCRIPTS / "pipeline.sh")
    commands = [
        "publish-source",
        "deploy-artifacts",
        "write-env",
        "write-info",
        "restart",
        "health",
        "health-active",
        "switch",
        "rollback",
    ]
    for cmd in commands:
        if f'"{cmd}"' in pipeline or f"|{cmd}|" in pipeline or f" {cmd})" in pipeline:
            ok("B06", f"pipeline komutu / command: {cmd}")
        else:
            fail("B06", f"pipeline komutu eksik / missing: {cmd}")

    if "switch_traffic_to_idle" in pipeline and "revert_upstreams_saved" in pipeline:
        ok("B07", "pipeline nginx reload geri alma")
    else:
        fail("B07", "pipeline reload revert eksik")

    if "target_stop_one" in pipeline and "target_publish_dir" in pipeline:
        ok("B08", "pipeline deploy izin duzeltmesi")
    else:
        fail("B08", "pipeline target_stop_one/target_publish_dir eksik")


# ---------------------------------------------------------------------------
# C — Workflow sozlesmeleri
# ---------------------------------------------------------------------------
def audit_workflows() -> None:
    section("C — Workflow sozlesmeleri / workflow contracts")
    deploy = read_text(WORKFLOWS / "production-deploy.yml")

    if "environment: production" in deploy:
        ok("C01", "deploy production environment")
    else:
        fail("C01", "deploy production environment eksik")

    if re.search(r"permissions:\s*\n\s*contents:\s*read", deploy):
        ok("C02", "deploy least-privilege permissions")
    else:
        fail("C02", "deploy permissions eksik")

    if "cancel-in-progress: false" in deploy:
        ok("C03", "deploy concurrency cancel-in-progress false")
    else:
        fail("C03", "deploy concurrency eksik")

    steps = re.findall(r"^\s+- name: (.+)$", deploy, re.MULTILINE)
    if not steps:
        fail("C04", "deploy adimlari okunamadi")
    else:
        names = [s.lower() for s in steps]
        ensure_idx = next(
            (i for i, n in enumerate(names) if "ensure" in n or "infra" in n),
            -1,
        )
        publish_idxs = [
            i for i, n in enumerate(names) if "yayinla" in n or "publish" in n
        ]
        if ensure_idx >= 0 and publish_idxs and ensure_idx < min(publish_idxs):
            ok("C04", "ensure-infra publish oncesi")
        else:
            fail("C04", f"ensure-infra sira hatasi (idx={ensure_idx}, publish={publish_idxs})")

        restart_pos = deploy.find("pipeline.sh restart")
        health_pos = deploy.find("id: health")
        switch_pos = deploy.find("pipeline.sh switch")
        if restart_pos > 0 and health_pos > restart_pos and switch_pos > health_pos:
            ok("C05", "restart -> health -> switch sirasi")
        else:
            fail("C05", f"restart/health/switch pozisyon: {restart_pos}/{health_pos}/{switch_pos}")

    if "vars.EF_PROJECT" in deploy and "ensure-infra.sh" in deploy:
        ok("C06", "deploy EF_PROJECT + ensure-infra.sh")
    else:
        fail("C06", "deploy EF_PROJECT baglantisi eksik")

    if "SSH_KNOWN_HOSTS" in deploy and "MITM" in deploy:
        ok("C07", "deploy SSH_KNOWN_HOSTS dokumantasyonu")
    else:
        fail("C07", "deploy SSH_KNOWN_HOSTS eksik")

    rollback = read_text(WORKFLOWS / "production-rollback.yml")
    if "pipeline.sh rollback" in rollback:
        ok("C08", "rollback workflow rollback komutu")
    else:
        fail("C08", "rollback workflow eksik")

    if "environment: production" in rollback:
        ok("C09", "rollback production environment")
    else:
        fail("C09", "rollback production environment eksik")

    ci = read_text(WORKFLOWS / "continuous-integration.yml")
    if "reusable-dotnet-build" in ci or "build-test" in ci:
        ok("C10", "CI build baglantisi")
    else:
        fail("C10", "CI workflow build eksik")

    pinned = re.findall(r"uses:\s+\S+@[0-9a-f]{40}", deploy)
    if len(pinned) >= 2:
        ok("C11", f"deploy action SHA pin ({len(pinned)} adet)")
    else:
        fail("C11", "deploy action SHA pin yetersiz")


# ---------------------------------------------------------------------------
# D — Dokuman / kod uyumu
# ---------------------------------------------------------------------------
def audit_docs() -> None:
    section("D — Dokuman-kod uyumu / doc-code sync")
    doc_files = [
        ROOT / "README.md",
        DOCS / "company-setup.tr.md",
        DOCS / "company-setup.en.md",
        DOCS / "beginner-walkthrough.tr.md",
        DOCS / "beginner-walkthrough.en.md",
        DOCS / "kendi-projene-entegrasyon.tr.md",
        DOCS / "own-project-integration.en.md",
        DOCS / "dotnet-cicd-template.tr.md",
        DOCS / "dotnet-cicd-template.en.md",
    ]
    stale_patterns = [
        r"ensure-infra\.sh.*duzenle",
        r"customize.*ensure-infra",
        r"hook'u ve siz doldurursunuz",
        r"you fill it in",
        r"yapilandirilmamis",
        r"not configured",
        r"RUN_ENSURE_INFRA=true yapmayin",
        r"before customizing this file",
    ]
    required_phrases = ["EF_PROJECT"]

    for doc in doc_files:
        if not doc.is_file():
            fail("D01", f"eksik dokuman / missing: {doc.name}")
            continue
        text = read_text(doc)
        rel = doc.relative_to(ROOT).as_posix()
        for phrase in required_phrases:
            if phrase in text:
                ok("D02", f"{rel} -> {phrase}")
            else:
                fail("D02", f"{rel} icinde {phrase!r} yok")

        for pat in stale_patterns:
            if re.search(pat, text, re.IGNORECASE):
                fail("D03", f"{rel} eski ifade / stale: /{pat}/")

    readme_path = ROOT / "README.md"
    if readme_path.is_file():
        readme = read_text(readme_path)
        if "ensure-infra" in readme.lower() or "migration" in readme:
            ok("D04", "README migration akisi")
        else:
            fail("D04", "README migration akisi eksik")
    else:
        fail("D04", "README.md bulunamadi (audit kopyasi eksik)")

    tree_path = DOCS / "company-setup.tr.md"
    if tree_path.is_file():
        tree = read_text(tree_path)
        if "ensure-infra.sh" in tree:
            ok("D05", "company-setup dosya agaci ensure-infra")
        else:
            fail("D05", "company-setup dosya agacinda ensure-infra.sh yok")
    else:
        fail("D05", "company-setup.tr.md bulunamadi")


# ---------------------------------------------------------------------------
# E — Bash sozlesme testleri (negatif + pozitif)
# ---------------------------------------------------------------------------
def audit_bash_contracts() -> None:
    section("E — Bash sozlesme testleri / bash contract tests")
    sc = SCRIPTS

    r = run_bash(f'bash "{sc}/pipeline.sh" 2>&1')
    if r.returncode != 0 and "usage" in r.stdout + r.stderr:
        ok("E01", "pipeline argumansiz reddedilir")
    else:
        fail("E01", f"pipeline argumansiz beklenen hata yok rc={r.returncode}")

    r = run_bash(f'bash "{sc}/pipeline.sh" not-a-command 2>&1')
    if r.returncode != 0:
        ok("E02", "pipeline gecersiz komut reddedilir")
    else:
        fail("E02", "pipeline gecersiz komut kabul edildi")

    r = run_bash(f'bash "{sc}/pipeline.sh" health 2>&1', env={"DEPLOY_TARGET": "local"})
    if r.returncode != 0:
        ok("E03", "pipeline SERVICES zorunlu")
    else:
        fail("E03", f"pipeline SERVICES eksikken rc=0 (subshell bug?)")

    bad_svc = "web|c|/opt/bad;rm|web|http://127.0.0.1:5001/health"
    r = run_bash(
        f'DEPLOY_TARGET=local SERVICES="{bad_svc}" bash "{sc}/pipeline.sh" health 2>&1'
    )
    if r.returncode != 0 and ("gecersiz" in r.stdout + r.stderr or "invalid" in r.stdout + r.stderr):
        ok("E04", "pipeline SERVICES path injection reddedilir")
    else:
        fail("E04", "pipeline SERVICES path validation zayif")

    r = run_bash(f'EF_PROJECT= bash "{sc}/ensure-infra.sh" 2>&1')
    if r.returncode == 0 and "skipping migration" in r.stdout + r.stderr:
        ok("E05", "ensure-infra EF_PROJECT bos -> skip")
    else:
        fail("E05", f"ensure-infra skip beklenmedi rc={r.returncode}")

    r = run_bash(f'RUN_ENSURE_INFRA=true EF_PROJECT= bash "{sc}/ensure-infra.sh" 2>&1')
    if r.returncode != 0 and "EF_PROJECT" in r.stdout + r.stderr:
        ok("E06", "RUN_ENSURE_INFRA=true + bos EF_PROJECT -> hata")
    else:
        fail("E06", f"RUN_ENSURE_INFRA guard zayif rc={r.returncode}")

    r = run_bash(f'EF_PROJECT=not-a-csproj bash "{sc}/ensure-infra.sh" 2>&1')
    if r.returncode != 0 and "invalid" in (r.stdout + r.stderr).lower():
        ok("E07", "ensure-infra gecersiz EF_PROJECT yolu")
    else:
        fail("E07", f"ensure-infra path validation zayif rc={r.returncode}")

    fake = ROOT / "tests" / "fixtures" / "missing.csproj"
    r = run_bash(
        f'EF_PROJECT="{fake}" EF_STARTUP_PROJECT="{FIXTURES}/CicdFixture.Web/CicdFixture.Web.csproj" '
        f'bash "{sc}/ensure-infra.sh" 2>&1'
    )
    if r.returncode != 0 and "not found" in (r.stdout + r.stderr).lower():
        ok("E08", "ensure-infra olmayan csproj reddedilir")
    else:
        fail("E08", f"ensure-infra missing file guard zayif rc={r.returncode}")

    r = run_bash(
        f'source "{sc}/ssh-remote.sh"; ssh_remote_init 2>&1',
        env={
            "DEPLOY_TARGET": "remote",
            "SSH_HOST": "h",
            "SSH_USER": "u",
            "SSH_PRIVATE_KEY": "fake",
        },
    )
    if r.returncode != 0 and "SSH_KNOWN_HOSTS" in r.stdout + r.stderr:
        ok("E09", "ssh-remote SSH_KNOWN_HOSTS zorunlu (MITM)")
    else:
        fail("E09", f"ssh-remote MITM guard zayif rc={r.returncode}")

    r = run_bash(f'bash "{sc}/verify-health.sh" 2>&1')
    if r.returncode != 0:
        ok("E10", "verify-health argumansiz reddedilir")
    else:
        fail("E10", "verify-health argumansiz kabul edildi")

    web = FIXTURES / "CicdFixture.Web" / "CicdFixture.Web.csproj"
    data = FIXTURES / "CicdFixture.Data" / "CicdFixture.Data.csproj"
    db = "/tmp/cicd-audit-migrate.db"
    run_bash(f"rm -f '{db}'")
    svc = f"web|{web}|/opt/x|x|http://127.0.0.1:5001/health"
    env_line = f"ConnectionStrings__DefaultConnection=Data Source={db}"
    r = run_bash(
        f'bash "{sc}/ensure-infra.sh" 2>&1',
        env={
            "EF_PROJECT": str(data),
            "EF_STARTUP_PROJECT": str(web),
            "SERVICES": svc,
            "APP_ENV": env_line,
        },
        timeout=180,
    )
    if r.returncode == 0 and Path(db).is_file():
        ok("E11", "ensure-infra gercek EF migration")
    else:
        detail = (r.stdout + r.stderr)[-500:]
        fail("E11", f"ensure-infra migration basarisiz rc={r.returncode}: {detail}")

    r2 = run_bash(
        f'bash "{sc}/ensure-infra.sh" 2>&1',
        env={
            "EF_PROJECT": str(data),
            "EF_STARTUP_PROJECT": str(web),
            "SERVICES": svc,
            "APP_ENV": env_line,
        },
        timeout=180,
    )
    if r2.returncode == 0:
        ok("E12", "ensure-infra migration idempotent (2. calistirma)")
    else:
        fail("E12", f"ensure-infra 2. migration basarisiz rc={r2.returncode}")

    # APP_ENV icinde esittir
    eq_db = "/tmp/cicd-audit-eq.db"
    run_bash(f"rm -f '{eq_db}'")
    r = run_bash(
        f'bash "{sc}/ensure-infra.sh" 2>&1',
        env={
            "EF_PROJECT": str(data),
            "EF_STARTUP_PROJECT": str(web),
            "APP_ENV": f"ConnectionStrings__DefaultConnection=Data Source={eq_db}",
        },
        timeout=180,
    )
    if r.returncode == 0 and Path(eq_db).is_file():
        ok("E13", "APP_ENV ConnectionStrings esittir islenir")
    else:
        fail("E13", "APP_ENV parse hatasi olabilir")

    r = run_bash(
        f'bash "{sc}/ensure-infra.sh" 2>&1',
        env={
            "EF_PROJECT": str(data),
            "SERVICES": svc,
            "APP_ENV": "ConnectionStrings__DefaultConnection=Data Source=/tmp/cicd-audit-svc.db",
        },
        timeout=180,
    )
    if r.returncode == 0:
        ok("E14", "EF_STARTUP_PROJECT SERVICES ilk csproj fallback")
    else:
        fail("E14", f"EF_STARTUP fallback basarisiz rc={r.returncode}")


# ---------------------------------------------------------------------------
# F — .NET fixture derleme
# ---------------------------------------------------------------------------
def audit_dotnet() -> None:
    section("F — .NET fixture derleme / build")
    if not shutil_which("dotnet"):
        print("SKIP F01 dotnet SDK yok")
        return
    test_proj = FIXTURES / "CicdFixture.Tests" / "CicdFixture.Tests.csproj"
    r = subprocess.run(
        [
            "dotnet",
            "test",
            str(test_proj),
            "--configuration",
            "Release",
            "--verbosity",
            "minimal",
            "/p:UseSharedCompilation=false",
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=180,
    )
    if r.returncode == 0:
        ok("F01", "dotnet test fixture")
    else:
        fail("F01", f"dotnet test basarisiz:\n{r.stdout}\n{r.stderr}")


def shutil_which(cmd: str) -> str | None:
    from shutil import which

    return which(cmd)


# ---------------------------------------------------------------------------
# G — README ic linkler
# ---------------------------------------------------------------------------
def audit_links() -> None:
    section("G — Dokuman linkleri / doc links")
    readme_path = ROOT / "README.md"
    if not readme_path.is_file():
        fail("G01", "README.md yok — link taramasi atlandi")
        return
    readme = read_text(readme_path)
    links = re.findall(r"\]\((docs/[^)]+\.md)\)", readme)
    for link in links:
        path = ROOT / link.replace("/", os.sep)
        if path.is_file():
            ok("G01", link)
        else:
            fail("G01", f"README kirrik link / broken: {link}")


# ---------------------------------------------------------------------------
def main() -> int:
    print("KAPSAMLI DENETIM / COMPREHENSIVE AUDIT")
    print(f"ROOT={ROOT}")
    audit_inventory()
    audit_script_quality()
    audit_workflows()
    audit_docs()
    audit_bash_contracts()
    audit_dotnet()
    audit_links()

    print(f"\n{'=' * 60}")
    print(f"SONUC / RESULT: {len(passes)} PASS, {len(failures)} FAIL")
    print("=" * 60)
    if failures:
        print("\nBASARISIZLAR / FAILURES:")
        for f in failures:
            print(f"  {f}")
        return 1
    print("\nKAPSAMLI DENETIM: TUM TESTLER GECTI")
    return 0


if __name__ == "__main__":
    sys.exit(main())
