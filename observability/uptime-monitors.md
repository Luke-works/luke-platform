# OBS-0 — External uptime monitor + Slack

Stand up a free-tier uptime monitor (**BetterStack** or **UptimeRobot**) and point it at each
service's health URL. This is the only signal that pages a human if Render's health-check *and*
auto-restart both fail. ~15 minutes.

## Monitors (per environment)

| Service | Monitor URL | Expected | Notes |
| --- | --- | --- | --- |
| core-engine | `https://<core-host>/actuator/health/readiness` | `200`, body `{"status":"UP"}` | Readiness includes the DB — catches a DB-down instance. |
| auth-engine (gateway) | `https://<gateway-host>/actuator/health/readiness` | `200`, `"status":"UP"` | Readiness includes WorkOS verifier + core reachability. |
| file-proxy | `https://<file-proxy-host>/actuator/health` | `200`, `"status":"UP"` | |
| agents | `https://<agents-host>/health` | `200` | Reports active brain + mounted agents. |
| consumer-ui | `https://<consumer-ui-host>/` | `200` | Static site — a 200 on root is enough. |
| core-ui | `https://<core-ui-host>/` | `200` | |

Dev hosts for reference: `platform-dev-engine.onrender.com`, `authdev.lukeflow.com`,
`platform-dev-agents.onrender.com`. Set up **prod** monitors first (that's what matters), then qa/dev
if you want early warning.

## Settings
- **Check interval:** 1–3 min (free tiers allow this).
- **Alert after:** 2 consecutive failures (avoids flapping on a single blip).
- **Keyword check** (optional but recommended): assert the response body contains `"status":"UP"` so a
  200-with-degraded-body still alerts.
- **Notifications:** connect the monitor's **Slack** integration to a dedicated `#alerts` channel. Use
  the **same** channel as the OBS-5 Grafana alerts so all "something's wrong" signals land in one place.

## Verify
Temporarily stop a dev service (or point a monitor at a deliberately-wrong path) and confirm the Slack
alert fires, then fix it. Note the recovery ("back up") notification also lands.
