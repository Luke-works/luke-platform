# 🧪 Master Test Script — Luke Platform (dev/qa)

**Who this is for:** new developers checking that the recent security & bug fixes work, by **using the app like a normal person** — no terminals, no `curl`, just logging into the portals and looking at what happens.

**The golden rule:** if a step does NOT do what the ✅ line says, don't panic and don't try to fix it yourself. Copy the **"📋 If it looks wrong, send Claude this"** prompt under that test, fill in the blanks, and paste it to Claude. That's it.

---

## Before you start (get these ready)
You'll need logins for the **dev/qa** environment (ask your lead for the URLs + accounts):

| Portal | What it is | URL (fill in) | Login |
|---|---|---|---|
| **Consumer Portal** | The app end-users use (forms, inbox) | `__________` | a normal user account |
| **Ops Console** | The admin/operator dashboard | `__________` | an operator/admin account |

Also handy: a **second user account** in a **different organization/tenant** (for the "can't see other people's data" tests), and your browser's **DevTools** (press `F12` → we'll only use the "Console" and "Application" tabs, and only when a test says so).

> 💡 Everything below is on **dev/qa** (the `develop` branch). Don't test on prod.

---

## How to ask Claude to investigate (the magic formula)
When something looks wrong, Claude needs 4 things. Just fill in this template:

> **In [PORTAL/REPO], I expected [WHAT SHOULD HAPPEN] but I saw [WHAT ACTUALLY HAPPENED].**
> **I did these steps: [1, 2, 3].**
> **Here's the related change: [PR # from the test].**
> **Please investigate and tell me if it's a bug, a config issue, or expected.**

Each test below already has this filled in for you under "📋 If it looks wrong" — just add what you actually saw.

---

# PART 1 — Consumer Portal (the end-user app)

### ✅ Test 1.1 — Your inbox/tasks still load (auth fix, core-engine PR #47)
**What changed:** the task inbox used to be open to anyone; now it requires you to be logged in.
**Steps:**
1. Log into the **Consumer Portal** as a normal user.
2. Open the **Inbox** (or Tasks) page.

- ✅ **Looks right:** your tasks appear, same as always.
- ❌ **Looks wrong:** the inbox is empty, spins forever, or shows an error like "Unauthorized / 401".

📋 **If it looks wrong, send Claude this:**
> In the Consumer Portal inbox, I expected my tasks to load but I saw [empty / spinner / "Unauthorized" — say which]. Steps: logged in as a normal user, opened Inbox. Related change: core-engine PR #47 (new /api auth filter). This might be the gateway-token config (`LUKE_AUTH_GATEWAY_ENABLED`). Please investigate whether it's a config issue or a bug.

---

### ✅ Test 1.2 — Your form edits are never lost silently (data-loss fix, consumer-ui PR #41)
**What changed:** if a save fails, the app now clearly says **"Save failed — retry"** instead of pretending it saved.
**Steps (Form Builder):**
1. Open a form in the **builder** (edit mode).
2. Turn your **Wi-Fi off** (or use DevTools → Network → "Offline").
3. Change a field (e.g. rename a label).
4. Watch the little save status text near the top.

- ✅ **Looks right:** it shows **"Save failed — retry"** (in red). Turn Wi-Fi back on, click **Save** → it shows "Draft saved".
- ❌ **Looks wrong:** it says **"Draft saved"** while offline, or just spins on "Saving…" forever with no error.

**Steps (Filling a form):**
1. Open a form to **fill** it.
2. Turn Wi-Fi off, type something in a field, wait ~1 second.

- ✅ **Looks right:** you see **"Couldn't save — check your connection"**.
- ❌ **Looks wrong:** it says "Saved", or nothing happens at all.

📋 **If it looks wrong, send Claude this:**
> In the Consumer Portal [Form Builder / Form Fill], I expected a "Save failed / Couldn't save" message when offline, but I saw [what you saw]. Steps: opened the form, went offline, edited a field. Related change: consumer-ui PR #41. Please investigate whether saves are failing silently again.

---

