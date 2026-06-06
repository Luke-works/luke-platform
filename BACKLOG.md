# Luke platform — backlog

Cross-cutting follow-ups tracked at the platform level.

## Security

### Operator-gate capability-engine admin routes
**Status:** open · **Added:** 2026-06-05

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
