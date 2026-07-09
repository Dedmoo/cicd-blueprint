#!/usr/bin/env bash
# Tam E2E: gercek .NET uygulamasi + uzak SSH + systemd + nginx + tum pipeline asamalari.
# Mock yok. Onceden: sudo bash tests/remote-sim-setup.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="$REPO/tests/.sim-keys"
SC="$REPO/templates/scripts"
FIXTURE_WEB="$REPO/tests/fixtures/CicdFixture.Web/CicdFixture.Web.csproj"
FIXTURE_TEST="$REPO/tests/fixtures/CicdFixture.Tests/CicdFixture.Tests.csproj"
ENSURE_E2E="$REPO/tests/fixtures/ensure-infra-e2e.sh"
VERIFY="$SC/verify-health.sh"

RC=0
E2E_START=$(date +%s)
PHASE_START=0
PHASE_ID=""

pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; RC=1; }
die(){ echo "FAIL: $1"; exit 1; }

phase_begin(){
  PHASE_ID="$1"
  PHASE_START=$(date +%s)
  echo ""
  echo "################################################################"
  echo "# E2E ${PHASE_ID}: $2"
  echo "################################################################"
}

phase_end(){
  local elapsed=$(( $(date +%s) - PHASE_START ))
  echo "--- E2E ${PHASE_ID} bitti / done (${elapsed}s) ---"
}

[ -f "$KEYDIR/deploy_key" ] || { echo "Once: sudo bash tests/remote-sim-setup.sh"; exit 1; }
command -v dotnet >/dev/null 2>&1 || { echo "dotnet gerekli / required"; exit 1; }

HOST="$(cat "$KEYDIR/host" 2>/dev/null || hostname -I | awk '{print $1}')"
[ -n "$HOST" ] || HOST="127.0.0.1"
echo "$HOST" > "$KEYDIR/host"

SIM_USER="cicddeploy"
PORT=5199
DD="/opt/cicd-e2e-web"
SVC="e2eweb"
DLL="CicdFixture.Web.dll"

export DEPLOY_TARGET=remote
export SSH_HOST="$HOST"
export SSH_USER="$SIM_USER"
export SSH_PORT=22
export SSH_PRIVATE_KEY="$(cat "$KEYDIR/deploy_key")"
export SSH_KNOWN_HOSTS="$(cat "$KEYDIR/known_hosts")"
export CONFIG=Release
export SERVICES="web|${FIXTURE_WEB}|${DD}|${SVC}|http://${HOST}:${PORT}/health"

# shellcheck source=ssh-remote.sh
source "$SC/ssh-remote.sh"
ssh_remote_init

# Eski remote-sim mock curl'u kaldir (sadece 200 yazdiriyordu — gercek health icin gerekli).
# Remove legacy remote-sim mock curl (it only printed 200).
remote_sudo '
if [ -f /usr/local/bin/curl.real ]; then
  mv -f /usr/local/bin/curl.real /usr/local/bin/curl
  chmod +x /usr/local/bin/curl
  echo "curl gercek surume geri yuklendi / restored real curl"
elif head -1 /usr/local/bin/curl 2>/dev/null | grep -q "^#!/bin/bash"; then
  rm -f /usr/local/bin/curl
  echo "mock curl kaldirildi / removed mock curl"
fi
'

public_health_version(){
  python3 -c "
import json, urllib.request
r = urllib.request.urlopen('http://${HOST}:${PORT}/health', timeout=10)
d = json.load(r)
print(d.get('version', ''))
" 2>/dev/null || true
}

active_color(){
  remote_ssh "cat /etc/nginx/cicd/${SVC}.active" 2>/dev/null || echo blue
}

publish_artifact(){
  local out_root="$1"
  mkdir -p "${out_root}/web"
  dotnet publish "$FIXTURE_WEB" \
    --configuration Release \
    --output "${out_root}/web" \
    /p:UseSharedCompilation=false \
    --verbosity minimal
}

dump_unit_logs() {
  local color="$1"
  remote_sudo "journalctl -u '${SVC}-${color}' -n 25 --no-pager" 2>/dev/null || true
}

