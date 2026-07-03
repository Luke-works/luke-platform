# Layer 2 — Manual penetration-test playbook

Executable test cases for a human tester (Burp Suite / `curl`) against a **staged**
Lukeflow environment. Each case is grounded in the real architecture and the surfaces
the internal audit flagged as highest risk. Run these before every release and hand
them to any third-party firm (Layer 3) as the starting scope.

> **Rules:** qa/uat only, never prod, never real customer data. See
> [`PENTEST_SCOPE.md`](./PENTEST_SCOPE.md) for authorization and rules of engagement.

## Prerequisites

- Two **test tenants** — call them **A** and **B** — each with an owner and a plain member.
  Cross-tenant tests need a user who is **owner of A** and **only a member of B**.
- Tools: Burp Suite (Pro for the active bits), `curl`, `jq`, a JWT decoder.
- Base URLs (qa): consumer-ui `https://consqa.lukeflow.com`, gateway `https://authqa.lukeflow.com`,
  engine `https://platform-qa-engine.onrender.com`, core-ui `https://platform-qa-ui.onrender.com`.
- A valid gateway **act-as** bearer token per test user (from a normal login), and the
  operator Basic cred for `/engine-rest` (staged only).

Record each case as **PASS** (control held) / **FAIL** (finding) with the raw request/response.

---

## Suite 1 — Tenant isolation & IDOR *(highest priority)*

The platform is multi-tenant; a cross-tenant read/write is a critical finding.

| # | Test | Steps | Expected (PASS) |
|---|---|---|---|
| 1.1 | **Cross-tenant org-admin escalation** (regression of the fixed bug) | As a user who owns tenant A and is a plain member of B, call every `/api/org/**` admin action against B (`X-Tenant-Id: B`): create user, set role, approve access, grant capability. | All **403** — the scoped `owner:<tenant>` check must reject B. |
| 1.2 | **Access-request approval cross-tenant** | Same actor calls `POST /api/access-requests/{id}/approve` for a request in B. | **403**. |
| 1.3 | **Capability-data IDOR** | As an A member, request form/signature/document/instance objects by an id that belongs to B (guess/enumerate ids; use ids observed in A and mutate). | **404/403** — reads are `findByIdAndTenantId`; no B data returned. |
| 1.4 | **`X-Tenant-Id` header forgery** | With A's token, set `X-Tenant-Id: B` on capability + engine-rest routes. | Rejected — tenant is membership-verified server-side, not trusted from the header. |
| 1.5 | **Owner transfer / last-owner** | Transfer ownership of A to a member, then try to remove the last owner. | Transfer works; removing the final owner is **409** (last-owner guard). |
| 1.6 | **Candidate-group namespacing** | As an A admin, try to add a user to a `B:*` candidate group. | Rejected — groups are tenant-prefixed. |

---

## Suite 2 — Authentication, session & rate limiting

| # | Test | Steps | Expected (PASS) |
|---|---|---|---|
| 2.1 | **Token forgery / weak validation** | Present a token signed by a different key; a token with a wrong `aud`/`iss`; an expired token. | All rejected — JWKS verify is fail-closed, audience-bound (strict-validation). |
| 2.2 | **act-as token abuse** | Capture an act-as token; replay it; alter the `sub`; use it after the source session ends. | Rejected — RS256-signed, server-minted, expiry-bound; never mint from client input. |
| 2.3 | **Rate-limit bypass via XFF** (regression of the fixed bug) | Brute-force `/auth/login` / `/service/token`, sending a **new random `X-Forwarded-For`** each request. | Still **429** after the threshold — the key is derived from trusted-proxy hops, not the spoofable leftmost hop. |
| 2.4 | **Header stripping** | Send `x-user-id`, `x-internal-key`, `x-dev-user` inbound through the gateway. | Stripped before proxying — client can't assert identity. |
| 2.5 | **OTP brute-force (respond flow)** | On `/respond/:token`, request an OTP then brute the code. | Locked out / rate-limited; codes single-use and short-lived. |
| 2.6 | **Path canonicalization** | Hit the proxy with `..`, `%2e%2e`, encoded traversal in the path. | Rejected before the public/protected decision. |
| 2.7 | **Dev backdoors off in staged** | Attempt any `dev-mode` impersonation path. | Disabled — needs BOTH `dev-mode` AND the `dev` profile (not set in qa/prod). |

---

## Suite 3 — Public / anonymous surfaces (embed, respond, webhooks)

These are internet-facing with token-only auth — the widest attack surface.

