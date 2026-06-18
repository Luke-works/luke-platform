# Master Prompt — Execute: Merge `luke-capability-engine` into `luke-core-engine`

Hand this entire document to a fresh coding-assistant session opened at the
`luke-0531` workspace root. It is self-contained: target behavior, ground truth,
the known traps, ordered milestones, verification, and rollback. Background &
decision rationale live in [`MERGE_CAPABILITY_INTO_CORE.md`](./MERGE_CAPABILITY_INTO_CORE.md);
**this** file is the execution contract.

---

## ⛔ CARDINAL RULE — STOP AND TAKE A BREAK BETWEEN MILESTONES

The work is divided into **milestones M0–M5**. After finishing **each** milestone:

1. **STOP.** Do not start the next milestone.
2. Report: what changed (files), what you verified (commands + results), what you
   could not verify, and any deviation from this prompt.
3. **Wait for an explicit human "go"** before continuing. Approval of one
   milestone is NOT approval of the next.

Never bundle two milestones into one change-set. Never push, deploy, merge to
`develop`/`qa`/`uat`/`main`, or run the data migration without explicit approval
at the relevant gate. If anything contradicts the GROUND TRUTH below, **stop and
report the drift** rather than guessing.

---

## TARGET BEHAVIOR (what "done and functional" means)

One Spring Boot deployable (`luke-core-engine`). When complete, ALL of the
following must be true and verified:

- **Roles:** Camunda (core) owns **all orchestration**; capability's 11 `luke_*`
  tables are a **passive data store**. No separate capability service runs.
- **In-process, no HTTP hops:** the proxy and every cross-service call are gone;
  all former capability routes resolve locally.
- **Write-back works:** orchestration output is persisted back to the `luke_*`
  tables by an **in-process JavaDelegate using the repositories**, in the same
  transaction as the process step — no HTTP, no `/processed` callback.
- **Submit→process is durable:** form submit writes the instance state **and** an
  outbox row in **one transaction**; a poller starts the Camunda process
  idempotently. A crash between the two never loses the submission.
- **Security holds:** former capability routes sit behind core's `/api/**` auth;
  `/api/tenants/**` and capability catalog writes require operator/tenant-admin;
  `/api/internal/**` is fail-closed; `/api/public/embed/**` stays **open +
  rate-limited**; client-supplied `X-User-Id`/`X-Tenant-Id` cannot be spoofed.
- **Reliability:** the engine takes load without job delay (sizing + job-executor
  tuning already on branch `chore/engine-sizing-tuning`).
- **Schema:** all `luke_*` + `ACT_*` + outbox live in the **same per-env schema**
  the engine already uses (Strategy A). One DataSource. **No second DataSource.**

---

## GROUND TRUTH (verified 2026-06-18; the repo wins if stale — re-verify, don't trust blindly)

- Core boots from `com.luke.engine.LukeCoreEngineApplication` (scans
  `com.luke.engine` only). Capability boots from
  `com.luke.capability.LukeCapabilityEngineApplication`.
- Capability: **64 classes**, **11 `@Entity` + 11 repos**, 12 controllers, 3
  filters (`GatewayAuthFilter`, `OperatorAuthFilter`, `InternalAuthFilter`), 9
  tests. Core's only entity is `RegisteredTopic`. **No table-name collisions.**
- `CapabilitiesProxyController` forwards 12 prefixes; **3 are dead**
  (`business-calendars`, `sla`, `process-calendars` — no controller). **`/api/tenants/**`
  is NOT proxied** — it is called directly by core's `OrganizationController`,
  `OrgAdminController`, `AccountController` via `RestTemplate` + operator creds.
- `/api/internal/**` is **bidirectional**: core has `/api/internal/process-start`;
  capability has `/api/internal/secrets` (returns **decrypted** tenant secrets)
  and `/api/internal/emails`, behind `InternalAuthFilter` (fail-closed 503).
- **The `/api/**` enforcer in core is `ApiAuthFilter`** (scoped to
  `/api/form-inbox`, `/api/process-trace`, `/api/topics`). `RestApiAuthFilter` is
  `/engine-rest/*` ONLY. Capability routes were previously auth'd *inside*
  capability — that enforcement vanishes when the proxy is deleted.
- Capability identity today comes from `GatewayAuthFilter`, which **overwrites**
  client `X-User-Id`/`X-Tenant-Id` with the verified token `sub` (anti-spoof).
  Controllers + `CapabilityAccessInterceptor` then read those headers.
