# Production cutover runbook — Luke fleet

How to take the Luke fleet live on **production** for the first time (or re-cut after a major change).
This is net-new — there is no existing prod-cutover runbook. It **references**, and does not duplicate, the
per-service operational runbooks in `luke-core-engine/docs/runbooks/` (DR, rollback, incident-triage, scaling).

> **Read the two blockers in §0 before planning a date.** As of 2026-07-27 the fleet **cannot** cut over to
> prod without infra + branch work that does not exist yet. This runbook documents both the prerequisites to
> *make* a cutover possible and the procedure to *run* it. Companion files: `smoke-test.sh` (automated
> post-deploy gate), `GO-NO-GO.md` (the sign-off checklist), `../MASTER_TEST_SCRIPT.md` (manual functional pass).

---

## 0. Blockers — the fleet is not prod-deployable today

**Blocker A — 3 of 6 services have no prod deploy path.**
- Prod deploys are meant to run from either the **`platform-prod-*`** blueprint set or the **standalone**
  service blueprints (`luke-platform/README.md` §Production).
- The `platform-prod-*` block in `luke-platform/render.yaml` is **DISABLED / commented out** (≈L832–865); it
  needs a dedicated **`luke-prod-db`**, the **Production WorkOS** project, and prod secrets before it can be enabled.
- **Standalone** prod blueprints exist only for `luke-core-engine` (`render.yaml`, `branch: main`),
  `luke-core-ui`, and `luke-agents`. **`luke-auth-engine`, `luke-consumer-ui`, and `luke-file-proxy` have no
  own `render.yaml`** — today they deploy *only* via the (non-prod) platform bundle.
- **`luke-file-proxy` has no `main` branch at all** (only `develop` + `qa`). Even the branch to deploy from
  doesn't exist.
- **→ ADDRESSED:** a complete, validated prod blueprint for **all 7 services** + a dedicated `luke-prod-db`
  now exists at **`../render.prod.yaml`** (inert — Render never auto-reads it). Blocker A is now an
  *activation* task (§1a), not a *build* task; `luke-file-proxy` still needs a `main` branch created (§1a).

**Blocker B — the entire hardening effort is unshipped to prod.**
- `main` = current prod. `origin/develop` is ahead of `origin/main` by **~187 (core-engine), 286 (consumer-ui),
  78 (auth-engine), 46 (agents), 42 (core-ui)** commits; file-proxy has no `main`. Everything from the
  enterprise-hardening backlog — tenant isolation, fail-closed admin password, Flyway schema ownership,
  graceful shutdown, gateway hardening, the OBS-2 metrics lock, OBS-4 Sentry, the `GATEWAY_VOUCH_SECRET`
  public-surface lock — lives on `develop` and is **live on dev/qa only**. Cutover's payload *is* promoting
  `develop → main` across all repos.

**Consequence:** a first prod cutover is a **project**, not a deploy. §1 is the prerequisite build; §2–§6 are
the actual cutover once §1 is done.

---

## 1. Prerequisites (build these before scheduling a cutover)

### 1a. Provision prod infrastructure
- [ ] Create **`luke-prod-db`** (dedicated Postgres, its own instance — NOT the shared `luke-nonprod-db`).
      Enable automated backups; confirm the retention matches the DR target (`docs/runbooks/README.md` says
      RPO ≤24h / RTO ≤2h — **and that a restore has never been rehearsed**; rehearse one, see §7).
- [ ] **Activate the prod blueprint.** `../render.prod.yaml` is a complete, validated 7-service prod
      definition + `luke-prod-db` (built for this — supersedes the partial disabled scaffold in
      `render.yaml`). Render only reads a file literally named `render.yaml`, so activate it via **a dedicated
      `prod-blueprint` branch** of luke-platform (whose `render.yaml` == that file) or **a separate prod repo**,
      connected as its own Render Blueprint (separate DB). See the file's header for the exact steps + the
      `sync:false` secrets to fill.
- [ ] Create a **`main` branch on `luke-file-proxy`** (and any other service missing one) off the tested
      `develop` tip — `render.prod.yaml` deploys file-proxy from `main`, which does not exist yet.
- [ ] Confirm the **Production WorkOS** project/env is the one wired into prod auth
      (`environment_01KTHG30DY4BN0EGDTA37J3195`).

