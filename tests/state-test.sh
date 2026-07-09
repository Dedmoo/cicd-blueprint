#!/usr/bin/env bash
# STATE-01 fonksiyonel testi — pipeline.sh blue-green state mantigi (local mock).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SC="$REPO/templates/scripts"
CICD="/etc/nginx/cicd"
RC=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; RC=1; }

BIN="$(mktemp -d)"
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
WORK="$(mktemp -d)"

init_svc(){
  local svc="$1" dd="$2" col="$3"
  mkdir -p "${dd}-blue" "${dd}-green"
  touch "${dd}-blue/c.dll" "${dd}-green/c.dll"
  printf 'upstream cicd_%s { server unix:/run/cicd/%s-%s.sock; }\n' "$svc" "$svc" "$col" > "${CICD}/${svc}-upstream.conf"
  printf '%s\n' "$col" > "${CICD}/${svc}.active"
}
active(){ cat "${CICD}/$1.active" 2>/dev/null; }

echo "================ STATE-01 TEST ================"

init_svc web "${WORK}/web" blue
[ "$(active web)" = "blue" ] && pass "T1 init" || fail "T1"

SERVICES="web|c|${WORK}/web|web|http://127.0.0.1:5001/health" bash "$SC/pipeline.sh" switch >/dev/null 2>&1
[ "$(active web)" = "green" ] && pass "T2 switch->green" || fail "T2 ($(active web))"

SERVICES="web|c|${WORK}/web|web|http://127.0.0.1:5001/health" bash "$SC/pipeline.sh" switch >/dev/null 2>&1
[ "$(active web)" = "blue" ] && pass "T3 switch->blue" || fail "T3 ($(active web))"

init_svc web "${WORK}/web" blue
NGINX_T_FAIL=1 SERVICES="web|c|${WORK}/web|web|http://127.0.0.1:5001/health" bash "$SC/pipeline.sh" switch >/dev/null 2>&1
[ "$(active web)" = "blue" ] && pass "T4 reload-fail state korundu" || fail "T4 ($(active web))"
grep -q 'web-blue' "${CICD}/web-upstream.conf" && pass "T4b reload-fail upstream geri alindi" || fail "T4b upstream"

init_svc blue-web "${WORK}/blueapp" green
SERVICES="blue-web|c|${WORK}/blueapp|blue-web|http://127.0.0.1:5002/health" bash "$SC/pipeline.sh" switch >/dev/null 2>&1
[ "$(active blue-web)" = "blue" ] && pass "T5 isimde-blue" || fail "T5 ($(active blue-web))"

init_svc a "${WORK}/a" green
init_svc b "${WORK}/b" green
rm -rf "${WORK}/b-blue"
SVC_MULTI="a|c|${WORK}/a|a|http://127.0.0.1:5001/health
b|c|${WORK}/b|b|http://127.0.0.1:5002/health"
SERVICES="$SVC_MULTI" bash "$SC/pipeline.sh" rollback >/dev/null 2>&1 || rbrc=$?
rbrc=${rbrc:-0}
[ "$rbrc" -ne 0 ] && pass "T6a rollback iptal" || fail "T6a"
{ [ "$(active a)" = "green" ] && [ "$(active b)" = "green" ]; } && pass "T6b state degismedi" || fail "T6b"

mkdir -p "${WORK}/b-blue"
SERVICES="$SVC_MULTI" bash "$SC/pipeline.sh" rollback >/dev/null 2>&1 || rbrc2=$?
rbrc2=${rbrc2:-0}
[ "$rbrc2" -ne 0 ] && pass "T6c bos dizin (DLL yok) rollback iptal" || fail "T6c bos dizin rollback olmamali"

init_svc a "${WORK}/a" green
init_svc b "${WORK}/b" green
SERVICES="$SVC_MULTI" bash "$SC/pipeline.sh" rollback >/dev/null 2>&1
{ [ "$(active a)" = "blue" ] && [ "$(active b)" = "blue" ]; } && pass "T7 coklu rollback" || fail "T7"

echo "============================================="
[ "$RC" -eq 0 ] && echo "STATE: TUM TESTLER GECTI" || echo "STATE: BASARISIZ"
rm -rf "$BIN" "$WORK" "${CICD}"/web.active "${CICD}"/web-upstream.conf \
  "${CICD}"/blue-web.active "${CICD}"/blue-web-upstream.conf \
  "${CICD}"/a.active "${CICD}"/a-upstream.conf "${CICD}"/b.active "${CICD}"/b-upstream.conf 2>/dev/null
exit "$RC"