- Email send is **synchronous** (`PostmarkClient.postForObject`, no `@Async`).
- Schema today: prod core has **no `DB_SCHEMA` → `public`**; prod capability uses
  `capability`. Non-prod engine = `platform_dev`/`platform_qa`; non-prod
  capability = `capability_dev`/`capability_qa`. `uat` is commented out.
- Camunda isolation lines (`schema-name` + `table-prefix=${DB_SCHEMA:public}.`)
  are in `application-postgres.yml`. **NEVER change them.**

---

## 🪤 KNOWN TRAPS — these compile/boot fine but are silently broken. DO NOT SHIP WITHOUT FIXING.

1. **Outbox consumer won't run.** There is no `@EnableScheduling` in core. Add it,
   or `@Scheduled` is silently ignored and no process ever starts.
2. **The "one transaction" doesn't exist.** The submit path has **no
   `@Transactional`** (and `open-in-view=false`). Add a `@Transactional` service
   that does the instance-state change AND the outbox insert together.
3. **Async email is a no-op.** No `@EnableAsync` + no `TaskExecutor`. Add both, or
   `@Async` runs synchronously on the request thread.
4. **Impersonation hole.** Deleting `GatewayAuthFilter` makes the moved
   controllers trust raw client headers. Port its header-override (verified `sub`
   overwrites client `X-User-Id`/`X-Tenant-Id`) into core, running BEFORE
   `CapabilityAccessInterceptor`.
5. **Wrong filter + open secrets.** Extend `ApiAuthFilter` (NOT
   `RestApiAuthFilter`) for the moved `/api/**` routes, and **port
   `InternalAuthFilter` into core** — `/api/internal/secrets` returns decrypted
   secrets and must stay fail-closed even though no external caller exists.
6. **Not all process-start callers are rewired.** `ProcessStarter.startForInstance`
   is called from `FormInstanceController.submit()`, `FormInstanceController.retryProcess()`,
   AND `FormEmbedController.submit()` (public embed). Convert **all three** to the
   outbox. Inventory every caller before deleting the HTTP path.

---

## 🔐 INTERNAL-AUTH HANDLING — do not regress #41 (from the #41 owner, 2026-06-18)

`#41` made `/api/internal/**` **fail-closed** (503 when the secret is unset). The
merge MUST NOT undo that.

1. **Keep `InternalAuthFilter` + `LUKE_INTERNAL_SHARED_SECRET` in place during the
   move (M1–M3).** Do not rip them out as part of the lift-and-shift.
2. **Converting `process-start` to in-process is fine** — that HTTP hop genuinely
   disappears in one app (the *caller* goes in-process; retire the endpoint only
   once nothing calls it).
3. **Do not delete the shared secret or `/api/internal/{secrets,emails}` until the
   audit is confirmed EMPTY** (source audit is already empty; add the per-env
   runtime BPMN check). If ANY BPMN service task calls them over HTTP, **keep
   them, shared-secret-guarded.** Removal is **M5-only and audit-gated.**
4. **Preserve fail-closed** for whatever `/api/internal/**` stays externally
   reachable — never regress to fail-open.
5. **Keep `LUKE_INTERNAL_SHARED_SECRET` set consistently on both ends** until the
   endpoints are actually removed.

---

## MILESTONES

### M0 — Prerequisites & audits (no code) ▸ STOP
- [x] **`develop` CLEARED to branch from (2026-06-18)** — #41 (internal-auth
      fail-close) is merged and is NOT a blocker. Branch off **latest** `develop`.
- [ ] Lock package target: `com.luke.engine.capability.*`.
- [x] **BPMN/source audit of `/api/internal/{secrets,emails}` callers = EMPTY
      (2026-06-18):** only ONE BPMN in the workspace
      (`FormSubmissionIntakeProcess.bpmn`), with NO HTTP connectors anywhere; no
      external script/config caller; no Java caller. ⚠️ Covers *source-controlled*
      artifacts only — **before M5 removal, confirm no runtime/tenant-deployed
      BPMN on each env** uses an HTTP connector to these paths. Until removal:
      keep filter + secret + endpoints (see "Internal-auth handling").
- [ ] AUDIT that no UI hits the 3 dead prefixes.
- [ ] Confirm the sizing branches (`chore/engine-sizing-tuning`,
      `chore/render-sizing`) are landed/deployed FIRST (the merged JVM needs the
      bigger instance before it carries capability).
- **STOP. Report audit answers + branch base. Wait for go.**