### 1b. Promote code develop → main (coordinated, all repos)
Do this as a coordinated batch so prod isn't half-hardened. Order mirrors the runtime dependency (backends
before UIs). For each repo: open a `develop → main` PR, ensure CI is green, merge.
- [ ] `luke-core-engine`  `luke-auth-engine`  `luke-file-proxy`  `luke-agents`  (backends)
- [ ] `luke-core-ui`  `luke-consumer-ui`  (frontends — rebuild after backends' prod URLs are known)
- [ ] Tag each repo's merged `main` (e.g. `prod-cutover-YYYYMMDD`) so rollback has a named target.

### 1c. Set prod secrets (all Render `sync: false`) — per service
core-engine fails to boot under the `prod` profile if the **must-exist** ones are missing (by design).

| Service | MUST exist before prod boot | Also set (feature-gated; boots without, feature off) |
|---|---|---|
| **core-engine** | `LUKE_EMBED_HMAC_SECRET` (real, not `…-change-me`), `LUKE_SECRETS_KEYS_V1`, `LUKE_AUTH_GATEWAY_JWKS_URL`, `CAPABILITY_OPERATOR_USER` + `_PASSWORD`, `CAMUNDA_ADMIN_PASSWORD` (non-default), DB creds (`fromDatabase`) | `LUKE_INTERNAL_SHARED_SECRET`, `POSTMARK_*`, `EMAIL_DEFAULT_FROM`, `LUKE_SIGN_KEYSTORE_*`+`LUKE_SIGN_KEY_ALIAS`+`SIGN_PUBLIC_BASE_URL`, `LUKE_DOCSTORE_ACCESS_KEY`/`_SECRET_KEY`(+region), `VAPI_*`, `NANGO_SECRET_KEY`, **`GATEWAY_VOUCH_SECRET`**, **`MANAGEMENT_METRICS_TOKEN`**, **`SENTRY_DSN`**+`SENTRY_ENVIRONMENT=prod` |
| **auth-engine** | `WORKOS_CLIENT_ID`, `WORKOS_API_KEY` (Production), `GATEWAY_PRIVATE_KEY` (if `GATEWAY_REQUIRE_STABLE_KEY=true`) | `WORKOS_JWKS_URL`/`_ISSUER`/`_AUDIENCE` (optional), **`GATEWAY_VOUCH_SECRET`** (same value as core), **`MANAGEMENT_METRICS_TOKEN`**, **`SENTRY_DSN`**+`SENTRY_ENVIRONMENT=prod` |
| **file-proxy** | (none hard-fail) | `LUKE_DOCSTORE_ACCESS_KEY`/`_SECRET_KEY`, **`MANAGEMENT_METRICS_TOKEN`**, **`SENTRY_DSN`**+`SENTRY_ENVIRONMENT=prod` |
| **agents** | — | `GROQ_API_KEY` (else `/health/ready` 503), `OPENAI_API_KEY`/`AGENTS_BRAIN`, `REDIS_URL` (else per-instance rate limit), `DATABASE_URL` (`fromDatabase` in bundle) |
| **UIs** | `VITE_API_BASE_URL`/`VITE_AUTH_API_URL` (baked at build → prod backend URLs) | `VITE_SENTRY_DSN` |

> The **bold** vars (`GATEWAY_VOUCH_SECRET`, `MANAGEMENT_METRICS_TOKEN`, `SENTRY_DSN`/`VITE_SENTRY_DSN`) are
> from this session's hardening/observability work — they exist on `develop` and must be present on `main` (§1b)
> **and** set on the prod services. `GATEWAY_VOUCH_SECRET` must be the **same value** on core-engine and
> auth-engine (it locks the public surface to gateway-origin — see the sibling-of-D4 work). All three are
> default-lenient: unset = feature off, never a boot crash.

### 1d. Flip core-engine to the prod profile
- [ ] Set `SPRING_PROFILES_ACTIVE=postgres,prod` on the prod engine **only after 1c** is done. The `prod`
      profile arms the fail-fast guards (`InsecureKeyGuard`, `AuthHardeningGuard`, …). If a required secret is
      missing it will **intentionally refuse to start** — that's the guard working, not a bug.

### 1e. Turn observability on (so you can watch the cutover)
- [ ] Complete the observability runbook (`../observability/README.md`) for **prod**: uptime monitor,
      Sentry DSNs, Grafana Cloud + Alloy collector, alert rules. You want dashboards + paging **live before**
      you flip prod, not after.

### 1f. (Optional, non-gating) WorkOS prod roles
- [ ] Run `../workos/PRODUCTION_ROLE_ROLLOUT.md` if desired. This is an *arming* step (Production has 0 orgs →
      no blast radius) and is **not** a cutover gate. It has no live consumer until the engine's #104 AC-3 ships.

---

## 2. Come-up order (how the services must start)
Derived from the dependency graph (Flyway on boot, gateway readiness includes core reachability, UIs bake
backend URLs). On a cold prod bring-up, respect this order:

1. **`luke-prod-db`** reachable first.
2. **core-engine** — runs Flyway `luke_*` migrations (`baseline-on-migrate`, `ddl-auto:none`) + Camunda
   `ACT_*` schema-update + `BootCoordinator` advisory-locked initializers (RBAC/tenant/capability seed/BPMN).
   Creates its schema on first connect.
3. **file-proxy** + **agents** — file-proxy calls core's `/api/internal/**` (needs `LUKE_INTERNAL_SHARED_SECRET`
   + core up); agents needs its DB schema.
4. **auth-engine (gateway)** — readiness depends on core reachable + WorkOS configured + signing key ready.
5. **UIs** (core-ui, consumer-ui, portal) — last; they call the engine/gateway origins baked at build time.