pipeline_deploy_cycle(){
  local version="$1"
  export APP_ENV="DEPLOY_VERSION=${version}"
  export GIT_SHA="e2e-${version}" DEPLOYED_BY="e2e-full" DEPLOY_NOTE="v${version}"
  bash "$SC/pipeline.sh" deploy-artifacts
  bash "$SC/pipeline.sh" write-env
  bash "$SC/pipeline.sh" write-info
  bash "$SC/pipeline.sh" restart
  bash "$SC/pipeline.sh" health
  bash "$SC/pipeline.sh" switch
}

# -------------------------------------------------------------------------
phase_begin "00" "Ortam / environment"
echo "host=${HOST} user=${SIM_USER} port=${PORT} service=${SVC}"
remote_ssh "echo SSH_OK" >/dev/null && pass "E00 SSH baglantisi" || fail "E00 SSH"
remote_sudo "echo SUDO_OK" >/dev/null && pass "E00 sudo" || fail "E00 sudo"
phase_end

# -------------------------------------------------------------------------
phase_begin "01" "CI simulasyonu (restore + build + test + publish artifact)"
dotnet restore "$FIXTURE_TEST" --verbosity minimal
dotnet build "$FIXTURE_TEST" --no-restore --configuration Release /p:UseSharedCompilation=false --verbosity minimal
dotnet test "$FIXTURE_TEST" --no-build --configuration Release --verbosity minimal \
  && pass "E01 dotnet test" || fail "E01 dotnet test"

ART="$(mktemp -d)"
publish_artifact "$ART"
[ -f "${ART}/web/${DLL}" ] && pass "E01 artifact publish (${DLL})" || fail "E01 artifact publish"
export ARTIFACT_ROOT="$ART"
phase_end

# -------------------------------------------------------------------------
phase_begin "02" "Uzak host kurulumu (setup-remote-host + nginx + systemd)"
remote_sudo "systemctl stop '${SVC}-blue' '${SVC}-green' 2>/dev/null || true"
remote_sudo "rm -rf '${DD}-blue' '${DD}-green'"
bash "$SC/setup-remote-host.sh" && pass "E02 setup-remote-host" || fail "E02 setup-remote-host"
[ "$(active_color)" = "blue" ] && pass "E02 baslangic active=blue" || fail "E02 active=$(active_color)"
phase_end

# -------------------------------------------------------------------------
phase_begin "03" "ensure-infra (migration marker)"
bash "$ENSURE_E2E" && pass "E03 ensure-infra-e2e" || fail "E03 ensure-infra-e2e"
remote_ssh "[ -f /var/lib/cicd-e2e-migration.marker ]" \
  && pass "E03 migration marker uzakta" || fail "E03 migration marker"
phase_end

# -------------------------------------------------------------------------
phase_begin "04" "Deploy v1 (artifact -> idle -> restart -> health -> switch)"
pipeline_deploy_cycle "1" && pass "E04 deploy v1 pipeline" || fail "E04 deploy v1 pipeline"
[ "$(active_color)" = "green" ] && pass "E04 active=green" || fail "E04 active=$(active_color)"
VER="$(public_health_version)"
[ "$VER" = "1" ] && pass "E04 public health version=1" || fail "E04 public version=${VER:-empty}"
phase_end

# -------------------------------------------------------------------------
phase_begin "05" "verify-health.sh (public URL + status=ok)"
bash "$VERIFY" "http://${HOST}:${PORT}" /health 3 2 \
  && pass "E05 verify-health public" || fail "E05 verify-health public"
phase_end

# -------------------------------------------------------------------------
phase_begin "06" "health-active (aktif renk socket)"
bash "$SC/pipeline.sh" health-active && pass "E06 health-active" || fail "E06 health-active"
phase_end

# -------------------------------------------------------------------------
phase_begin "07" "Deploy v2 (APP_ENV ile, blue-green ikinci renk)"
pipeline_deploy_cycle "2" && pass "E07 deploy v2 pipeline" || fail "E07 deploy v2 pipeline"
[ "$(active_color)" = "blue" ] && pass "E07 active=blue" || fail "E07 active=$(active_color)"
VER="$(public_health_version)"
[ "$VER" = "2" ] && pass "E07 public health version=2" || fail "E07 public version=${VER:-empty}"
phase_end

