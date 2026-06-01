# luke-platform

Infrastructure blueprint that deploys **luke-core-engine + luke-core-ui** together
for three shared non-prod environments on Render:

| Env | Engine | UI | Branch | DB schema |
|-----|--------|----|--------|-----------|
| dev | `platform-dev-engine` | `platform-dev-ui` | `develop` | `platform_dev` |
| qa  | `platform-qa-engine`  | `platform-qa-ui`  | `qa`      | `platform_qa`  |
| uat | `platform-uat-engine` | `platform-uat-ui` | `uat`     | `platform_uat` |

All three share **one** Postgres instance (`luke-nonprod-db`), isolated by schema.

## Architecture

- **Engine** — Docker web service built from `luke-core-engine` (`./Dockerfile`),
  Spring profile `postgres`. Each env sets `DB_SCHEMA`; the engine points
  `currentSchema` there and auto-creates the schema on first connect, so Camunda
  and the app keep their tables isolated per env on the shared DB.
- **UI** — Render static site built from `luke-core-ui` (`npm ci && npm run build`
  → `dist`). `VITE_API_BASE_URL` is **baked at build time** to that env's engine
  URL, so each env gets its own build.
- **CORS** — each engine's `ALLOWED_ORIGINS` is its env's UI URL.

## One-time setup

1. **Branches** — create `develop`, `qa`, `uat` in **both** `luke-core-engine`
   and `luke-core-ui`. They must include the engine's `DB_SCHEMA` support
   (commit on `main`: schema-aware `application-postgres.yml`).
2. **Render access** — grant your Render account access to
   `lukeadministrator/luke-core-engine` and `lukeadministrator/luke-core-ui`
   (the blueprint pulls each service from its own repo via `repo:`).
3. **Create the blueprint** — Render → New → Blueprint → connect this repo.
   Render reads `render.yaml` and provisions the DB + 6 services.
4. After first deploy, grab each engine's generated `CAMUNDA_ADMIN_PASSWORD`
   from Render → service → Environment.

## URLs (deterministic)

- dev: UI `https://platform-dev-ui.onrender.com` → engine `https://platform-dev-engine.onrender.com`
- qa:  UI `https://platform-qa-ui.onrender.com`  → engine `https://platform-qa-engine.onrender.com`
- uat: UI `https://platform-uat-ui.onrender.com` → engine `https://platform-uat-engine.onrender.com`

If Render assigns a suffixed hostname (name collision), update the matching
`VITE_API_BASE_URL` (UI) and `ALLOWED_ORIGINS` (engine) in `render.yaml`.

## Promotion flow

Push to a branch → that env redeploys. Promote dev → qa → uat by merging
`develop → qa → uat` (engine and ui repos).

## Production

Prod is intentionally **not** in this non-prod blueprint. Keep prod as its own
blueprint with a dedicated database (the existing `luke-core-engine/render.yaml`),
or add a parallel `platform-prod-*` set with a separate `luke-prod-db`.

## Cost note

6 web services + 1 Postgres. Static UIs are free; the three engines are
`starter` ($7 each) and the DB is `basic-256mb`. Downsize/upsize per env in
`render.yaml`.