> **Health-check paths** (set per service in the blueprint): core-engine `→ /actuator/health/readiness`
> (DB-aware, drains on shutdown); auth-engine `→ /actuator/health/liveness` (deliberately liveness-only so a
> core/WorkOS blip won't restart the gateway); file-proxy `→ /actuator/health`; agents `→ /health`; UIs static `/`.

---

## 3. Cutover procedure (the day-of steps)
Pre-req: §1 fully done, `GO-NO-GO.md` all-green, a maintenance window if there's existing prod data.

1. **Snapshot first.** Take a fresh `luke-prod-db` backup/snapshot and record its ID. This is your rollback
   floor (`docs/runbooks/disaster-recovery.md`).
2. **Announce** the window; freeze `main` merges for the duration.
3. **Deploy backends in order** (§2 steps 2–4). For each: trigger the prod deploy (Render manual deploy of the
   merged `main`/prod branch), wait for the service to report **healthy** on its probe path before moving on.
   - Watch the first core-engine boot logs for Flyway (`baseline-on-migrate` should skip V1 on an existing DB;
     on a brand-new prod DB it runs the baseline) and for the `prod`-profile guards passing.
4. **Deploy the UIs** (§2 step 5) — rebuilt against the prod backend URLs.
5. **Run the automated smoke test** against prod:
   ```bash
   ENV=prod \
     CORE_HOST=https://<prod-core> GATEWAY_HOST=https://<prod-gateway> \
     FILE_PROXY_HOST=https://<prod-file-proxy> AGENTS_HOST=https://<prod-agents> \
     CONSUMER_UI=https://<prod-consumer-ui> CORE_UI=https://<prod-core-ui> \
     METRICS_TOKEN=<the prod MANAGEMENT_METRICS_TOKEN> \
     PUBLIC_EMBED_URL=<a real public form/embed URL> \
     ./smoke-test.sh
   ```
   Must exit 0 (all readiness UP, metrics locked 404 without token / 200 with, `/api/users` 401/403, public
   surface serves non-5xx). If it fails → **do not proceed**, go to §5.
6. **Manual functional pass** — walk `../MASTER_TEST_SCRIPT.md` against prod (login, forms, email, tenant
   isolation, no admin/admin backdoor, public embed). This is the human gate the smoke test can't replace.
7. **Watch observability** for the first 30–60 min: Grafana 5xx/p95/Hikari dashboards, Sentry issue stream,
   uptime monitor green. Confirm alerts are armed (§1e).

---

## 4. Verify (definition of a successful cutover)
- [ ] `smoke-test.sh` exits 0 against prod.
- [ ] `MASTER_TEST_SCRIPT.md` manual pass — every row ✅.
- [ ] Grafana shows `up{env="prod"}=1` for all targets; no sustained 5xx; p95 within SLO.
- [ ] Sentry receiving events (backend + frontend), tagged `environment=prod`.
- [ ] A test tenant can log in, submit a form, and the follow-up (email/task) fires.
- [ ] Cross-tenant isolation holds (a user of Org A cannot see Org B).
- [ ] `admin/admin` is rejected; `/actuator/prometheus` is 404 without the token.

## 5. Rollback
Follow `luke-core-engine/docs/runbooks/bad-deploy-rollback.md`. In short:
- **Code-only regression:** Render → the service → **Deploys → Rollback** to the previous good deploy, or
  revert the offending commit on the prod branch and redeploy. Roll UIs back independently of backends.
- **Schema-involved:** Flyway is **forward-only / expand-contract** — do **not** hand-delete migration rows.
  Prefer a forward "contract/repair" migration; restore from the §3.1 snapshot only as a last resort
  (`docs/runbooks/disaster-recovery.md`). This is why §3.1 (snapshot first) is non-negotiable.
- **Gateway:** if the public-surface lock misbehaves, unset `GATEWAY_VOUCH_SECRET` on core+auth (default-open
  fallback) rather than rolling the whole deploy.

## 6. Post-cutover
- [ ] Unfreeze `main`; document the deployed tags.
- [ ] Update `luke-docs/reference/completeness.md` + `guide/fleet-map.md` status (dev/qa → prod-live).
- [ ] Schedule the first **DR restore rehearsal** (§7) if not already done.

## 7. Known risks / gaps to close (track these)
- **DR restore never rehearsed** (`docs/runbooks/README.md` L36-37) — RPO/RTO are targets, unproven. Rehearse
  a `luke-prod-db` restore into a scratch instance before you depend on it.
- **No CI/CD deploy automation** — every deploy is a manual Render action; there's no pipeline gating prod on
  the smoke test. Consider wiring `smoke-test.sh` into a post-deploy check.
- **Prod blueprints for auth-engine/consumer-ui/file-proxy are net-new** (Blocker A) — review them as
  carefully as code; a wrong `ALLOWED_ORIGINS`/`VITE_API_BASE_URL` silently breaks the fleet.
- **Health-probe path differs** between the standalone core blueprint (`/actuator/health/readiness`) and the
  platform bundle (`/actuator/health`). For prod, readiness (DB-aware) is correct for drain behavior — but it
  means a prolonged DB outage will cycle the instance; decide deliberately per service.
