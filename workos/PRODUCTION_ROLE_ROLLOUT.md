# WorkOS — Production RBAC role rollout

Promote the four engine-mirrored roles + SSO/dsync role-assignment from the **Development** sandbox to
**Production**, so the WorkOS Production environment matches what the engine's `RoleCatalog` expects. This is
the "arm Production" half of core-engine **#61 / #104** (see memory `workos-rbac-mapping`).

> **Approval gate:** Production is `sandbox=false`. Per the standing constraint, **every mutation below runs
> only on explicit per-change approval** — nothing here is executed until you say "run step N". Reads were done
> to build this plan; no Production write has happened.

---

## Why now, and what it does *not* do

- **What it does:** makes Production's role catalog identical to Development's, and turns on IdP-driven role
  assignment (SSO + Directory Sync), so that when a customer connection eventually sends a `role` claim, WorkOS
  can map it to the right role instead of falling back to `member`.
- **What it does *not* do (yet):** there is **no live consumer** in Production today.
  - Production has **0 organizations** and **0 SSO/dsync connections** (verified 2026-07-27) → **zero blast
    radius**. Creating roles and flipping the assignment toggles changes behavior for **no existing user**.
  - The engine only *sources* a role from the login token once core-engine **#104 AC-3** (SSO/dsync
    login-token role sourcing + `org_id`→tenant resolution) is built — that work is **PARKED**. Until AC-3
    ships *and* a customer SSO/dsync connection is provisioned, these roles are dormant scaffolding.
- **Net:** this is a safe, additive, reversible "arming" step. Do it whenever convenient; it is **not** a
  prerequisite for the prod cutover and does not gate MVP (Forms/Email/Access).

---

## Live state (verified 2026-07-27, read-only)

| | Development `environment_01KTND3EV50F6AEVR3GSF7WDSQ` | Production `environment_01KTHG30DY4BN0EGDTA37J3195` |
|---|---|---|
| `tenant-admin`, `tenant-user`, `process-operator`, `task-worker` | ✅ all 4 present | ❌ **absent** |
| built-in `member` / `admin` | present | present |
| Organization resourceType id | `authz_resource_type_01KTND3EZQX8VFWCP53QFZ22Z8` | **`authz_resource_type_01KTHG30HQE5BT4G9TZJST98CP`** |
| roleConfig id | `role_config_01KTND3F16QWPE0314FDS4PXGV` | **`role_config_01KTHG30JTDDV0WT85MFEG3396`** |
| `defaultRole` | `member` | `member` |
| `ssoRoleAssignmentEnabled` | ✅ true | ❌ **false** |
| `dsyncRoleAssignmentEnabled` | ✅ true | ❌ **false** |
| `multipleRolesEnabled` | false | false |
| organizations / connections | (sandbox) | **0 / 0** |

> ⚠️ **Do not reuse Development's IDs.** `resourceTypeId` and `roleConfigId` are **per-environment**. The steps
> below use **Production's** IDs (bolded above). Production's built-in role IDs, for reference:
> `member` = `role_01KTHG30HTTVJ6Y93WKK1EBCQD`, `admin` = `role_01KTHG30TWW7E3KXJSD5KABFJQ`.

---

## The change set (5 mutations, each needs approval)

Slugs must stay **identical** to Development — the engine's `RoleCatalog.fromWorkosSlug()` matches on the slug
string. Names/descriptions are copied verbatim from Development for parity.

### Step 1 — create `tenant-admin`
```json
{"operation":"createRole","variables":{
  "slug":"tenant-admin",
  "name":"Tenant Admin",
  "description":"Org owner — full control of the tenant's runtime data. Mirrors engine RoleCatalog.TENANT_ADMIN (management dimension: tenantAdmin).",
  "resourceTypeId":"authz_resource_type_01KTHG30HQE5BT4G9TZJST98CP",
  "permissions":[]
}}
```

