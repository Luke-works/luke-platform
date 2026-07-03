# Lukeflow security-testing program

A three-layer program: cheap and continuous at the bottom, expensive and manual at
the top. Layers 1–2 run between third-party engagements so Layer 3 finds the *unknown*,
not the obvious.

| Layer | What | Cadence | Where |
|---|---|---|---|
| **1 — Automated** | SAST (Semgrep), secret scanning (gitleaks), dependency/IaC (Trivy), DAST (OWASP ZAP baseline) | Every PR/push + weekly | CI (per-repo `security-scan.yml` + this repo's `zap-baseline.yml`) |
| **2 — Manual** | Focused pentest of the risk surfaces by a human (Burp/`curl`) | Each release | [`SECURITY_TESTING.md`](./SECURITY_TESTING.md) |
| **3 — Third-party** | Independent engagement + retest, attestable report | Pre-launch, annually, after big changes | [`PENTEST_SCOPE.md`](./PENTEST_SCOPE.md) |

Plus **CodeQL** (already on the JS/TS repos) and **Dependabot** (fleet-wide) feeding the
same GitHub Security tab.

---

## Layer 1 — how it runs

**Per-repo static scanning** — [`security-scan.template.yml`](./security-scan.template.yml)
is deployed as `.github/workflows/security-scan.yml` in each service/UI repo. It runs:

- **Semgrep** (`--config auto`) — SAST across Java/Python/JS/TS.
- **gitleaks** — secret scanning over full history.
- **Trivy** (`fs`) — dependency CVEs + Dockerfile/IaC misconfig + secrets.

It is **informational by design** (every step `continue-on-error`) so a pre-existing
finding can't break delivery. Findings upload as SARIF to each repo's Security tab.

> **To make it gating:** triage the baseline in the Security tab, fix/allowlist the
> noise, then delete the `continue-on-error` flags on the categories you want to block on
> (start with secrets + Critical deps). This is the same "informational → gate after
> baseline" path used for the existing lint/dep checks.

**DAST** — [`.github/workflows/zap-baseline.yml`](../.github/workflows/zap-baseline.yml)
runs an OWASP ZAP **baseline** (passive-only) scan against the qa consumer-ui, gateway,
and ops console weekly and on demand. Baseline never attacks, so it's safe against qa.
Active scans belong in a Layer-3 window, not CI.

To re-deploy the per-repo workflow after editing the template:

```bash
for r in luke-core-engine luke-auth-engine luke-file-proxy luke-agents luke-consumer-ui luke-core-ui; do
  cp security/security-scan.template.yml ../$r/.github/workflows/security-scan.yml
done
```

## Layer 2 — how it runs

Before each release, a tester works through [`SECURITY_TESTING.md`](./SECURITY_TESTING.md)
against qa: six suites (tenant isolation, auth/session, public surfaces, file-proxy,
secrets/internal, business logic), each a table of concrete cases with expected results.
The regression cases re-verify the fixes from the 2026-07 internal audit.

## Layer 3 — how it runs

[`PENTEST_SCOPE.md`](./PENTEST_SCOPE.md) is the engagement package: objectives, in/out of
scope, the threat model (actors → questions), rules of engagement, the authorization &
legal checklist (**including notifying Render before active testing**), what we provide the
firm, and expected deliverables. Use it to authorize internal active testing too.

---

## Ground rules (all layers)

- **Staged only.** qa/uat, never prod, never real customer data.
- **Third-party services are out of scope** — WorkOS, Groq, Postmark, Vapi, Nango, AWS,
  Render. Test our integration, not their platforms.
- **Notify the hosting provider** before any active/volumetric testing.
- Track findings as **private** GitHub security advisories per repo.

## Known gaps to hand testers (so they focus on the unknown)

- Internal shared `X-Internal-Key` can read any tenant's secrets with the key (#60) —
  per-tenant keys are the planned fix; verify it's never network-exposed.
- Capability billing/tier gate is deferred (auto-subscribe on grant).
- core-ui CSP is Report-Only (not yet enforcing).
- core-ui lint is not yet gating (160 known issues).
