#!/usr/bin/env bash
# Statik dogrulama: bash -n + shellcheck + actionlint
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SC="$ROOT/templates/scripts"
RC=0
TMP="$(mktemp -d)"

echo "=== bash -n ==="
for f in "$SC"/*.sh "$ROOT"/tests/*.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  sed 's/\r$//' "$f" > "$TMP/$b"
  bash -n "$TMP/$b" && echo "OK  $b" || { echo "FAIL $b"; RC=1; }
done

echo "=== shellcheck (templates/scripts only) ==="
if command -v shellcheck >/dev/null 2>&1; then
  SC_FILES=()
  for f in "$SC"/*.sh; do
    b="$(basename "$f")"
    sed 's/\r$//' "$f" > "$TMP/$b"
    SC_FILES+=("$TMP/$b")
  done
  shellcheck -x -e SC1091 "${SC_FILES[@]}" && echo "shellcheck CLEAN" || { echo "shellcheck FAIL"; RC=1; }
else
  echo "shellcheck yok (atlandi)"
fi

echo "=== actionlint ==="
if command -v actionlint >/dev/null 2>&1; then
  WF="$TMP/wf"; mkdir -p "$WF"
  shopt -s nullglob
  for f in "$ROOT"/templates/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yml; do
    sed 's/\r$//' "$f" > "$WF/$(basename "$f")"
  done
  shopt -u nullglob
  WF_FILES=("$WF"/*.yml)
  if [ ${#WF_FILES[@]} -eq 0 ] || [ ! -f "${WF_FILES[0]}" ]; then
    echo "actionlint: workflow dosyasi yok (atlandi)"
  elif actionlint -ignore "could not read reusable workflow file" "${WF_FILES[@]}"; then
    echo "actionlint CLEAN"
  else
    echo "actionlint FAIL"; RC=1
  fi
else
  echo "actionlint yok (atlandi)"
fi

echo "=== ensure-infra (skip + migrate) ==="
ENSURE="$SC/ensure-infra.sh"
FIXTURE_DATA="$ROOT/tests/fixtures/CicdFixture.Data/CicdFixture.Data.csproj"
FIXTURE_WEB="$ROOT/tests/fixtures/CicdFixture.Web/CicdFixture.Web.csproj"
E2E_DB="$TMP/cicd-ensure-test.db"
rm -f "$E2E_DB"

if EF_PROJECT= SERVICES= bash "$ENSURE" 2>&1 | grep -q "skipping migration"; then
  echo "OK  ensure-infra skip (EF_PROJECT bos)"
else
  echo "FAIL ensure-infra skip"; RC=1
fi

if EF_PROJECT="$FIXTURE_DATA" EF_STARTUP_PROJECT="$FIXTURE_WEB" \
   APP_ENV="ConnectionStrings__DefaultConnection=Data Source=${E2E_DB}" \
   bash "$ENSURE" >/dev/null 2>&1 \
   && [ -f "$E2E_DB" ]; then
  echo "OK  ensure-infra EF migrate"
else
  echo "FAIL ensure-infra EF migrate"; RC=1
fi

echo "============================================="
[ "$RC" -eq 0 ] && echo "STATIK: TEMIZ" || echo "STATIK: SORUN"
rm -rf "$TMP"
exit "$RC"