### Step 2 — create `tenant-user`
```json
{"operation":"createRole","variables":{
  "slug":"tenant-user",
  "name":"Tenant User",
  "description":"Standard tenant member. Mirrors engine RoleCatalog.TENANT_USER (management dimension: tenantUser).",
  "resourceTypeId":"authz_resource_type_01KTHG30HQE5BT4G9TZJST98CP",
  "permissions":[]
}}
```

### Step 3 — create `process-operator`
```json
{"operation":"createRole","variables":{
  "slug":"process-operator",
  "name":"Process Operator",
  "description":"Operate process instances. Mirrors engine RoleCatalog.PROCESS_OPERATOR (effective-access dimension: processUser).",
  "resourceTypeId":"authz_resource_type_01KTHG30HQE5BT4G9TZJST98CP",
  "permissions":[]
}}
```

### Step 4 — create `task-worker`
```json
{"operation":"createRole","variables":{
  "slug":"task-worker",
  "name":"Task Worker",
  "description":"Work assigned user tasks. Mirrors engine RoleCatalog.TASK_WORKER (effective-access dimension: taskUser).",
  "resourceTypeId":"authz_resource_type_01KTHG30HQE5BT4G9TZJST98CP",
  "permissions":[]
}}
```

> `organizationId` is intentionally omitted → the roles are **environment-wide** (assignable to any org),
> matching Development. Do **not** pass permissions — the engine, not WorkOS, enforces capability access; these
> roles carry no WorkOS permission slugs (same as Development).

### Step 5 — turn on IdP role assignment
Run **after** Steps 1–4 succeed. Only the two toggles are set; `defaultRole` and `multipleRolesEnabled` are
left untouched by omission.
```json
{"operation":"updateRoleConfig","variables":{
  "roleConfigId":"role_config_01KTHG30JTDDV0WT85MFEG3396",
  "ssoRoleAssignmentEnabled":true,
  "dsyncRoleAssignmentEnabled":true
}}
```

### Step 6 (optional) — priority order
Cosmetic (drives which role wins if multiple ever apply; `multipleRolesEnabled` is false so it's largely moot).
Only doable *after* Steps 1–4, using the **new Production role IDs** returned by those calls. Mirror
Development's order: `member, admin, tenant-admin, tenant-user, process-operator, task-worker`.
```json
{"operation":"updateRoleConfig","variables":{
  "roleConfigId":"role_config_01KTHG30JTDDV0WT85MFEG3396",
  "rolePriorityOrder":["role_01KTHG30HTTVJ6Y93WKK1EBCQD","role_01KTHG30TWW7E3KXJSD5KABFJQ","<tenant-admin id>","<tenant-user id>","<process-operator id>","<task-worker id>"]
}}
```

---

## Verify (read-only, after the change)
Re-run the roles query against Production and confirm **6 roles** and both toggles `true`:
```
query roles  environment_id=environment_01KTHG30DY4BN0EGDTA37J3195
```
Expect: `member, admin, tenant-admin, tenant-user, process-operator, task-worker`; roleConfig
`ssoRoleAssignmentEnabled=true`, `dsyncRoleAssignmentEnabled=true`, `defaultRole=member`.

## Rollback (if needed)
- **Toggles:** `updateRoleConfig` with `ssoRoleAssignmentEnabled:false, dsyncRoleAssignmentEnabled:false`
  (or `resetOrganizationRoleConfig` to environment defaults). Instant, zero-impact given 0 connections.
- **Roles:** `deleteRole` per role. With 0 memberships there is nothing to reassign; if any membership existed,
  `deleteRole` takes a replacement default role. Deleting is safe here precisely because Production has no orgs.

## End-to-end proof (defer until there's a consumer)
The real "a WorkOS role reaches the engine as the right capability" test needs (a) core-engine **#104 AC-3**
shipped and (b) a live customer SSO **or** Directory Sync connection in an org. Do that proof alongside the
first real customer onboarding, not now — there is nothing to exercise it against today.
