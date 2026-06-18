#!/usr/bin/env bash
# Engine backlog + throughput monitor — run this in a second terminal WHILE the
# k6 load test runs. It answers the real question: "is the engine keeping up, or
# are jobs piling up?"
#
#   jobs           pending jobs the job-executor still has to run (async steps,
#                  timers, retries). Should stay flat/low. If it climbs steadily
#                  through the run, the engine is FALLING BEHIND → jobs delayed.
#   running        process instances currently in-flight (e.g. waiting on a user
#                  task). Grows as you submit; should plateau, not run away.
#   history_total  cumulative instances ever started — the (+N/s) is your real
#                  end-to-end throughput.
#
# Usage:
#   ENGINE_URL=https://platform-qa-engine.onrender.com \
#   ENGINE_BASIC=admin:admin TENANT_ID=loadtest ./monitor.sh
#
# Auth: set ENGINE_BASIC="user:pass" (curl -u) OR ENGINE_AUTH="Bearer <jwt>".
# The caller must be privileged (parent_cluster / camunda-admin) to read counts
# for an arbitrary X-Tenant-Id.
set -euo pipefail

ENGINE_URL="${ENGINE_URL:-${BASE_URL:-http://localhost:8080}}"; ENGINE_URL="${ENGINE_URL%/}"
TENANT_ID="${TENANT_ID:-loadtest-tenant}"
PROC_KEY="${PROC_KEY:-FormSubmissionIntakeProcess}"
INTERVAL="${INTERVAL:-5}"

auth=()
if   [[ -n "${ENGINE_BASIC:-}" ]]; then auth=(-u "${ENGINE_BASIC}")
elif [[ -n "${ENGINE_AUTH:-}"  ]]; then auth=(-H "Authorization: ${ENGINE_AUTH}")
fi
hdr=(-H "X-Tenant-Id: ${TENANT_ID}")

# GET /engine-rest/<path>, extract the integer "count" field (no jq dependency).
count() {
  curl -fsS "${auth[@]}" "${hdr[@]}" "${ENGINE_URL}/engine-rest/$1" 2>/dev/null \
    | sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
}

printf '%-10s %8s %10s %14s %10s\n' 'time' 'jobs' 'running' 'history_total' 'rate/s'
prev=''
while true; do
  jobs=$(count 'job/count' || true);                                                  jobs=${jobs:-?}
  run=$(count "process-instance/count?processDefinitionKey=${PROC_KEY}" || true);      run=${run:-?}
  hist=$(count "history/process-instance/count?processDefinitionKey=${PROC_KEY}" || true); hist=${hist:-?}
  rate='-'
  if [[ "$hist" =~ ^[0-9]+$ && "$prev" =~ ^[0-9]+$ ]]; then rate=$(( (hist - prev) / INTERVAL )); fi
  [[ "$hist" =~ ^[0-9]+$ ]] && prev="$hist"
  printf '%-10s %8s %10s %14s %10s\n' "$(date +%H:%M:%S)" "$jobs" "$run" "$hist" "$rate"
  sleep "$INTERVAL"
done
