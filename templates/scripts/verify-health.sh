#!/usr/bin/env bash
#
# CI/CD Blueprint - servis saglik kontrolu / service health check
#
# Verilen taban adres icin sirasiyla dener / tries in order for a base URL:
#   1) <base>/health -> {"status":"ok"} icerir mi / contains it
#   2) <base>/health -> HTTP 200
#   3) <base>/        -> HTTP 200
# Herhangi biri olumluysa servis saglikli sayilir.
# Service is considered healthy if any of these succeeds.
#
# Kullanim / Usage:
#   bash verify-health.sh <base_url> [health_path] [max_attempts] [sleep_seconds]

set -euo pipefail

BASE_URL="${1:?taban adres gerekli / base url required}"
HEALTH_PATH="${2:-/health}"
MAX_ATTEMPTS="${3:-12}"
SLEEP_SECONDS="${4:-5}"

BASE_URL="${BASE_URL%/}"
HEALTH_PATH="/${HEALTH_PATH#/}"

check_service_up() {
  local body status

  body="$(curl -fsS --max-time 10 "${BASE_URL}${HEALTH_PATH}" 2>/dev/null || true)"
  if printf '%s' "$body" | grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    echo "kontrol / check: ${HEALTH_PATH} status=ok"
    return 0
  fi

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE_URL}${HEALTH_PATH}" 2>/dev/null || echo 000)"
  if [ "$status" = "200" ]; then
    echo "kontrol / check: ${HEALTH_PATH} 200"
    return 0
  fi

  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE_URL}/" 2>/dev/null || echo 000)"
  if [ "$status" = "200" ]; then
    echo "kontrol / check: / 200"
    return 0
  fi

  return 1
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if check_service_up; then
    echo "saglikli / healthy (${attempt}/${MAX_ATTEMPTS}): ${BASE_URL}"
    exit 0
  fi
  echo "bekleniyor / waiting (${attempt}/${MAX_ATTEMPTS}), ${SLEEP_SECONDS}s..."
  sleep "$SLEEP_SECONDS"
done

echo "saglik kontrolu basarisiz / health check failed: ${BASE_URL}"
exit 1
