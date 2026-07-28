# Luke platform — backlog

Cross-cutting follow-ups tracked at the platform level.

## Security

### Operator-gate capability-engine admin routes
**Status:** ✅ RESOLVED (2026-06-18, via the capability→core merge) · **Added:** 2026-06-05

**Resolution:** capability merged into core. `/api/tenants/**` is now reached only
in-process by core's admin controllers (which authorize via `requireAdmin` first),
and the catalog WRITE routes (`POST/PUT/DELETE /api/capabilities/**`) are gated by
the operator credential — `OperatorAuthFilter` was extended to cover them, with GET
left public. Verified by `CapabilityCatalogAuthTest`. (Original issue below.)


capability-engine's admin routes — `/api/tenants/**` (subscriptions + per-user
capability grants) and the catalog write routes (`POST/PUT/DELETE /api/capabilities/**`)
— are currently **unauthenticated**. Any caller that can reach the service (or
the core-engine proxy that now forwards `/api/tenants/**`) can change
subscriptions and grants.

**Why it's not a data-leak today:** forms/data access is gated per
`(tenant, user)` grant, and engine-rest user/group writes are enforced by
Camunda authorizations — so a non-operator can't *read* another tenant's data.
But they could *alter* grants. The consumer-ui gates the Auth page by `operator`,
which is UI-only.

**Fix:** add a Step-4-style filter on capability-engine's admin routes that
verifies the gateway act-as token and requires the user to be an operator
(member of `camunda-admin` / `parent_cluster`). The user-facing routes already
verify the token (`GatewayAuthFilter`); this extends it to the admin routes with
an operator check. When the verifier is disabled (local dev), keep the current
open behavior.

**Touches:** `luke-capability-engine` (`com.luke.capability.access`).

## Observability

### OBSERVABILITY V1 — fleet monitoring
**Status:** 🚧 IN PROGRESS (OBS-2 + OBS-4 shipped) · **Added:** 2026-07-23

Fleet-wide **continuous monitoring** initiative. Today's monitoring is strong on *security*
(weekly SAST/CodeQL/ZAP scans, Dependabot on 6 repos) and has basic *liveness* (Actuator
health probes + Render `healthCheckPath` auto-restart), but there is **no observability
stack** — no metrics/APM, no external uptime monitor, no alerting, and error tracking exists
only client-side (`@sentry/react` in consumer-ui/core-ui, DSN-gated and currently off).

Documented in `luke-docs/operations/observability.md`.

**Guardrails (all tickets):** default-lenient — every collector is env-gated and a **no-op
when its env var is unset**, mirroring the existing `observability.ts` (`if (!dsn) return`).
No new hard dependency that can fail a boot. Backend changes ship to `develop`, never `main`.

**Phase 0 — quick wins (near-zero code, highest value/hour):**

- **OBS-0 · External uptime monitor + Slack.** Stand up BetterStack/UptimeRobot (free tier)
  pinging the two UIs and `/actuator/health` on core-engine, auth-engine, file-proxy; wire the
  Slack integration. Closes the biggest gap — nothing today alerts a human if Render's
  auto-restart also fails. *No code.*
- **OBS-1 · Turn on the Sentry already built.** Create a Sentry project; set `VITE_SENTRY_DSN`
  (+ `VITE_RELEASE`) in the consumer-ui/core-ui prod envs; pin the Sentry origin in the
  platform CSP (already flagged pending in `render.yaml`). *No code change —
  `observability.ts` is wired.*

**Phase 1 — metrics pipeline:**

- **OBS-2 · Prometheus registry on the JVM backends.** ✅ **SHIPPED** — `micrometer-registry-prometheus`
  plus a scrape-token-gated `/actuator/prometheus` on all three JVM backends (never public).
  _core-engine `42ec6e4` · auth-engine `53a4b7e` · file-proxy `f4f40de` (all on `develop`)._
  Metrics are now exposed but nothing collects them yet — that's OBS-3.
- **OBS-3 · Ship to Grafana Cloud (free tier).** Run a small Grafana Alloy collector as a
  Render private service that scrapes each backend and `remote_write`s to hosted Grafana Cloud
  Prometheus; import the stock Spring Boot / Micrometer dashboard. (Push/remote-write chosen
  over scrape-only because a self-hosted Prometheus can't easily reach Render public services.)

**Phase 2 — alerting + backend errors:**

- **OBS-4 · Backend error tracking.** ✅ **SHIPPED** — `sentry-spring-boot-starter-jakarta`,
  DSN-gated so it is inert until `SENTRY_DSN` is set (dev/qa run with no config and no calls
  out). Closes the "JVM errors only live in Render logs" gap.
  _core-engine `6e86e22` · auth-engine `1216039` · file-proxy `d5a546d` (all on `develop`)._
  Wired but silent until a DSN is provisioned — same pending step as OBS-1.
- **OBS-5 · Alert rules → Slack.** Grafana Cloud alerts on 5xx-rate spike, p95 latency,
  DB-pool saturation, and `readiness` DOWN; route to the OBS-0 Slack channel.

**Phase 3 — document:**

- **OBS-6 · Docs + scorecard.** Flesh out `luke-docs/operations/observability.md` (dashboards,
  alert runbook, how to add a service) and bump the completeness scorecard once shipped.

**Touches:** `luke-platform` (this doc, `render.yaml`), `luke-core-engine`, `luke-auth-engine`,
`luke-file-proxy`, `luke-consumer-ui`, `luke-core-ui`, `luke-docs`.

**Where it stands.** The two items that were pure code are done: every JVM backend now emits
Prometheus metrics and reports errors to Sentry. Everything still open is an **account /
env-var step, not a code change** — OBS-0 (uptime monitor), OBS-1 (frontend DSN), OBS-3
(Grafana Cloud + collector), OBS-5 (alert rules). Until those are provisioned the fleet
publishes telemetry that nothing is listening to, so the original gap — *nothing alerts a
human* — is still open despite two tickets being green.
