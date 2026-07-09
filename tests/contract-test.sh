#!/usr/bin/env bash
# Sozlesme testleri: pipeline yardimcilari, write-env, coklu servis, rollback fazlari.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SC="$REPO/templates/scripts"
CICD="/etc/nginx/cicd"
RC=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; RC=1; }

BIN="$(mktemp -d)"
WORK="$(mktemp -d)"

cat > "$BIN/nginx" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-t" ]; then
  if [ "${NGINX_T_FAIL:-0}" = "1" ]; then echo "nginx: TEST FAIL (mock)"; exit 1; fi
  echo "nginx: ok (mock)"; exit 0
fi
echo "nginx reload (mock)"; exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/systemctl"
printf '#!/usr/bin/env bash\necho 200\n'  > "$BIN/curl"
chmod +x "$BIN/nginx" "$BIN/systemctl" "$BIN/curl"
export PATH="$BIN:$PATH"
export DEPLOY_TARGET=local

mkdir -p "$CICD"
init_svc(){
  local svc="$1" dd="$2" col="$3"
  mkdir -p "${dd}-blue" "${dd}-green"
  touch "${dd}-blue/app.dll" "${dd}-green/app.dll"
  printf 'upstream cicd_%s { server unix:/run/cicd/%s-%s.sock; }\n' "$svc" "$svc" "$col" > "${CICD}/${svc}-upstream.conf"
  printf '%s\n' "$col" > "${CICD}/${svc}.active"
}

echo "================ CONTRACT TEST ================"

# C01 write-env bos APP_ENV atlanir
init_svc web "${WORK}/web" blue
OUT="$(DEPLOY_TARGET=local SERVICES="web|c|${WORK}/web|web|http://127.0.0.1:5001/health" \
  bash "$SC/pipeline.sh" write-env 2>&1)" || true
echo "$OUT" | grep -q "bos, atlaniyor\|empty, skipped" \
  && pass "C01 write-env bos APP_ENV skip" || fail "C01 write-env skip"

# C02 write-env APP_ENV yazar (idle renk = blue, active = green)
init_svc web "${WORK}/web2" green
APP_ENV=$'FOO=bar\nConnectionStrings__Default=Server=x;Password=y=z'
OUT="$(DEPLOY_TARGET=local APP_ENV="$APP_ENV" \
  SERVICES="web|c|${WORK}/web2|web|http://127.0.0.1:5001/health" \
  bash "$SC/pipeline.sh" write-env 2>&1)" || true
echo "$OUT" | grep -q 'gizli ortam yazildi\|secret env written' \
  && grep -q 'FOO=bar' "${WORK}/web2-blue/.env" \
  && grep -q 'Password=y=z' "${WORK}/web2-blue/.env" \
  && pass "C02 write-env cok satir + esittir" || fail "C02 write-env icerik ($OUT)"

# C03 write-info alanlari (idle renk = blue, active = green)
GIT_SHA=abc DEPLOYED_BY=tester DEPLOY_NOTE=note \
DEPLOY_TARGET=local SERVICES="web|c|${WORK}/web2|web|http://127.0.0.1:5001/health" \
  bash "$SC/pipeline.sh" write-info >/dev/null 2>&1
grep -q 'commit=abc' "${WORK}/web2-blue/.deploy-info" \
  && grep -q 'deployed_by=tester' "${WORK}/web2-blue/.deploy-info" \
  && pass "C03 write-info alanlari" || fail "C03 write-info"

# C04 coklu servis validate — ikinci satir bos name reddedilir
BAD_MULTI="web|c|${WORK}/a|a|http://127.0.0.1:5001/health
|c|${WORK}/b|b|http://127.0.0.1:5002/health"
if DEPLOY_TARGET=local SERVICES="$BAD_MULTI" bash "$SC/pipeline.sh" health >/dev/null 2>&1; then
  fail "C04 coklu servis bos name kabul edilmemeli"
else
  pass "C04 coklu servis validation"
fi

# C05 health-active aktif renk socket
init_svc ha "${WORK}/ha" blue
DEPLOY_TARGET=local SERVICES="web|c|${WORK}/ha|ha|http://127.0.0.1:5003/health" \
  bash "$SC/pipeline.sh" health-active >/dev/null 2>&1 \
  && pass "C05 health-active" || fail "C05 health-active"

# C06 rollback faz1 — DLL yoksa iptal (state-test T6 ile ayni mantik)
init_svc rb "${WORK}/rb" green
rm -rf "${WORK}/rb-blue"
if DEPLOY_TARGET=local SERVICES="web|c|${WORK}/rb|rb|http://127.0.0.1:5004/health" \
  bash "$SC/pipeline.sh" rollback >/dev/null 2>&1; then
  fail "C06 rollback DLL yokken olmamali"
else
  pass "C06 rollback DLL guard"
fi

# C07 ensure-infra local migration (remote runner'da DB'ye baglanir — E2E'de test edilir)
EF_PROJECT="$REPO/tests/fixtures/CicdFixture.Data/CicdFixture.Data.csproj"
EF_STARTUP="$REPO/tests/fixtures/CicdFixture.Web/CicdFixture.Web.csproj"
DB="/tmp/cicd-contract-local.db"
rm -f "$DB"
DEPLOY_TARGET=local EF_PROJECT="$EF_PROJECT" EF_STARTUP_PROJECT="$EF_STARTUP" \
  APP_ENV="ConnectionStrings__DefaultConnection=Data Source=${DB}" \
  bash "$SC/ensure-infra.sh" >/dev/null 2>&1 \
  && [ -f "$DB" ] \
  && pass "C07 ensure-infra local migration" || fail "C07 ensure-infra local"

# C08 pipeline usage health-active komutu
USAGE="$(bash "$SC/pipeline.sh" 2>&1 || true)"
echo "$USAGE" | grep -q 'health-active' \
  && pass "C08 usage health-active listelenir" || fail "C08 usage"

# C09 setup-host.sh SERVICES zorunlu
if sudo SERVICES= bash "$SC/setup-host.sh" >/dev/null 2>&1; then
  fail "C09 setup-host SERVICES zorunlu degil mi"
else
  pass "C09 setup-host SERVICES guard"
fi

echo "============================================="
rm -rf "$BIN" "$WORK" \
  "${CICD}/web.active" "${CICD}/web-upstream.conf" \
  "${CICD}/web2.active" "${CICD}/web2-upstream.conf" \
  "${CICD}/ha.active" "${CICD}/ha-upstream.conf" \
  "${CICD}/rb.active" "${CICD}/rb-upstream.conf" 2>/dev/null
[ "$RC" -eq 0 ] && echo "CONTRACT: TUM TESTLER GECTI" || echo "CONTRACT: BASARISIZ"
exit "$RC"
