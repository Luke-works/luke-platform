# OBS-1 / OBS-4 — Turn on Sentry (frontend + backend)

All the code is shipped and **DSN-gated** — Sentry stays off until you set a DSN. This is env + one
CSP line. ~30 minutes.

## 1. Create Sentry projects (free tier)
In Sentry, create projects (one per app keeps issues clean, or group as you prefer):
- **React** platform → `luke-consumer-ui`, `luke-core-ui`
- **Spring Boot / Java** platform → `luke-core-engine`, `luke-auth-engine`, `luke-file-proxy`

Each project gives you a **DSN** (looks like `https://<key>@o<org>.ingest.sentry.io/<project>`).

## 2. Set the DSNs (all `sync:false`)

| App | Env var(s) | Where |
| --- | --- | --- |
| consumer-ui | `VITE_SENTRY_DSN`, `VITE_RELEASE` (optional) | consumer-ui service, per env |
| core-ui | `VITE_SENTRY_DSN`, `VITE_RELEASE` | core-ui service, per env |
| core-engine | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` (`dev`\|`qa`\|`prod`) | core-engine service |
| auth-engine | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | auth-engine service |
| file-proxy | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | file-proxy service |

> Frontend `VITE_*` vars are **baked at build time** — set them before the build/deploy. Backend
> `SENTRY_DSN` is read at boot. Both are no-op when unset (`if (!dsn) return` / `sentry.dsn` null).
> `send-default-pii=false` is already set on the backends — no PII is sent.

## 3. Pin the Sentry origin in the CSP (frontend only)
The browser SDK POSTs errors to Sentry's ingest host, so the UIs' **Content-Security-Policy** must
allow it or the reports are blocked. Add the ingest origin to `connect-src`:

```
connect-src 'self' https://*.ingest.sentry.io https://*.ingest.us.sentry.io <your existing origins>;
```

(Use the region host that matches your DSN — `ingest.sentry.io` or `ingest.<region>.sentry.io`.) This
ties into the CSP work (D12); if no CSP is enforced yet, there's nothing to change here yet — just
remember to include it when the CSP lands.

## 4. Verify
- **Frontend:** in a dev build with the DSN set, trigger an error (e.g. a throwing test button) and
  confirm it appears in Sentry, tagged with the environment + release.
- **Backend:** hit an endpoint that 500s (or add a temporary `throw`) and confirm the exception lands
  in the matching Sentry project. Remove the temporary throw.
