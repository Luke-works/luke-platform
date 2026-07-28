#!/usr/bin/env bash
# Post-deploy smoke test for the Luke fleet — a fast, automated "is it alive and serving safely?" gate.
#
# This complements ../MASTER_TEST_SCRIPT.md (the deep, manual, click-through-the-portals functional pass).
# This script is the 60-second automated gate you run IMMEDIATELY after a deploy, from any shell, before you
# hand off to a human for the manual pass. It only uses curl + POSIX shell (jq optional).
#
# Usage:
#   ENV=prod \
#   CORE_HOST=https://<core-host> \
#   GATEWAY_HOST=https://<gateway-host> \
#   FILE_PROXY_HOST=https://<file-proxy-host> \
#   AGENTS_HOST=https://<agents-host> \
#   CONSUMER_UI=https://<consumer-ui-host> \
#   CORE_UI=https://<core-ui-host> \
#   ./smoke-test.sh
#
# Optional:
#   METRICS_TOKEN=<token>   # if set, also asserts /actuator/prometheus is 200 WITH it (else just 404 WITHOUT)
#   PUBLIC_EMBED_URL=<url>  # a known public embed/form URL to assert the public surface serves (non-5xx)
#   TIMEOUT=10              # per-request seconds (default 10)
#
# Any host left unset is SKIPPED (reported), so you can run a partial check. Exit code is non-zero if any
# executed check fails — wire it into a deploy pipeline as a gate.

set -uo pipefail
TIMEOUT="${TIMEOUT:-10}"
ENVNAME="${ENV:-unknown}"
PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""

c() { curl -sS -m "$TIMEOUT" -o /dev/null -w "%{http_code}" "$@" 2>/dev/null; }        # -> status code
cbody() { curl -sS -m "$TIMEOUT" "$@" 2>/dev/null; }                                    # -> body

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s  \033[31m(%s)\033[0m\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES\n    - $1 ($2)"; }
skip() { printf '  \033[33m–\033[0m %s  (skipped: %s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }

# assert_status <name> <url> <expected-code>[,<code>...]
assert_status() {
  local name="$1" url="$2" want="$3" got
  got="$(c "$url")"
  case ",$want," in
    *",$got,"*) ok "$name → $got" ;;
    *)          bad "$name" "want $want, got $got  [$url]" ;;
  esac
}

# assert_body_contains <name> <url> <needle>
assert_body_contains() {
  local name="$1" url="$2" needle="$3" body
  body="$(cbody "$url")"
  if printf '%s' "$body" | grep -q "$needle"; then ok "$name → contains '$needle'";
  else bad "$name" "body missing '$needle'  [$url]"; fi
}

echo "════════════════════════════════════════════════════════════"
echo "  Luke fleet smoke test — env=$ENVNAME  ($(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo now))"
echo "════════════════════════════════════════════════════════════"

# ── 1. Liveness + readiness ────────────────────────────────────────────────
echo; echo "[1] Liveness / readiness"
if [ -n "${CORE_HOST:-}" ]; then
  assert_status       "core-engine readiness"  "$CORE_HOST/actuator/health/readiness" "200"
  assert_body_contains "core-engine status UP" "$CORE_HOST/actuator/health/readiness" '"status":"UP"'
else skip "core-engine" "CORE_HOST unset"; fi

if [ -n "${GATEWAY_HOST:-}" ]; then
  # gateway readiness includes core-engine reachability + WorkOS verifier — a strong single signal
  assert_status       "auth-engine (gateway) readiness" "$GATEWAY_HOST/actuator/health/readiness" "200"
  assert_body_contains "auth-engine status UP"          "$GATEWAY_HOST/actuator/health/readiness" '"status":"UP"'
else skip "auth-engine" "GATEWAY_HOST unset"; fi

if [ -n "${FILE_PROXY_HOST:-}" ]; then
  assert_status       "file-proxy health" "$FILE_PROXY_HOST/actuator/health" "200"
else skip "file-proxy" "FILE_PROXY_HOST unset"; fi

if [ -n "${AGENTS_HOST:-}" ]; then
  assert_status "agents health" "$AGENTS_HOST/health" "200"
else skip "agents" "AGENTS_HOST unset"; fi

if [ -n "${CONSUMER_UI:-}" ]; then
  assert_status "consumer-ui root" "$CONSUMER_UI/" "200"
else skip "consumer-ui" "CONSUMER_UI unset"; fi

if [ -n "${CORE_UI:-}" ]; then
  assert_status "core-ui root" "$CORE_UI/" "200"
else skip "core-ui" "CORE_UI unset"; fi

# ── 2. Security posture (fail-CLOSED where it should) ───────────────────────
echo; echo "[2] Security posture"
# 2a. Metrics endpoint must NOT be public — 404 without a Bearer token (MetricsScrapeAuthFilter).
if [ -n "${CORE_HOST:-}" ]; then
  assert_status "core /actuator/prometheus locked (no token → 404)" "$CORE_HOST/actuator/prometheus" "404"
  if [ -n "${METRICS_TOKEN:-}" ]; then
    got="$(c -H "Authorization: Bearer $METRICS_TOKEN" "$CORE_HOST/actuator/prometheus")"
    [ "$got" = "200" ] && ok "core /actuator/prometheus opens WITH token → 200" \
                        || bad "core /actuator/prometheus with token" "want 200, got $got"
  else skip "core /actuator/prometheus with token" "METRICS_TOKEN unset"; fi
fi
# 2b. A protected API must reject anonymous access (auth is enforced, not open).
if [ -n "${CORE_HOST:-}" ]; then
  assert_status "core protected API rejects anon" "$CORE_HOST/api/users" "401,403"
fi

# ── 3. Public surface still serves (fail-OPEN where it should) ──────────────
echo; echo "[3] Public surface"
if [ -n "${PUBLIC_EMBED_URL:-}" ]; then
  # A real public embed/form URL should serve WITHOUT auth and WITHOUT a 5xx. 200/302/404-from-controller
  # are all "the app is handling it"; a 5xx or a connection failure is the real failure.
  got="$(c "$PUBLIC_EMBED_URL")"
  case "$got" in
    2*|3*|404) ok "public embed serves (no 5xx) → $got" ;;
    5*|000)    bad "public embed" "got $got (5xx / unreachable)  [$PUBLIC_EMBED_URL]" ;;
    *)         ok "public embed reachable → $got" ;;
  esac
else skip "public embed surface" "PUBLIC_EMBED_URL unset"; fi

# ── Summary ────────────────────────────────────────────────────────────────
echo; echo "════════════════════════════════════════════════════════════"
printf "  PASS=%d  FAIL=%d  SKIP=%d\n" "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf "  \033[31mFAILED checks:\033[0m"; printf "$FAILED_NAMES\n"
  echo "════════════════════════════════════════════════════════════"
  echo "  ❌ SMOKE TEST FAILED — do NOT proceed with the cutover / roll back."
  exit 1
fi
echo "════════════════════════════════════════════════════════════"
echo "  ✅ Smoke test passed. Proceed to the manual functional pass (../MASTER_TEST_SCRIPT.md)."
exit 0
