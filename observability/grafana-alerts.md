# OBS-5 — Grafana Cloud alert rules → Slack

Four alert rules over the metrics the Alloy collector ships (OBS-3). Create them in **Grafana Cloud →
Alerting → Alert rules**, and add a **contact point** for the same `#alerts` Slack channel as OBS-0.
The PromQL uses stock Spring Boot / Micrometer metric names, so no app changes are needed.

> Metric availability: `http_server_requests_*` and `hikaricp_*` come from the JVM backends;
> `hikaricp_*` only exists on services with a DB pool (core-engine). `up` is emitted by the collector
> for every scrape target.

## 1. 5xx error-rate spike
Fires when a service serves a sustained burst of server errors.
```promql
sum by (job, env) (rate(http_server_requests_seconds_count{status=~"5.."}[5m])) > 0.5
```
- **For:** 5m · **Severity:** critical · Tune `0.5` (5xx/sec) to your traffic; or use a ratio:
  `sum by (job)(rate(...{status=~"5.."}[5m])) / sum by (job)(rate(http_server_requests_seconds_count[5m])) > 0.05` (>5%).

## 2. p95 latency high
Fires when the 95th-percentile request latency degrades.
```promql
histogram_quantile(0.95, sum by (le, job, env) (rate(http_server_requests_seconds_bucket[5m]))) > 2
```
- **For:** 10m · **Severity:** warning · `2` = 2 seconds; adjust per service SLO.

## 3. DB connection-pool saturation (core-engine)
Fires when the Hikari pool is nearly exhausted — the classic precursor to request pile-up.
```promql
max by (job, env) (hikaricp_connections_active / hikaricp_connections_max) > 0.9
```
- **For:** 5m · **Severity:** critical · Also worth watching `hikaricp_connections_pending > 0` sustained.

## 4. Service down / readiness DOWN
Fires when the collector can't scrape a target (process down, readiness failing, or unreachable).
```promql
up{job=~"core-engine|auth-engine|file-proxy|agents"} == 0
```
- **For:** 2m · **Severity:** critical · This complements the OBS-0 external uptime monitor (defence in
  depth: OBS-0 checks from outside Render, this checks from the collector inside).

## Routing
- One **Slack contact point** → `#alerts`.
- A **notification policy** grouping by `job` + `env`, so a flapping service doesn't spam.
- Optionally silence `env=dev` outside working hours.

## Verify
Lower a threshold temporarily (e.g. p95 `> 0.01`) and confirm the Slack alert + recovery fire, then
restore the real threshold.