### M1 — Bring-in / compile / boot (lift-and-shift, no behavior change) ▸ GATE A ▸ STOP
- [ ] Move `com/luke/capability/**` → `com/luke/engine/capability/**`; rewrite
      imports. **Do not move** `LukeCapabilityEngineApplication` (delete it).
- [ ] Keep capability `form` classes in `com.luke.engine.capability.form`
      (distinct from existing `com.luke.engine.form`).
- [ ] Add `@EntityScan("com.luke.engine")` + `@EnableJpaRepositories("com.luke.engine")`
      to `LukeCoreEngineApplication`. Grep for duplicate simple class names
      (bean-name collisions) and resolve.
- [ ] Add to core `pom.xml`: `spring-boot-starter-validation`,
      `spring-security-oauth2-jose`. No other version changes — flag conflicts.
- [ ] Merge capability `luke.*` config blocks (auth, internal, embed,
      email/Postmark, secrets, cors) into core's `application.yml` /
      `application-postgres.yml`. **Reconcile one schema story:** drop capability's
      `default_schema: capability`; let all JPA entities ride core's
      `currentSchema` (as `RegisteredTopic` already does). Leave Camunda
      `schema-name`/`table-prefix` untouched.
- [ ] Move the 9 tests; fold capability `contextLoads` into core's. Note: the
      merged `@SpringBootTest` now boots the full Camunda engine — add test config
      if needed (disable scheduling/auto-deploy in tests so they stay fast/quiet).
- **GATE A:** `./mvnw clean verify` builds; single context loads; all 12 tests
  (3 core + 9 capability) pass on H2; zero behavior change (proxy still present,
  no routing/auth/outbox work yet). **STOP. Report build + test output. Wait.**

### M2 — Routes in-process + auth ▸ STOP
*(These MUST land together — deleting the proxy without the auth below leaves
routes open/impersonatable.)*
- [ ] Delete `CapabilitiesProxyController`. Rewire `OrganizationController`,
      `OrgAdminController`, `AccountController` from `RestTemplate` calls to direct
      repository/service calls (subscription + grant). Remove `RestTemplate`,
      `luke.capabilities.base-url`, operator-cred `@Value`s.
