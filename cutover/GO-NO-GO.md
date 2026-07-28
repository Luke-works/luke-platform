# Production cutover — GO / NO-GO checklist

One scannable page for the go/no-go call. Every box must be **✅** to proceed. Any ❌ in a **🔴 hard gate**
section = **NO-GO**. Full context for each item is in `RUNBOOK.md` (section refs in parentheses).

**Cutover date/window:** ____________  **Decision owner:** ____________  **Rollback owner:** ____________

---

## 🔴 Hard gates (any ❌ → NO-GO)

### A. Prod deploy path exists (RUNBOOK §0, §1a)
- [ ] `luke-prod-db` provisioned (dedicated instance, backups on), separate from `luke-nonprod-db`.
- [ ] A prod deploy path exists for **all 6 services** — either `platform-prod-*` enabled, or standalone prod
      blueprints created for auth-engine / consumer-ui / file-proxy.
- [ ] `luke-file-proxy` (and any other) has a **`main`** (prod) branch.

### B. Code promoted to prod (RUNBOOK §1b)
- [ ] `develop → main` merged + CI-green for: core-engine, auth-engine, file-proxy, agents, core-ui, consumer-ui.
- [ ] Each repo's prod `main` tagged for rollback (`prod-cutover-YYYYMMDD`).

### C. Secrets set on prod (RUNBOOK §1c–1d)
- [ ] core-engine must-exist secrets present: `LUKE_EMBED_HMAC_SECRET` (real), `LUKE_SECRETS_KEYS_V1`,
      `LUKE_AUTH_GATEWAY_JWKS_URL`, `CAPABILITY_OPERATOR_USER`/`_PASSWORD`, `CAMUNDA_ADMIN_PASSWORD` (non-default), DB creds.
- [ ] auth-engine: `WORKOS_CLIENT_ID`/`WORKOS_API_KEY` (Production), signing key if `GATEWAY_REQUIRE_STABLE_KEY`.
- [ ] `GATEWAY_VOUCH_SECRET` set to the **same value** on core-engine + auth-engine.
- [ ] `SPRING_PROFILES_ACTIVE=postgres,prod` on the prod engine (only after the above) — and it **booted** (guards passed).
- [ ] UIs built with prod `VITE_API_BASE_URL`/`VITE_AUTH_API_URL`.

### D. Verification passed on prod (RUNBOOK §3.5–3.6, §4)
- [ ] `smoke-test.sh` exits **0** against prod (readiness UP; metrics 404 w/o token, 200 w/ token; `/api/users`
      401/403; public surface non-5xx).
- [ ] `../MASTER_TEST_SCRIPT.md` manual pass — every row ✅ (esp. tenant isolation, no admin/admin, public embed, password-change).

### E. Rollback ready (RUNBOOK §3.1, §5)
- [ ] Fresh `luke-prod-db` snapshot taken **immediately before** deploy; snapshot ID recorded: ____________.
- [ ] Rollback owner has `bad-deploy-rollback.md` + `disaster-recovery.md` open and knows the Flyway
      forward-only rule.

---

## 🟠 Strongly recommended (⚠️ if ❌ — document the risk, decide explicitly)

### F. Observability live (RUNBOOK §1e)
- [ ] Uptime monitor on prod readiness URLs → Slack.
- [ ] Sentry receiving prod backend + frontend events (`environment=prod`).
- [ ] Grafana Cloud + Alloy collector shipping prod metrics; `up{env="prod"}=1`; dashboards imported.
- [ ] Alert rules armed → `#alerts` (5xx spike, p95, Hikari pool, `up==0`).

### G. DR confidence (RUNBOOK §7)
- [ ] A `luke-prod-db` restore has been **rehearsed** at least once (currently: **not done** — this is a known gap).

---

## 🟡 Optional / non-gating

### H. WorkOS prod roles (RUNBOOK §1f, `../workos/PRODUCTION_ROLE_ROLLOUT.md`)
- [ ] 4 engine-mirrored roles created in Production + SSO/dsync assignment on. *(Arming step; 0 orgs today, no
      live consumer until engine #104 AC-3. Safe to skip for the first cutover.)*

---

## Decision

| Section | Status | Notes |
|---|---|---|
| A — Deploy path | ⬜ | |
| B — Code promoted | ⬜ | |
| C — Secrets | ⬜ | |
| D — Verification | ⬜ | |
| E — Rollback | ⬜ | |
| F — Observability | ⬜ | |
| G — DR rehearsed | ⬜ | |

**Call:**  ⬜ GO   ⬜ NO-GO   —  signed ____________  date ____________
