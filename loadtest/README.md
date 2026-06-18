# Luke engine load-test harness

A small harness to turn "how many tenants/users can we run?" into a measured
number. It drives the real **form-submit → process-start** path (and, optionally,
raw engine throughput) at a ramping request rate and tells you where it breaks.

## What's here

| File | Purpose |
|---|---|
| `k6/submit-flow.js` | The k6 load script. Open-model (ramping arrival rate); finds the throughput knee. |
| `monitor.sh` | Run alongside the test — shows job backlog + instance throughput so you can see if the engine is keeping up. |
| `setup.sh` | Best-effort seed: creates a tenant + a published form, prints the `FORM_CODE`. |
| `.env.example` | All config knobs. |

## Prerequisites

- [k6](https://k6.io/docs/get-started/installation/) (`brew install k6`)
- `curl` (always) and `jq` (only for `setup.sh`)
- A **staged** engine to point at — qa or uat. **Do not run against prod.**

## Auth: pick the easy path

The form routes sit behind the gateway filter, which **trusts `X-Tenant-Id` when
the JWKS verifier is unset** (local-dev behavior). The simplest setup is to run
the staged engine with `LUKE_AUTH_GATEWAY_ENABLED=false` (or no `…JWKS_URL`) for
the duration of the test — then no tokens are needed. If the gateway is enabled,
pass a real act-as-user token via `AUTH_HEADER`. `/engine-rest` always needs
Basic admin creds (`ENGINE_BASIC=admin:admin`) for the monitor.

## Run it

```bash
cd luke-platform/loadtest

# 1) (optional) seed a tenant + published form
BASE_URL=https://platform-qa-engine.onrender.com \
ENGINE_URL=https://platform-qa-engine.onrender.com \
ENGINE_BASIC=admin:admin TENANT_ID=loadtest ./setup.sh
#   -> prints the k6 command with the right FORM_CODE

# 2) start the monitor in a second terminal
ENGINE_URL=https://platform-qa-engine.onrender.com \
ENGINE_BASIC=admin:admin TENANT_ID=loadtest ./monitor.sh

# 3) run the load test
k6 run -e BASE_URL=https://platform-qa-engine.onrender.com \
       -e TENANT_ID=loadtest -e FORM_CODE=<from-setup> \
       -e MAX_RATE=50 k6/submit-flow.js
```

Isolate raw engine throughput (no form layer):

```bash
k6 run -e ENGINE_URL=https://platform-qa-engine.onrender.com \
       -e ENGINE_AUTH="Basic $(printf 'admin:admin' | base64)" \
       -e TENANT_ID=loadtest -e SCENARIO=engine_start \
       -e MAX_RATE=80 k6/submit-flow.js
```

## Reading the result

k6 prints per-metric summaries; the ones that matter:

- **`luke_submit_duration` p95** — end-to-end submit latency. The arrival rate at
  which p95 crosses ~2s (or your SLO) is your **practical ceiling**.
- **`http_req_failed`** and **`luke_errors`** — climb sharply at the knee.
- **`luke_process_started`** — should stay ~100%. If it drops, submissions are
  succeeding but processes aren't starting (engine/DB pressure).
- **`iterations` / `http_reqs` rate** — achieved throughput vs the target rate;
  when achieved < target, you've saturated.

From `monitor.sh`, the **`jobs` column is the "jobs never delayed" signal**: flat
= keeping up; steadily climbing through the run = falling behind. `rate/s` is your
real sustained process throughput.

The knee gives you process-steps/sec. Translate to users with your activity
assumption, e.g. *50 actions/user/business-day ≈ 0.0017 sustained actions/sec per
active user*, then apply a 5× peak factor. (A ceiling of ~15/s sustained ≈ a few
hundred concurrently-active users at typical B2B usage — confirm against YOUR
process complexity, which dominates the number.)

## Scale-up tripwires (what to do when the knee is too low)

- `monitor.sh` **jobs climbing** or k6 latency knee low → add an engine node / bump instance.
- Engine DB CPU >70% or pool saturation → bigger Postgres / read replica.
- Many concurrent AI sessions → scale the agents service (separate tier).
- Before spending: set Camunda `historyTimeToLive` and/or drop `history-level`
  from `full` — usually the biggest free capacity win.

## Cleanup

Every run leaves form instances + process instances (and history) in the target
schema. On a throwaway staged env, the simplest reset is to drop/recreate the
env's schema, or delete by the `loadtest` tenant. Don't let load-test history
accumulate in a shared non-prod DB — it skews later runs.
