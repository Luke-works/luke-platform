#!/usr/bin/env bash
# Best-effort seed for the load test: creates a Camunda tenant, a form
# definition, and publishes v1 — then prints the TENANT_ID / FORM_CODE to feed
# into k6. Idempotent-ish: re-running makes a fresh form (new code).
#
# Requires: curl, jq. (The k6 harness itself needs neither — only this seeder.)
#
# Usage:
#   BASE_URL=https://platform-qa-engine.onrender.com \
#   ENGINE_URL=https://platform-qa-engine.onrender.com \
#   ENGINE_BASIC=admin:admin TENANT_ID=loadtest \
#   AUTH_HEADER="Bearer <act-as-user-jwt>"  ./setup.sh
#
# If your staged engine runs with the auth gateway DISABLED (jwks unset), the
# X-Tenant-Id header is trusted and you can omit AUTH_HEADER.
set -euo pipefail
command -v jq >/dev/null || { echo "jq is required for setup.sh"; exit 1; }

BASE_URL="${BASE_URL:-http://localhost:8082}";  BASE_URL="${BASE_URL%/}"
ENGINE_URL="${ENGINE_URL:-http://localhost:8080}"; ENGINE_URL="${ENGINE_URL%/}"
TENANT_ID="${TENANT_ID:-loadtest-tenant}"
USER_ID="${USER_ID:-loadtest-user}"

api=(-H "Content-Type: application/json" -H "X-Tenant-Id: ${TENANT_ID}" -H "X-User-Id: ${USER_ID}")
[[ -n "${AUTH_HEADER:-}" ]] && api+=(-H "Authorization: ${AUTH_HEADER}")

eng=(-H "Content-Type: application/json")
if   [[ -n "${ENGINE_BASIC:-}" ]]; then eng+=(-u "${ENGINE_BASIC}")
elif [[ -n "${ENGINE_AUTH:-}"  ]]; then eng+=(-H "Authorization: ${ENGINE_AUTH}")
fi

echo "1) ensure Camunda tenant '${TENANT_ID}' exists (best-effort)…"
curl -sS "${eng[@]}" -X POST "${ENGINE_URL}/engine-rest/tenant/create" \
  -d "{\"id\":\"${TENANT_ID}\",\"name\":\"Load Test\"}" -o /dev/null -w "   -> HTTP %{http_code}\n" || true

echo "2) create form definition…"
form=$(curl -fsS "${api[@]}" -X POST "${BASE_URL}/api/form-definitions" \
  -d '{"name":"Load Test Form","description":"throwaway form for capacity testing"}')
FORM_ID=$(echo "$form"   | jq -r '.id')
FORM_CODE=$(echo "$form" | jq -r '.code')
echo "   -> id=${FORM_ID} code=${FORM_CODE}"

echo "3) check in + publish v1…"
schema='{"title":"Load Test","fields":[{"key":"note","type":"text","label":"Note"},{"key":"amount","type":"number","label":"Amount"}]}'
curl -fsS "${api[@]}" -X POST "${BASE_URL}/api/form-definitions/${FORM_ID}/versions" \
  -d "{\"schema\":$(jq -Rs . <<<"$schema"),\"publish\":true}" -o /dev/null -w "   -> HTTP %{http_code}\n"

cat <<EOF

✅ seeded. Run the load test with:

   k6 run -e BASE_URL=${BASE_URL} -e ENGINE_URL=${ENGINE_URL} \\
          -e TENANT_ID=${TENANT_ID} -e FORM_CODE=${FORM_CODE} \\
          ${AUTH_HEADER:+-e AUTH_HEADER="${AUTH_HEADER}" }-e MAX_RATE=50 \\
          k6/submit-flow.js

   # and in another terminal:
   ENGINE_URL=${ENGINE_URL} ${ENGINE_BASIC:+ENGINE_BASIC=${ENGINE_BASIC} }TENANT_ID=${TENANT_ID} ./monitor.sh
EOF
