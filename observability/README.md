# Observability — operator runbook

The **code** for OBSERVABILITY V1 is shipped and inert until you flip the switches below. Every
backend already emits metrics and can report errors; this runbook wires the free-tier SaaS side so
they become **visible + alerting**. Tracker: [luke-platform#13].

| Signal | Emitted by (shipped) | Activated by you (here) |
| --- | --- | --- |
| **Metrics** | `/actuator/prometheus` on core-engine, auth-engine, file-proxy (+ agents `/metrics`) | OBS-3: Grafana Cloud + the Alloy collector |
| **Backend errors** | `sentry-spring-boot-starter` on the 3 JVM backends (DSN-gated) | OBS-1/4: Sentry project + `SENTRY_DSN` |
| **Frontend errors** | `@sentry/react` in consumer-ui / core-ui (DSN-gated) | OBS-1: Sentry project + `VITE_SENTRY_DSN` |
| **Uptime** | Render health probes + auto-restart | OBS-0: external monitor + Slack |
| **Alerting** | — | OBS-5: Grafana alert rules → Slack |

Everything is **env-gated**: nothing is exposed or sent until the corresponding secret is set, so
dev/qa keep running untouched while you roll this out.

---

## Do it in this order (each step is independent and reversible)

### 1. OBS-0 — Uptime monitor + Slack (15 min, biggest gap closed first)
See [`uptime-monitors.md`](./uptime-monitors.md). Stand up BetterStack or UptimeRobot (free), point
it at each service's **readiness** URL, route failures to a Slack channel. This is the only thing
that pages a human if Render's health-check *and* auto-restart both fail.

### 2. OBS-1 — Turn on Sentry (frontend + backend) (30 min)
See [`sentry-setup.md`](./sentry-setup.md). Create the Sentry projects, set the DSNs as env vars
(`VITE_SENTRY_DSN` for the UIs, `SENTRY_DSN` for the backends), and pin the Sentry origin in the CSP
(ties to the CSP work). The code is already wired — this is env + one CSP line.

### 3. OBS-3 — Metrics → Grafana Cloud (45 min)
See [`alloy/`](./alloy/). Create a free Grafana Cloud stack, set a `MANAGEMENT_METRICS_TOKEN` on each
backend (the same value the Alloy collector uses), deploy the Alloy collector as a Render service,
import the stock Spring Boot / Micrometer dashboard. Metrics start flowing within a minute.

### 4. OBS-5 — Alert rules → Slack (20 min)
See [`grafana-alerts.md`](./grafana-alerts.md). Import the four alert rules (5xx spike, p95 latency,
DB-pool saturation, readiness DOWN) and route them to the OBS-0 Slack channel.

---

## The secrets you'll set (all `sync:false`)

| Env var | On which services | Purpose |
| --- | --- | --- |
| `MANAGEMENT_METRICS_TOKEN` | core-engine, auth-engine, file-proxy **+ the Alloy collector** | Bearer token gating `/actuator/prometheus`. Same value everywhere. Unset ⇒ endpoint is 404. |
| `SENTRY_DSN` | core-engine, auth-engine, file-proxy | Backend Sentry DSN. Unset ⇒ disabled. |
| `SENTRY_ENVIRONMENT` | same | `dev` \| `qa` \| `prod` — tags events. |
| `VITE_SENTRY_DSN` | consumer-ui, core-ui | Frontend Sentry DSN. Unset ⇒ disabled. |
| `GRAFANA_CLOUD_PROM_URL` / `_USER` / `_API_KEY` | the Alloy collector only | Grafana Cloud `remote_write` target + creds. |

> Roll out per environment: **dev first**, verify metrics + a test error land, then qa, then prod.
> None of these change app behavior — they only turn telemetry on.
