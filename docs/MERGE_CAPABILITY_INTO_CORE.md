# Master Prompt — Merge `luke-capability-engine` into `luke-core-engine`

Hand this entire document to a fresh Claude Code session opened at the
`luke-0531` workspace root. It is self-contained: context, decisions,
guardrails, ordered phases, and verification gates.

---

## ✅ GATE 0 — Scan findings & decisions (re-scanned 2026-06-18)

> Added after executing Phase 0 against the live repos. **Where this conflicts
> with GROUND TRUTH below, this section wins** (repos re-scanned 2026-06-18).
> **Phase 1 has NOT started.**

### Target architecture — LOCKED (2026-06-18)
Framed around roles, not just "one process":
- **Camunda (core) = orchestration brain.** Owns ALL process logic.
- **Capability `luke_*` tables = system of record (a passive data store).**
- **Strategy A + in-process data layer + collapse to ONE deployable:** capability's
  JPA **entities + repositories fold into the core JVM**; capability ceases to be a
  separate Render service — its CRUD API and public-embed intake become endpoints
  in the merged app. Shared Postgres, one schema per env (`platform_<env>`).
- **Write-back is in-process + transactional:** Camunda service-task delegates
  (`@Component` JavaDelegates) read inputs and persist orchestration **output back
  to the `luke_*` tables via the repositories, in the same transaction as the
  process step** — no network hop. (The clean form of the #28 fix.)
- **Submit→process inverts:** form data → data store → process started (via the
  OUTBOX) → process reads it, orchestrates, writes results back.
- **Only the active surfaces get isolated** (a passive data layer is otherwise
  safe to co-locate): **email → async**; **public embed → rate-limited**. These
  are the only parts that could stall the engine once capability is passive.

### Confirmed (GROUND TRUTH holds)
- Both Spring Boot 3.4.4 / Java 21, identical parent + BOM. No version conflicts.
- Capability owns exactly **11** `luke_*` tables; core owns only
  `luke_registered_topics` (+ `TenantAwareEntity` `@MappedSuperclass`).
  **No table-name collisions** (verified by grep).
- Camunda isolation (`schema-name` + `table-prefix=${DB_SCHEMA:public}.`) present
  in `application-postgres.yml` — leave untouched.
- `LUKE_INTERNAL_SHARED_SECRET` guards capability→core
  `/api/internal/process-start` (fail-closed via `InternalAuthFilter`, PR #41).

### Drift — corrections to GROUND TRUTH
1. **`/api/tenants/**` is NOT proxied.** It's reached by core's *own* admin
   controllers via direct RestTemplate + operator creds —
   `OrganizationController`, `OrgAdminController`, `AccountController`. Deleting
   `CapabilitiesProxyController` does NOT remove these; **Phase 2 must also
   rewire these three to in-process service calls.**
2. **The proxy forwards 12 prefixes and 3 are dead.** Actual list:
   `business-calendars`, `sla`, `process-calendars`, `capabilities`,
   `my-subscriptions`, `my-capabilities`, `form-definitions`, `form-instances`,
   `emails`, `email-servers`, `email-verification`, `public`. The first three
   have **no controller** in capability (catalog placeholders → proxy to 404).
3. **`/api/internal/**` is bidirectional.** Besides core's `process-start`,
   *capability* also exposes `/api/internal/secrets` and `/api/internal/emails`
   (behind its own `InternalAuthFilter`). No compile-time Java caller found in
   core/task-engine — likely BPMN HTTP connectors. **Phase 2 decision:** keep
   these mounted (shared-secret) for external/BPMN callers, or convert to
   in-process. **Audit deployed BPMN before deleting the shared secret.**
4. **Capability ALREADY has per-env schema isolation.** The platform blueprint
   sets `capability_dev` / `capability_qa`; `uat` is commented out (only **2
   live envs**, not 3). The literal `capability` default applies only to the
   standalone repo / local. (Contradicts the doc's "no per-env isolation".)
5. **Almost no third-party deps to bring in.** Capability implements Postmark /
   embed-HMAC / secret-crypto with the **JDK**. Only deps core lacks:
   `spring-boot-starter-validation`, `spring-security-oauth2-jose`. **Zero
   version conflicts.**

### KEY DECISION — RESOLVED: **Strategy A (single schema)**
Per-env data move (corrected for drift #4 — not a single `capability` schema):
- `capability_dev.<11 tables>` → `platform_dev`
- `capability_qa.<11 tables>`  → `platform_qa`
- local / standalone `capability` → `public`
- `uat`: n/a (disabled)

### New design constraints (not in the original doc)
- **Two-pool isolation vs. the single-transaction #28 fix CONFLICT.** A dedicated
  Camunda DB pool needs Camunda + JPA on *separate* datasources; the "persist
  form instance + start process in ONE transaction" fix needs them to *share*
  one. Cannot have both without XA/JTA. **Resolution: single datasource +
  transactional OUTBOX** — persist instance + outbox row in one tx; an
  idempotent consumer starts the process (dedup on business key). Durable, no
  distributed tx, composes with separate pools later. Do NOT ship a naive single
  `@Transactional` (it would roll back the user's submission on a Camunda flake).
- **Email is synchronous** (`PostmarkClient`/`PostmarkAccountClient` block on the
  request thread, no `@Async`). Post-merge this couples Postmark latency to the
  engine JVM → **make email async (outbox / `@Async`) as part of the merge.**

### Sizing / reliability prep ALREADY applied (uncommitted branches)
Adjacent to the merge — on `chore/engine-sizing-tuning` (luke-core-engine) and
`chore/render-sizing` (luke-platform):
- Engine: non-prod **Standard 2 GB ×1**; prod **Pro 4 GB ×2** (HA + jobs-never-
  delayed). `HEAP_PCT` knob + G1GC / `-Xss512k` / `ExitOnOutOfMemoryError`.
- DB: non-prod shared → `basic-1gb`; prod → `basic-4gb` (HA TBC).
- Camunda job-executor tuned (`lock-time-in-millis=300000` for ≥2-node safety);
  `DB_POOL_MAX` env-driven; `enforceHistoryTimeToLive` env-driven (prod on,
  `historyTimeToLive` already `P180D`).
- The merged engine inherits the prod `×2` requirement — it is cluster-safe by
  Camunda's per-row job lock.

### Status & adjusted phase notes
- **Phase 0: DONE** (this section). **Phases 1–3: NOT started.**
- Phase 1 dep merge = add only the 2 starters above.
- **Phase 2 gains scope:** rewire the 3 admin controllers (`/api/tenants/**`); a
  decision on capability's `/api/internal/{secrets,emails}`; the **outbox** for
  submit→process (not a naive single `@Transactional`); and **async email**.

---

## ROLE & GOAL

You are merging the `luke-capability-engine` Spring Boot service **into**
`luke-core-engine` so the platform runs one Java process instead of two. This
removes a deployment, the `CapabilitiesProxyController` HTTP hop, the
`LUKE_INTERNAL_SHARED_SECRET` server-to-server call, and the cross-service auth
boundary — and it closes the open security backlog item (unauthenticated
capability admin routes) by putting those routes behind core-engine's existing
auth filter.

Work on a branch. **Do not push, deploy, or merge to `develop`/`qa`/`uat`/`main`
without explicit approval.** Stop at every GATE and report; wait for a go.

---

## GROUND TRUTH (verify before trusting; the repo wins if this is stale)

**Services**
- `luke-core-engine` — Spring Boot 3.4 / Java 21, FluxNova (Camunda 7), port 8080.
  Own JPA entities under `com.luke.engine` (`RegisteredTopic`; `TenantAwareEntity`
  is an abstract base). Hosts `CapabilitiesProxyController` that forwards
  `/api/capabilities/**`, `/api/my-subscriptions/**`, `/api/business-calendars/**`,
  `/api/sla/**`, `/api/process-calendars/**`, `/api/tenants/**` to capability.
- `luke-capability-engine` — Spring Boot 3.4 / Java 21, port 8082. Entities under
  `com.luke.capability.{form,secrets,access,capability,email}`. 9 test files.

**Database (shared instance `luke_camunda`)**
- core-engine writes schema `${DB_SCHEMA}` (per env: `platform_dev`/`qa`/`uat`,
  default `public`): Camunda `ACT_*` tables + `RegisteredTopic`.
- capability-engine writes schema `capability` (literal default): 11 `luke_*`
  tables — `luke_capabilities`, `luke_capability_subscriptions`,
  `luke_capability_grants`, `luke_form_definitions`, `luke_form_versions`,
  `luke_form_audit`, `luke_form_instances`, `luke_secrets`, `luke_email_servers`,
  `luke_email_messages`, `luke_email_verifications`.
- `ACT_*` and `luke_*` names never overlap; core's only own table is
  `RegisteredTopic`. **No name collisions exist** — verify with a grep before
  relying on it.

**Cross-service plumbing to remove**
- capability → core `/api/internal/**` guarded by `LUKE_INTERNAL_SHARED_SECRET`.
- capability's `luke.auth.gateway.*` (JWKS verify) + `luke.auth.operator.*`
  (operator user/pass on `/api/tenants/**`). core presents the same operator pair
  on its server-to-server calls.

**Config facts**
- Camunda isolation in core's `application-postgres.yml`: `schema-name` +
  `table-prefix=${DB_SCHEMA}.`. **DO NOT CHANGE THIS.** It prevents the
  `act_id_user does not exist` first-boot race across shared-schema envs.
- Hikari pools: core 8, capability 10 (on a `basic-256mb` Postgres).
- capability JPA: `default_schema=${DB_SCHEMA:capability}`,
  `hbm2ddl.create_namespaces=true`.
- Deploy: `luke-platform/render.yaml` (3 envs, core+ui only) and a separate
  `render.yaml` inside the capability repo. CI: per-repo `.github/workflows/ci.yml`.

---

## KEY DECISION (resolve at GATE 0, then bake in)

**Schema strategy — pick ONE:**

- **(A) Single-schema (recommended).** Capability's 11 `luke_*` tables move into
  the per-env `${DB_SCHEMA}` alongside `ACT_*`. Drop the `capability` schema.
  Pro: fixes today's asymmetry (capability currently has no per-env isolation);
  one schema to reason about. Con: requires moving existing rows
  (`ALTER TABLE capability.<t> SET SCHEMA <env_schema>;` ×11) and deciding which
  env today's single `capability` data maps to (likely `platform_dev`; qa/uat
  start empty).
- **(B) Keep capability schema.** Code merges into one process, but capability
  entities keep `schema="capability"` (explicit on each `@Table`, or a second
  `EntityManagerFactory`). Pro: zero data migration, same-day cutover. Con:
  preserves the per-env asymmetry; two schemas forever.

Default to **(A)** unless the user says a zero-data-move cutover matters more.
Present the trade-off and get a decision before writing code.

---

## PHASES (stop at each GATE)

### Phase 0 — Recon & plan  ▸ GATE 0
1. Confirm GROUND TRUTH against the actual repos (entity packages, table names,
   the proxy routes, the `/api/internal/**` contract, both `render.yaml`s, pom
   coordinates/versions). Note any drift.
2. Grep for table-name collisions between `com.luke.engine` and
   `com.luke.capability` entities. Confirm none.
3. List capability's third-party deps (Postmark, embed HMAC, secret crypto, etc.)
   that core does not yet have, so the merged `pom.xml` is complete.
4. Produce a written migration plan + the schema decision (A/B) recommendation.
   **STOP. Report the plan. Wait for approval.**

### Phase 1 — Bring the code in (compiles, no behavior change yet)
1. Copy `com.luke.capability.*` source + resources + the 9 test files into
   core-engine, preserving packages. Merge `pom.xml` deps (no duplicates,
   reconcile versions — flag any conflicts instead of silently picking).
2. Merge config into core's `application.yml` / `application-postgres.yml`:
   capability's `luke.email.*`, `luke.embed.*`, secret-crypto keys, etc. For
   strategy (A) let capability entities inherit core's `${DB_SCHEMA}` (delete
   `default_schema: capability`); for (B) pin `schema="capability"` explicitly.
   **Leave Camunda `schema-name`/`table-prefix` untouched.**
3. Collapse to **one** Hikari pool (~10–12, not 18).
4. Build: `cd luke-core-engine && ./mvnw -q clean verify`. All tests (core's 3 +
   capability's 9) must pass against the default H2 profile.
   ▸ GATE 1 — **STOP. Report build + test results.**

### Phase 2 — Wire routes in-process, delete the hops
1. Mount capability's controllers directly in core-engine. **Delete**
   `CapabilitiesProxyController`; the routes (`/api/capabilities/**`,
   `/api/my-subscriptions/**`, `/api/sla/**`, `/api/business-calendars/**`,
   `/api/process-calendars/**`, `/api/tenants/**`) now resolve locally.
2. Replace the capability→core `/api/internal/**` HTTP call (process-start on form
   submit) with a direct in-process service call. Wrap "persist form instance +
   start Camunda process" in **one** transaction. Delete the
   `LUKE_INTERNAL_SHARED_SECRET` plumbing on both ends.
3. Put the former capability routes behind core-engine's existing
   `GatewayAuthFilter`. The admin routes (`/api/tenants/**`, capability catalog
   writes) get core's operator check (`camunda-admin` / `parent_cluster`) — this
   is the BACKLOG fix. Remove capability's now-redundant `luke.auth.gateway.*`
   and `luke.auth.operator.*`. Preserve the local-dev "open when verifier unset"
   behavior.
4. Build + run the merged app on the `postgres` profile against a local Postgres;
   smoke-test each former proxy route and a form submit end-to-end.
   ▸ GATE 2 — **STOP. Report route-by-route results.**

### Phase 3 — Data & deploy (only after GATE 2 approval)
1. **(Strategy A only)** Write the data-move script:
   `ALTER TABLE capability.<table> SET SCHEMA <env_schema>;` for all 11 tables,
   per env, idempotent, inside a transaction, with a verification count
   before/after. Treat as a reviewed migration, not an ad-hoc run.
2. Update deploy: remove the capability service from any blueprint; ensure
   core-engine's env carries the merged env vars (Postmark, embed HMAC, secret
   keys). Archive the capability repo's `render.yaml`. Update CI (drop
   capability's pipeline or fold its tests into core's).
3. Update docs: `luke-platform/README.md`, the capability README (mark merged),
   and close the "Operator-gate capability-engine admin routes" item in
   `luke-platform/BACKLOG.md` referencing this change.
4. Update `luke-core-ui` / `luke-consumer-ui` only if any client pointed at
   capability's URL directly rather than through core (verify; most go through
   the proxy and need no change).
   ▸ GATE 3 — **STOP. Present the full diff, the data script, and a rollback
   plan. Wait for go before anything is pushed.**

---

## GUARDRAILS
- One change-set per phase; keep commits scoped and reversible. Branch off the
  current branch; never commit to `develop`/`qa`/`uat`/`main`.
- **Never touch** Camunda's `schema-name` / `table-prefix` config.
- No silent version bumps or dependency removals — flag conflicts and ask.
- Don't delete capability source until the merged build + routes pass (GATE 2);
  delete in Phase 3 so the diff stays bisectable.
- If anything contradicts GROUND TRUTH, stop and report the drift rather than
  guessing.
- Watch core-engine's memory: it already carries an OOM fix (PR #49). Adding the
  capability domain to one JVM means the merged instance likely needs a size
  bump even though total RAM across the box drops (one JVM baseline removed).

## VERIFICATION
- Unit/integration: merged `./mvnw clean verify` green (core 3 + capability 9).
- Functional: walk the relevant rows of `luke-platform/MASTER_TEST_SCRIPT.md`
  — esp. 1.7 (AI builder), 3.1 (form submit + follow-up), 3.2 (public-form
  rate limit), 3.3 (tenant email/secrets). All must still pass.
- Security: confirm `/api/tenants/**` now rejects a non-operator caller (the
  BACKLOG fix) and public embed links still work unauthenticated (test 1.3).

## ROLLBACK
- Pre-cutover: revert the branch; the standalone capability-engine still deploys.
- Post-cutover (strategy A): keep the inverse `ALTER TABLE … SET SCHEMA capability;`
  script ready and the capability service definition archived, so you can move
  tables back and redeploy the old service if needed.