# -------------------------------------------------------------------------
phase_begin "08" "publish-source v3 (build_from_source modu)"
export APP_ENV="DEPLOY_VERSION=3"
export GIT_SHA="e2e-src-3" DEPLOYED_BY="e2e-full" DEPLOY_NOTE="publish-source-v3"
bash "$SC/pipeline.sh" publish-source
bash "$SC/pipeline.sh" write-env
bash "$SC/pipeline.sh" write-info
bash "$SC/pipeline.sh" restart
if ! bash "$SC/pipeline.sh" health; then
  dump_unit_logs "green"
  die "E08 publish-source health"
fi
bash "$SC/pipeline.sh" switch || die "E08 publish-source switch"
pass "E08 publish-source v3"
[ "$(active_color)" = "green" ] && pass "E08 active=green" || fail "E08 active=$(active_color)"
VER="$(public_health_version)"
[ "$VER" = "3" ] && pass "E08 public health version=3" || fail "E08 public version=${VER:-empty}"
phase_end

# -------------------------------------------------------------------------
phase_begin "09" "Rollback (previous_folder -> v2)"
bash "$SC/pipeline.sh" rollback && pass "E09 rollback" || fail "E09 rollback"
[ "$(active_color)" = "blue" ] && pass "E09 active=blue after rollback" || fail "E09 active=$(active_color)"
VER="$(public_health_version)"
[ "$VER" = "2" ] && pass "E09 public health version=2 after rollback" || fail "E09 public version=${VER:-empty}"
phase_end

# -------------------------------------------------------------------------
phase_begin "10" "Saglik basarisiz -> switch yapilmaz (aktif renk korunur)"
ACTIVE_BEFORE="$(active_color)"
if [ "$ACTIVE_BEFORE" = "blue" ]; then
  IDLE_UNIT="${SVC}-green"
else
  IDLE_UNIT="${SVC}-blue"
fi
remote_sudo "systemctl stop '${IDLE_UNIT}'"
sleep 2
if bash "$SC/pipeline.sh" health; then
  fail "E10 sagliksiz idle ile gecmemeli"
else
  pass "E10 health fail (beklenen)"
fi
[ "$(active_color)" = "$ACTIVE_BEFORE" ] && pass "E10 active degismedi" || fail "E10 active degisti"
remote_sudo "systemctl start '${IDLE_UNIT}'"
sleep 3
remote_sudo "systemctl restart '${IDLE_UNIT}'"
sleep 2
bash "$SC/pipeline.sh" health && pass "E10 idle yeniden ayakta" || fail "E10 idle start"
phase_end

# -------------------------------------------------------------------------
phase_begin "11" "Denetim: .deploy-info + upstream tutarliligi"
INFO="$(remote_ssh "cat '${DD}-blue/.deploy-info' 2>/dev/null | head -1")"
echo "$INFO" | grep -q 'deploy_time=' && pass "E11 .deploy-info blue" || fail "E11 .deploy-info"
UP="$(remote_ssh "grep -o '${SVC}-[a-z]*' /etc/nginx/cicd/${SVC}-upstream.conf | head -1")"
CUR="$(active_color)"
echo "$UP" | grep -q "${SVC}-${CUR}" && pass "E11 upstream tutarli" || fail "E11 upstream=${UP} active=${CUR}"
phase_end

# -------------------------------------------------------------------------
phase_begin "12" "SSH_KNOWN_HOSTS zorunluluk (MITM)"
unset SSH_KNOWN_HOSTS
if DEPLOY_TARGET=remote SSH_HOST="$HOST" SSH_USER="$SIM_USER" \
   SSH_PRIVATE_KEY="$(cat "$KEYDIR/deploy_key")" \
   bash -c 'source "'"$SC"'/ssh-remote.sh"; ssh_remote_init' 2>/dev/null; then
  fail "E12 SSH_KNOWN_HOSTS bosken reddedilmeli"
else
  pass "E12 SSH_KNOWN_HOSTS bos -> reddedildi"
fi
export SSH_KNOWN_HOSTS="$(cat "$KEYDIR/known_hosts")"
phase_end

# -------------------------------------------------------------------------
TOTAL=$(( $(date +%s) - E2E_START ))
echo ""
echo "============================================="
echo "E2E TOPLAM SURE / TOTAL TIME: ${TOTAL}s"
if [ "$RC" -eq 0 ]; then
  echo "E2E FULL: TUM ASAMALAR GECTI"
else
  echo "E2E FULL: BASARISIZ"
fi
echo "============================================="
rm -rf "$ART"
exit "$RC"