| # | Test | Steps | Expected (PASS) |
|---|---|---|---|
| 3.1 | **Embed token forge/replay** | Forge an embed HMAC token; tamper the tenant/form claims; replay a revoked token. | Rejected — HMAC-verified, tenant-scoped, revocable. |
| 3.2 | **Embed framing** | Load the embed page inside an attacker origin iframe. | Blocked by per-tenant `frame-ancestors` (and X-Frame-Options on the dashboard). |
| 3.3 | **Author JS on public fill** (regression of the fixed bug) | Publish a form with `customConditionalJs`/`calculateValueJs`; fill it via the **public embed** and **respond** page; attempt DOM/`fetch`/cookie access from the snippet. | Author JS does **not execute** on embed/respond (`allowJs={false}`); the sandbox shadows host globals even where JS is allowed. |
| 3.4 | **Webhook signature bypass** | Post to the Vapi/Nango webhook endpoints with no signature, a wrong signature, and a replayed body. | Rejected when a secret is configured (prod-asserted by `EdgeHardeningGuard`); no unsigned acceptance in staged-with-secret. |
| 3.5 | **Submission/stored XSS** | Submit form values / rich-text containing `<script>`, `<img onerror>`, `javascript:`/`data:` URLs; view them in Form Inbox, PDF render, and email preview. | Escaped/sanitized (DOMPurify hardened profile; render harness `allowJs=false`; email URL allow-list; sandboxed preview iframe). |
| 3.6 | **CSP** | Inspect response headers on the dashboards; attempt inline-script injection. | Security headers present; CSP (Report-Only today) logs violations — confirm the report endpoint receives them before enforcing. |

---

## Suite 4 — file-proxy (render + document proxy)

| # | Test | Steps | Expected (PASS) |
|---|---|---|---|
| 4.1 | **SSRF** | Try to make any file-proxy endpoint fetch an attacker URL (render payload, document link, S3 endpoint override). | No user-controlled outbound fetch — S3 endpoint is config-only. |
| 4.2 | **S3 key / path traversal** | Request documents with `..`, absolute paths, or another tenant's key prefix. | Rejected — keys are tenant-prefixed and normalized. |
| 4.3 | **Presigned-URL scope** | Obtain a presigned URL; try to widen the path/verb; use after expiry. | Scoped + short-lived; least-privilege IAM (per-bucket, no admin). |
| 4.4 | **Render payload injection** | Embed `</script>`, HTML, and JS in submission values passed to the PDF harness. | Neutralized — payload JSON-escaped (`<`→`<`), assets injected via DOM, `allowJs=false`. |
| 4.5 | **Render DoS / back-pressure** | Fire many concurrent `/internal/render` calls. | Bounded by the semaphore; excess returns **503 + Retry-After**, service stays responsive (no thread pileup). |
| 4.6 | **Direct-to-proxy identity spoofing** | Reach file-proxy directly (bypassing the gateway) and set `X-User-Id`. | Blocked by network isolation + core-engine remains the authorizer; confirm the internal-network boundary. |

---

## Suite 5 — Secrets & internal endpoints

| # | Test | Steps | Expected (PASS) |
|---|---|---|---|
| 5.1 | **Internal shared-secret reach** (known gap #60) | From outside the private network, hit `/api/internal/**` (e.g. `/api/internal/secrets/{tenant}/{name}`) with/without the `X-Internal-Key`. | Not reachable externally; fail-closed without the key. **Note:** one shared key can read *any* tenant with the key — verify it's never network-exposed; per-tenant keys are the planned fix. |
| 5.2 | **Actuator exposure** | Request `/actuator/env`, `/beans`, `/configprops`, `/health` (authed + unauthed). | Only `health,info,metrics` exposed; sensitive endpoints 404; health detail not leaking internals to anon (prod). |
| 5.3 | **Dev-default keys** | Confirm staged/prod isn't running with `…-change-me` embed/secrets keys. | `InsecureKeyGuard` fail-fast under the prod profile. |
| 5.4 | **Prod hardening guards** | On a prod-profile boot with lenient config, confirm refusal (CORS localhost default, strict-validation off, stable key off, unenforced webhook secret). | Startup **fails fast** (`AuthHardeningGuard`, `EdgeHardeningGuard`, `InsecureKeyGuard`). |

---

## Suite 6 — Business logic & authorization

| # | Test | Steps | Expected (PASS) |
|---|---|---|---|
| 6.1 | **Capability tier gating** | As a member without a grant, call a capability API directly (bypassing UI hiding). | Rejected — effective access needs subscription **and** per-user grant. |
| 6.2 | **Access-request self-approval** | Create an access request and try to approve your own. | Only an owner approves; self-approval rejected unless you are the owner. |
| 6.3 | **Auto-subscribe abuse** | Trigger org-admin grant flows; confirm tier limits (billing gate is deferred). | Grants stay within the tenant; note the deferred billing gate as a business risk. |
| 6.4 | **Mass assignment / over-posting** | Add unexpected fields (role, tenant, ids) to create/update bodies. | Ignored — server sets authority fields, not the client. |

---

## Reporting

For each FAIL: surface, severity (CVSS or Critical/High/Med/Low), reproduction (raw
request/response), impact, and a fix suggestion. Track findings as **private** GitHub
security advisories per repo (the backlog convention), not public issues.