- [ ] Delete capability `GatewayAuthFilter`/`OperatorAuthFilter` ONLY after
      porting their behavior: (a) **header-override** anti-spoof into core (trap
      #4); (b) extend **`ApiAuthFilter`** to cover the moved routes
      (`/api/form-definitions/*`, `/api/form-instances/*`, `/api/emails/*`,
      `/api/email-servers/*`, `/api/email-verification/*`, `/api/my-capabilities`,
      `/api/my-subscriptions/*`, `/api/capabilities/**`) — a missed pattern = open
      endpoint (trap #5); update its Javadoc (no longer "delegates to capability").
- [ ] Add a **tenant-admin gate** for `/api/tenants/**` + capability catalog
      writes (the BACKLOG fix — core never enforced this; capability's deleted
      filter was the only gate). Must NOT depend on the operator cred being removed.
- [ ] Port `InternalAuthFilter` into core for `/api/internal/**`, fail-closed
      (trap #5). Set filter order: internal → tenant-admin → api.
- [ ] Register `CapabilityAccessInterceptor` on the moved routes. Keep
      `/api/public/embed/**` unauthenticated + rate-limited (filters skip it).
- **STOP. Report route-by-route auth results + an impersonation test (spoofed
  `X-User-Id` rejected) + secrets endpoint guarded + embed still open. Wait.**

### M3 — Outbox + write-back + async (NET-NEW) ▸ STOP
- [ ] Add `@EnableScheduling` and `@EnableAsync` + a bounded `TaskExecutor`
      (traps #1, #3).
- [ ] **Outbox:** `FormSubmissionOutbox` entity (in `${DB_SCHEMA}`; `businessKey`
      unique = idempotency; status QUEUED|PUBLISHED|FAILED) + repo + a
      `@Scheduled` consumer that starts the intake process idempotently. With prod
      `numInstances: 2`, guard against double-poll: `SELECT … FOR UPDATE SKIP
      LOCKED` or a single-instance enable toggle (trap: HA race).
- [ ] **Transactional submit:** a `@Transactional` `FormSubmissionService.submit`
      that writes instance→SUBMITTED + outbox row in one tx (trap #2). Repoint
      **all** `ProcessStarter` callers — `submit`, `retryProcess`,
      `FormEmbedController.submit` — to it (trap #6). Replace
      `InternalProcessController`/`ProcessStarter` HTTP with in-process
      `RuntimeService` start (Spin JSON vars; confirm spin-json on classpath).
- [ ] **Write-back:** add a service task to `FormSubmissionIntakeProcess.bpmn`
      with a `@Component` `JavaDelegate` that writes output to `luke_*` via the
      repositories **in-process** (NOT the old `/processed` HTTP call). The
      delegate must be best-effort (a write-back failure must not rewind a
      complete process). Redeploy the BPMN to all tenants **before** flipping
      submit to the outbox; account for in-flight instances on the old version.
- **STOP. Report: a QUEUED row → PUBLISHED → process started → write-back
  persisted; a forced failure after the state save commits NEITHER row. Wait.**

### M4 — Data migration (per-env) ▸ GATE C ▸ STOP
> **N/A — SKIPPED (2026-06-18): pre-production, no existing data to move.** Dev/qa
> create the `luke_*` tables fresh via `ddl-auto` on first boot of the merged engine.
> Revisit only if/when an environment holds data worth relocating; the script below
> is kept for that case.
- [ ] Write an **idempotent, per-env** psql migration: `ALTER TABLE <src>.<t> SET
      SCHEMA <dst>` ×11 with `IF EXISTS` + before/after row counts, in a tx, then
      `DROP SCHEMA` of the emptied source. **Per-env mapping:** dev
      `capability_dev → platform_dev`; qa `capability_qa → platform_qa`; prod
      `capability → public`. **Never** hardcode `camunda`; **never** change core's
      `DB_SCHEMA` (it would strand existing `ACT_*` tables → boot crash).
- [ ] The migration must run **before** the merged app boots with `ddl-auto:
      update` (else it creates empty `luke_*` in the target and the move fails).
- [ ] Rehearse on a **staging copy** first; verify counts match.
- **GATE C: STOP. Present the script + dry-run results + rollback (inverse `SET
  SCHEMA`). Wait for explicit go before touching any real data.**

### M5 — Deploy / cutover ▸ STOP
- [ ] **Internal endpoints (audit-gated — see "Internal-auth handling"):** source
      audit is empty; if the per-env **runtime** BPMN check is also clean, remove
      `/api/internal/{secrets,emails}` (and `process-start` once nothing calls it)
      and the shared secret on both ends. If ANY caller exists, KEEP them
      shared-secret-guarded + **fail-closed** and keep `LUKE_INTERNAL_SHARED_SECRET`
      set. Never regress #41 to fail-open.
- [ ] `luke-core-engine/render.yaml`: fold capability env vars
      (`LUKE_INTERNAL_SHARED_SECRET`, `POSTMARK_*`, `EMAIL_*`, `LUKE_SECRETS_*`,
      `LUKE_EMBED_HMAC_SECRET`); remove `CAPABILITIES_BASE_URL` + operator creds.
- [ ] `luke-platform/render.yaml`: delete `platform-{dev,qa}-capability` blocks;
      repoint the shared-secret envVarGroups.
- [ ] Archive `luke-capability-engine` (tag final commit); update CI + docs; close
      the operator-gate BACKLOG item referencing this change.
- [ ] Coordinated single redeploy; smoke-test (see VERIFICATION). Ship any
      co-dependent UI together.
- **STOP. Present full diff + cutover checklist + rollback. Wait for go.**

---

## GUARDRAILS
- One change-set per milestone; scoped, reversible commits. Branch off latest
  `develop`; never commit to `develop`/`qa`/`uat`/`main`.
- **Never** touch Camunda `schema-name`/`table-prefix`; **never** change core's
  `DB_SCHEMA`; **no** second DataSource (Strategy A is one schema, one pool).
- No silent version bumps or dependency removals — flag and ask.
- Don't delete capability source/filters until their behavior is ported and the
  build + routes pass.

## VERIFICATION (run at the relevant milestone)
- **Build:** `./mvnw clean verify` green (3 core + 9 capability tests).
- **Functional:** walk `MASTER_TEST_SCRIPT.md` rows 1.7 (AI builder), 3.1 (submit
  + follow-up), 3.2 (public-form rate limit), 3.3 (tenant email/secrets).
- **Submit durability:** QUEUED→PUBLISHED→process→write-back; failure rolls back
  both rows.
- **Security:** `/api/tenants/**` rejects a non-operator; spoofed `X-User-Id`
  rejected; `/api/internal/secrets` fail-closed; `/api/public/embed` works
  unauthenticated (test 1.3).

## ROLLBACK
- Pre-cutover: revert the branch; standalone capability still deploys.
- Post-cutover: keep the inverse `ALTER TABLE … SET SCHEMA <src>` script + the
  archived capability service definition ready to redeploy.