### ✅ Test 1.3 — Public (shared) form links still work without logging in (auth-engine PR #44)
**What changed:** we hardened the gateway, but real public form links must still work for people who aren't logged in.
**Steps:**
1. Get a **public/shared form link** (the kind you'd email to an outside person — it has `/embed/` or `/public/` in it).
2. Open it in a **private/incognito window** (so you're not logged in).

- ✅ **Looks right:** the form loads and you can fill + submit it.
- ❌ **Looks wrong:** it shows "Bad Request", "Unauthorized", or a blank page.

📋 **If it looks wrong, send Claude this:**
> A public form embed link doesn't load when I'm not logged in — I saw [error]. Steps: opened the share link in incognito. Related change: auth-engine PR #44 (proxy path-traversal hardening). Please check the public-path handling didn't block a legit embed link.

---

### ✅ Test 1.4 — Changing your password requires your current password (auth-engine PR #45)
**What changed:** you can no longer change a password without proving you know the old one.
**Steps:**
1. Log in, go to **Account / Profile → Change Password**.
2. Try to set a new password but **leave "current password" blank** (or type a wrong one).

- ✅ **Looks right:** it's **rejected** ("current password is required" / "incorrect").
- ❌ **Looks wrong:** the password changes anyway.

📋 **If it looks wrong, send Claude this:**
> In the Consumer Portal, I changed my password WITHOUT giving the correct current password and it succeeded. Steps: Account → Change Password, left current blank. Related change: auth-engine PR #45. This is a security bug — please investigate.

---

### ✅ Test 1.5 — Social / SSO login still works (auth-engine PR #45)
**What changed:** social login (Google/Microsoft/etc.) now has extra anti-forgery protection.
**Steps:**
1. Log out. On the login screen, click **"Sign in with Google"** (or your provider).
2. Complete the provider login.

- ✅ **Looks right:** you land back in the app, logged in.
- ❌ **Looks wrong:** you get bounced back with an error like `invalid_state`, or login never completes.

📋 **If it looks wrong, send Claude this:**
> Social/SSO login fails — after the Google screen I got [error, e.g. "invalid_state"]. Steps: logged out, clicked Sign in with Google. Related change: auth-engine PR #45 (OAuth state cookie). The state cookie may not be round-tripping (needs HTTPS). Please investigate.

---

### ✅ Test 1.6 — The app loads with no hidden errors (auth-engine PR #46, CORS)
**What changed:** we tightened which request headers the gateway accepts.
**Steps:**
1. Log into the Consumer Portal and use it normally (open a few pages).
2. Press **F12 → Console** tab. Look for **red** errors mentioning **"CORS"** or "blocked by … policy".

- ✅ **Looks right:** the app works and there are **no CORS errors** in the Console.
- ❌ **Looks wrong:** you see a red CORS error mentioning a blocked header.

📋 **If it looks wrong, send Claude this:**
> The Consumer Portal shows a CORS error in the browser console: [paste the red error]. Related change: auth-engine PR #46 (CORS header allowlist). It probably needs that header added to the allowlist. Please investigate.

---

### ✅ Test 1.7 — The AI form builder still works (agents PR #42)
**What changed:** we added abuse-protection (rate limits, size limits) to the AI form builder.
**Steps:**
1. In the builder, use the **"describe your form"** AI box. Type something normal like *"Add a name, email, and phone number."*

- ✅ **Looks right:** it builds/updates the form as usual.
- ❌ **Looks wrong:** it errors immediately, or says "Too Many Requests" on your very first normal try.

📋 **If it looks wrong, send Claude this:**
> The AI form builder fails on a normal request — I saw [error]. Steps: typed a short normal prompt. Related change: agents PR #42 (rate limit + input caps). Please check the limits aren't too strict for normal use.

---

# PART 2 — Operations Console (the admin dashboard)

### ✅ Test 2.1 — Your login isn't left lying around after you close the browser (core-ui PR #43)
**What changed:** the operator password is no longer stored in a way that survives closing the browser.
**Steps:**
1. Log into the **Ops Console**.
2. **Refresh** the page (F5).
   - ✅ You're **still logged in** (refresh is fine).
3. **Close the whole browser**, reopen it, and go to the Ops Console again.
   - ✅ **Looks right:** it asks you to **log in again**.
   - ❌ **Looks wrong:** it remembers you and logs you straight in.
4. *(Optional, slightly techy):* F12 → **Application** tab → Storage. Look in **Session Storage** (should have a `luke-core-auth-storage` entry) and **Local Storage** (should **not** have it).

📋 **If it looks wrong, send Claude this:**
> In the Ops Console, after fully closing and reopening the browser I was still logged in (or I found credentials in Local Storage). Related change: core-ui PR #43 (creds → sessionStorage). Please investigate whether credentials are still persisting to localStorage.

---

### ✅ Test 2.2 — There's no "admin/admin" backdoor (core-engine PR #48)
**What changed:** the system refuses to run with the default password `admin`.
**Steps:**
1. Log into the Ops Console with the **real** admin account → should work normally.
2. Log out. Try to log in with username **`admin`** and password **`admin`**.

- ✅ **Looks right:** the real account works; **`admin`/`admin` is rejected**.
- ❌ **Looks wrong:** `admin`/`admin` logs you in.

📋 **If it looks wrong, send Claude this:**
> The Ops Console accepts admin/admin as a login. Related change: core-engine PR #48 (fail-closed admin password). Please investigate — the CAMUNDA_ADMIN_PASSWORD env may not be set in this environment.

---

### ✅ Test 2.3 — You only see your own organization's data (core-engine PR #47 / #21)
**What changed:** stronger checks that you can't see another organization's (tenant's) data.
**Steps:**
1. Log into the Ops Console (or Consumer Portal) as a user in **Organization A**.
2. Look at the lists (processes / tasks / forms). Note what's there.
3. If you have a tenant switcher, switch to **Organization B** (one you DON'T belong to) — or try the second account.

- ✅ **Looks right:** you only ever see **your** organization's items; you can't pull up another org's data.
- ❌ **Looks wrong:** you can see another organization's processes/tasks/forms.

📋 **If it looks wrong, send Claude this:**
> I can see data from an organization I don't belong to in [portal/page]. Steps: logged in as a user of Org A, then [what you did], and saw Org B's [processes/tasks/forms]. Related change: core-engine PR #47 / issue #21 (tenant isolation). This is a serious data-leak — please investigate immediately.

---

### ✅ Test 2.4 — The dashboards load (general health after the OOM fix, core-engine PR #49)
**What changed:** we reduced the memory pressure that was crashing the engine.
**Steps:**
1. Use the Ops Console for a few minutes — open process lists, tasks, history, a couple of detail pages.

- ✅ **Looks right:** pages load and stay responsive; no repeated "502 / 503 / service unavailable" errors.
- ❌ **Looks wrong:** the app keeps going down, showing 502/503, or feels like it restarts mid-use.

📋 **If it looks wrong, send Claude this:**
> The Ops Console keeps showing 502/503 errors or seems to restart. Related change: core-engine PR #49 (OOM/memory relief). The service may still be running out of memory — please check whether it needs the instance upgraded.

---

# PART 3 — Forms & Email plumbing (Consumer Portal)

### ✅ Test 3.1 — A submitted form actually goes through (capability + core-engine)
**What changed:** lots of backend hardening around form submission and the email/process step.
**Steps:**
1. Fill out and **submit** a form as an end user.
2. If that form triggers an email or a review task, check the email arrives / the task shows up in the Inbox.

- ✅ **Looks right:** the submission succeeds and the follow-up (email/task) happens.
- ❌ **Looks wrong:** submit errors out, or the email/process never happens (esp. a "503 / Service Unavailable" on submit).

📋 **If it looks wrong, send Claude this:**
> Submitting a form fails or the follow-up email/task never happens — I saw [what happened]. Steps: filled and submitted a form that should [send email / create a task]. This may relate to the internal shared-secret config (capability-engine PR #41) or the process-start path. Please investigate whether it's a config or code issue.

---

### ✅ Test 3.2 — Spamming a public form gets throttled (capability-engine PR #42)
**What changed:** the public form submit has a per-link rate limit that can no longer be wiped/bypassed.
**Steps:**
1. Open a **public form link** (incognito). Submit it quickly several times in a row (20+).

- ✅ **Looks right:** after a bunch of rapid submits it starts saying **"Too many submissions, try again shortly."**
- ❌ **Looks wrong:** you can submit unlimited times with no throttle ever.

📋 **If it looks wrong, send Claude this:**
> A public form lets me submit unlimited times with no rate limit. Steps: opened the public link, submitted 20+ times fast. Related change: capability-engine PR #42 (embed rate-limit). Please investigate whether the limiter is working.

---

### ✅ Test 3.3 — Tenant email setup still works (capability-engine PR #42, secrets)
**What changed:** we made the secret-key handling safer; existing saved secrets must still work.
**Steps:**
1. In the Consumer Portal, go to **Email setup** for your org (the OTP / "verify your company email" flow), or send a test email if that exists.

- ✅ **Looks right:** email verification / sending works exactly as before.
- ❌ **Looks wrong:** it errors with something about secrets, decryption, or keys.

📋 **If it looks wrong, send Claude this:**
> Email setup/sending is broken with an error about [secrets/decryption/keys]. Steps: went to Email setup and [what you did]. Related change: capability-engine PR #42 (SecretCrypto key handling). Stored secrets may not be decrypting — please investigate urgently.

---

## ✅ Final checklist (tick as you go)

| # | Test | Portal | Pass? |
|---|---|---|---|
| 1.1 | Inbox loads when logged in | Consumer | ☐ |
| 1.2 | No silent data loss on save | Consumer | ☐ |
| 1.3 | Public form link works (no login) | Consumer | ☐ |
| 1.4 | Change password needs current one | Consumer | ☐ |
| 1.5 | Social/SSO login works | Consumer | ☐ |
| 1.6 | No CORS errors in console | Consumer | ☐ |
| 1.7 | AI form builder works | Consumer | ☐ |
| 2.1 | Login cleared after browser close | Ops | ☐ |
| 2.2 | No admin/admin backdoor | Ops | ☐ |
| 2.3 | Can't see other org's data | Ops/Consumer | ☐ |
| 2.4 | Dashboards stay up (no 502/503) | Ops | ☐ |
| 3.1 | Form submit + follow-up works | Consumer | ☐ |
| 3.2 | Public form gets throttled | Consumer | ☐ |
| 3.3 | Tenant email setup works | Consumer | ☐ |

**Anything not ✅?** Use the "📋 If it looks wrong, send Claude this" prompt under that test. When in doubt, over-share what you saw (screenshots help) — there's no such thing as too much detail.

---
*Covers the security & bug fixes deployed to dev/qa (PRs: core-engine #47/#48/#49, auth-engine #44/#45/#46, agents #42, capability-engine #41[pending]/#42, consumer-ui #41, core-ui #43). Generated to help new devs validate behavior from the portals — no command line required.*
