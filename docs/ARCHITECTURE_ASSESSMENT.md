# Velto Ops — Architecture Assessment & 10-Year Modernization Plan

> Commissioned by the founder. Purpose: an unflinching, evidence-based assessment of the
> current app (v220), and the plan for a modern build meant to run reliably for 10+ years —
> Toyota-grade reliability, German-grade engineering, whale-grade supervision.
> **Scope: assessment and plan only. Nothing is built here.** The rebuild happens in a
> separate project; this document is its founding charter.
>
> Companion doc: `docs/PROJECT_BRIEF.md` (the complete feature/data inventory — the
> rebuild's feature-parity checklist).

---

## 1. Executive verdict

**The product is excellent. The vehicle carrying it is at the end of its road.**

Velto Ops is not a bad app — it is a *successful prototype that got promoted to production
by winning*. The domain intelligence inside it (the iron-floor capacity math, the triage
ranking, the reorder rhythm engine, the payment-aware messaging, the Dhaka-time
discipline) is genuinely better than most funded startups' ops tooling. That logic, and
the Postgres schema underneath it, are the crown jewels — **they carry forward**.

What cannot carry forward is the delivery vehicle: one hand-edited 1.3 MB HTML file with
no types, no tests in-repo, no CI gate, whole-table data loading, and a security model
where the database trusts every logged-in employee with everything. Each of these has
already caused (or will predictably cause) a production incident.

| Dimension | Grade | One-line verdict |
|---|---|---|
| Product/domain logic | **A** | Deep, correct, business-fitted. Preserve at all cost. |
| Database schema & design | **B+** | Sound tables, idempotent migrations; RLS is a hole. |
| Front-end architecture | **D** | 1 file, 165 globals, 729 functions, string-built UI. |
| Data flow & scalability | **D+** | Full-table loads on every refresh; hard cliffs ahead. |
| Reliability engineering | **C−** | Clever fallbacks, but one typo kills login for all. |
| Security | **C−** | Auth solid (v218/220); DB-level authorization ≈ none. |
| Observability | **C** | client_errors + activity_log exist; nobody is paged. |
| Process (CI/testing/deploy) | **D** | No tests in repo, no gates, main = prod instantly. |
| **Overall system** | **C−** | Works today by skill and vigilance, not by design. |

**The founder's instinct is correct.** Every day on this architecture, changes get more
expensive and riskier — the classic backfoot. The move is a disciplined rebuild of the
**client only**, on top of the **same Supabase database**, run in parallel with the old
app until cutover. That single decision (§7.2) makes the migration low-risk.

---

## 2. What the current app gets RIGHT (the assets — carry these forward)

Honest engineering respects what works. These are not accidents; they are the spec:

1. **The domain logic.** The honest hours-range iron model (rates per garment class,
   count-override), Needs-Action triage ranking (commitment→blocked→money→improve),
   reorder rhythm detection, payment-aware Ready messages with honorific naming,
   promise-health verdicts, per-outlet scoping through one choke point. This is the
   product. The rebuild's job is to re-house it, not reinvent it.
2. **The database schema.** ~30 well-named tables, snapshot columns on orders (name/phone
   frozen at intake — correct for invoices), gap-free per-outlet numbering via RPC,
   `activity_log` as an audit trail, idempotent hand-written migrations with human-readable
   headers. Keep the schema; keep Supabase.
3. **Dhaka-time discipline.** All "today" logic runs through `dhakaDateStr()`. A classic
   off-by-one class of bugs, pre-eliminated.
4. **Graceful degradation habits.** Column-missing retry in `loadOrders` (app works before
   a migration is run), "run setup SQL" hints instead of crashes, localStorage profile +
   orders cache for offline opens, coalesced in-flight fetches, visibility-change
   reconciliation, a 3-minute polling backstop against dropped realtime.
5. **Client-side photo compression** (canvas → JPEG, quality-capped) before upload, with
   in-flight job tracking and a retry/repair queue (v197).
6. **Failure telemetry exists**: `window.onerror` → `client_errors` table with version +
   UA; the release ritual was verified headlessly (Playwright) before every ship.
7. **The v218/v220 auth hardening**: vendored auth library (no CDN dependency), watchdogs
   on every auth path, a login-screen health probe, the Web-Lock bypass. This class of
   thinking — *no silent failure states* — is exactly the 10-year standard; it's currently
   applied to one subsystem and must become the default everywhere.
8. **Documentation**: `docs/PROJECT_BRIEF.md` is a complete, accurate system inventory.
   Few teams of any size have this.

---

## 3. The current build, measured (v220, facts not vibes)

| Metric | Value | Why it matters |
|---|---|---|
| `index.html` size / lines | **1,316,945 bytes / 11,683 lines** | Whole app re-parsed on every load; unmergeable, undiffable at scale. |
| Functions in one shared scope | **729** | Any function can touch anything; no boundaries. |
| Top-level mutable globals | **165** (`let`/`const` at file scope) | The real state model: implicit, shared, unguarded. |
| Inline `onclick=` handlers | **478** | Logic wired through strings; no event delegation, no typing. |
| `.innerHTML` writes | **162** | UI = string concatenation; XSS discipline is manual (`he()`), every render is a full DOM teardown. |
| Inline `style="` attributes | **649** | Design drift; no enforceable system. |
| `getElementById` calls | **536** | DOM as a global variable store. |
| `try{` blocks / **silent empty catches** | 471 / **273** | More than half of all error handling deletes the error. Failures become mysteries. |
| `setTimeout/setInterval` | 46 | Timing-based coordination; race conditions live here. |
| Supabase query call-sites | 143 | Data access scattered through UI code; no repository layer. |
| Embedded base64 fonts | **297 KB (11 faces)** inside the HTML | Fonts re-shipped with every app update. |
| Tests in repo / CI gates on code | **0 / 0** (CI builds the APK only) | Correctness rests on one person's manual verification. |
| Framework / types / build | none / none / none | Every guarantee a modern toolchain gives is absent. |

---

## 4. Findings — where it hurts, with evidence

### F1. Single-file, single-scope: total blast radius **(severity: critical)**
One syntax error anywhere in the 11,683 lines breaks *everything*, including login — the
file is one `<script>`; parse failure = dead app for the whole company. This is not
hypothetical: sign-in was taken down in production this month, and every release risks it
again. There is no module boundary that can contain a mistake, no type checker to catch
it pre-ship, and no test suite in the repo to catch it post-edit. Two AI agents (or a
human + agent) cannot safely work in parallel: every change edits the same file.

### F2. Whole-table data loading: three hard scaling cliffs **(severity: critical, time-fused)**
`loadOrders()` downloads **the entire orders table** (paged ×1000 up to a 50,000-row
ceiling) into a global array — on app open, on reconnect, on the 3-minute backstop, on
every "refresh." `customer_stats` is loaded the same way. Consequences, in order of arrival:

- **Cliff 1 — egress & battery (already hit):** every device repeatedly re-downloading
  everything is what burned the 5 GB Supabase quota and caused the company-wide sign-out
  outage. Pro plan bought headroom; growth spends it.
- **Cliff 2 — localStorage (~1–2 years away):** the full orders array is cached in
  `localStorage` (`velto_orders`), which browsers cap at ~5 MB. At a few thousand orders the
  write starts failing silently — offline open degrades, then breaks.
- **Cliff 3 — memory/CPU on low-end Androids (~2–3 years):** parsing and re-scoping tens
  of thousands of order objects on every refresh, on the phones the staff actually carry,
  will make the app feel "jammed" — the exact symptom the founder already dislikes.

The dashboard RPCs (`dashboard_counts`, `dashboard_stats`, `cockpit_stats`) show the team
already knows the fix — server-side aggregation — but the pattern was never applied to
the main lists.

### F3. Security: the database trusts every employee with everything **(severity: high)**
Every table's RLS policy is `authenticated → using(true), with check(true)` — deliberate
for a small trusted team, and honestly documented. But concretely: **any logged-in account
(a rider, a worker) can read, modify, or delete any row in any table** — every payment,
every customer, the whole order history — by calling the API directly with the public anon
key. The UI hides the buttons; the database does not check. For a 10-year business system
this is the largest latent risk in the stack: one disgruntled ex-staff whose account
outlives their exit, one phone borrowed, one pasted script. Role checks must move into the
database (see §7.5).

### F4. Errors are swallowed, so failures become folklore **(severity: high)**
273 empty `catch` blocks mean most failures leave no trace. The founder's original
complaints — "app is slowing down *sometimes*," "status not updating *regularly*" — are
the natural language of swallowed errors: symptoms without evidence. `client_errors`
catches only uncaught exceptions; handled-and-ignored ones (the majority) vanish.

### F5. Statuses sync by polling, not by push **(severity: medium)**
Realtime subscriptions exist for tasks, task comments, and reorder actions — but **not for
orders**, the heart of the system. Order status freshness relies on a 3-minute interval
poll plus visibility-change reconciliation (each of which triggers F2's full reload).
Cross-outlet status lag is designed-in.

### F6. Releases depend on a manual ritual **(severity: medium)**
Three version markers (`APP_VERSION`, the badge, the `sw.js` CACHE name) must be bumped in
sync by hand; missing one ships stale code to installed PWAs. `main` deploys to production
in ~30 s with no staging environment, no automated test gate, and no canary. Database
migrations are pasted into the SQL editor by a human. Every one of these steps has already
produced a real near-miss in this project's history (duplicate installer names, header fix
that never deployed).

### F7. Nobody is watching **(severity: medium)**
`client_errors` and `activity_log` are write-only in practice — no alerting, no dashboards,
no uptime probe, no Supabase usage alarms. The egress overage was discovered by the whole
team being locked out, not by a warning at 80%. "Whale-level supervision" currently means
the founder noticing.

### F8. The bus factor is one **(severity: strategic)**
No types, no tests, no modules, 165 globals: the only complete model of this system lives
in one founder's head plus one AI session's context. `PROJECT_BRIEF.md` mitigates this on
paper; the architecture must mitigate it in code.

### Incident history reads as symptoms of exactly these findings
- Egress overage → company-wide sign-out **(F2 + F7)**
- Auth Web-Lock silent hang **(F4: silent failure state)**
- CDN dependency breaking invoices/sign-in risk → vendoring fix **(F6-class supply risk)**
- "Cards not arriving," "still the same, not deployed" confusions **(F6)**
- "App slowing down sometimes / status not updating" **(F2 + F4 + F5)**

---

## 5. The philosophy of the target build (what "Toyota + German + whale" means in practice)

- **Jidoka — stop the line.** Nothing reaches production that a machine hasn't verified:
  type-check, lint, unit tests, E2E on the money paths — all green or the merge is blocked.
  A human (or the founder) approves the PR; a robot enforces the floor.
- **Andon — the cord anyone can pull.** Every error is captured, attributed to a release,
  and *someone is notified*. No silent catches: errors are handled, logged, or surfaced —
  never deleted. Health is a dashboard, not a feeling.
- **Poka-yoke — make mistakes impossible, not forbidden.** Types instead of memory.
  Generated DB types instead of guessed column names. One version stamped by the build
  instead of three hand-edited markers. Migrations applied by pipeline, not paste.
- **German engineering — specified, then built.** The `PROJECT_BRIEF.md` feature inventory
  becomes the acceptance checklist; domain logic ports with unit tests that lock its
  behavior (the iron math already has known fixtures: 131 pcs → 13.6–17.9 h).
- **Boring technology.** Ten-year longevity comes from picking what will still be hiring-
  pool mainstream in 2036: TypeScript, React, Postgres. No exotic frameworks, no
  microservices, no Kubernetes — this is a ~10-seat ops system; its excellence is
  reliability, not scale theater.
- **The database is the constitution.** Supabase/Postgres stays. Both old and new clients
  speak to the same data during migration. Rollback is "open the old URL."

---

## 6. Target architecture

### 6.1 Stack (chosen for 2036, not 2026)

| Layer | Choice | Rationale |
|---|---|---|
| Language | **TypeScript, strict** | Types are the cheapest reliability money can buy. |
| Framework | **React 18+ + Vite** (SPA/PWA) | Internal tool: no SEO/SSR need. Vite = fast, simple, boring. (Next.js acceptable if server routes are ever wanted; not required.) |
| Server state | **TanStack Query** | Caching, retries, background refetch, request dedup — replaces 165 globals and the polling loops with a managed cache. |
| Local/UI state | Zustand (tiny) or React state | Minimal; most state is server state. |
| DB/auth/storage | **Supabase (kept)** + `supabase gen types` | Same project, same tables; generated types end guessed column names. |
| Validation | Zod at every boundary | Runtime guarantees where types can't reach (DB rows, forms). |
| Styling | Tailwind + design tokens ported from the current dark theme | The existing visual identity (the team likes it) becomes an enforced system. |
| PWA | `vite-plugin-pwa` (Workbox) | Generated, versioned service worker — the 3-marker ritual dies. Media cache strategy ported. |
| Native | Capacitor wrapper (kept) | Point it at the new URL; nothing else changes. |
| Testing | **Vitest** (domain units) + **Playwright** (E2E) | The current external test harnesses move in-repo and run on every PR. |
| CI/CD | GitHub Actions + Vercel previews + protected `main` | Every PR: typecheck→lint→unit→E2E→preview URL. Merge = deploy. |
| Monitoring | **Sentry** (errors+perf, release-tagged) + uptime probe + Supabase usage alerts | The andon cord. |
| Errors | Result-style handling; ESLint rule **bans empty catch** | F4 becomes structurally impossible. |

### 6.2 The strangler-fig migration model (the risk-killer)
**Rebuild the client; keep the database.** Old v220 and the new app run side by side
against the same Supabase project. Staff cut over role-by-role; any problem = reopen the
old URL. No data migration, no big-bang, no downtime window. v220 is feature-frozen
(critical fixes only) the day Phase 1 starts.

### 6.3 Repository shape (modular monolith — boundaries without microservice theater)
```
velto-app/
├── src/
│   ├── app/                  # routing, shell, auth guard, providers
│   ├── features/
│   │   ├── orders/           # intake, list+triage, detail, journey, status
│   │   ├── ironfloor/        # engine (pure TS) + floor page + count + alerts
│   │   ├── weekly/           # subscriptions + auto-task client
│   │   ├── outsource/        # partners + assignments
│   │   ├── customers/  finance/  tasks/  reorder/  team/  analytics/
│   │   └── roles/            # rider / worker / ironman homes (Bangla UI kept)
│   ├── domain/               # PURE logic, zero I/O: iron math, triage ranking,
│   │                         #   reorder rhythm, money, honorifics, dhaka-time
│   ├── data/                 # ALL Supabase access: typed queries, realtime, storage
│   ├── ui/                   # design system: tokens, cards, sheets, score cards
│   └── lib/
├── supabase/
│   ├── migrations/           # Supabase CLI–managed, CI-applied (existing SQL imported)
│   └── functions/            # notify-push, fcm-send, ai-copilot (ported)
├── tests/e2e/                # login, intake, status→Ready→msg, invoice, payment
└── .github/workflows/        # ci.yml (gates), deploy, apk
```
Rules: `domain/` imports nothing with I/O (it's where the crown jewels live, unit-tested);
UI never calls Supabase directly — only through `data/`.

### 6.4 Data flow redesign (kills F2 and F5)
- **Server does the filtering.** Screens query what they show: live orders = `status not in
  (Delivered,Cancelled)` (a few hundred rows), history = paginated on demand, search =
  server-side (`ilike`/FTS on number, name, phone). The full-table download is deleted.
- **Push, not poll.** Postgres realtime subscription on `orders` (and payments) →
  TanStack Query cache invalidation → statuses update in ~1 s on every device. Keep a
  slow reconcile as belt-and-suspenders.
- **Aggregates stay in SQL** — the existing `dashboard_counts`/`cockpit_stats` pattern,
  extended: score cards, iron-floor rollups, KPIs as views/RPCs.
- **Offline:** cache-read via TanStack persist (IndexedDB — no 5 MB wall), plus a small
  **outbox** for the two writes that matter in the field (status change, payment) which
  replays on reconnect. Everything else is online-required, honestly labeled.
- **Photos:** keep client compression; add width caps + thumbnail variants; media cache
  strategy carried into the generated SW.

### 6.5 Security hardening (kills F3) — phased, on the live DB, before cutover
1. Generate typed clients + inventory every table's real access needs per role (the brief
   already lists them).
2. Replace `using(true)` with **role-aware policies** driven by a `profiles.role` lookup
   (SECURITY DEFINER helper, as `is_admin()` already does): riders/workers write only
   what their job writes; `payments` and `expenses` become insert-only (reversal = the
   existing RPC, never delete); finance tables readable by admin/manager only.
3. Privileged mutations (role changes, merges, reversals) = SECURITY DEFINER RPCs only.
4. Storage bucket policies per prefix.
5. Ship RLS changes table-by-table with the old app still running (its calls are the
   regression test) — then cut over.

### 6.6 Supervision (kills F7) — the whale watchtower
- Sentry on both clients from day one, release-tagged, alert → founder's phone.
- Uptime probe on app URL + Supabase health (1-min cron, external).
- Supabase usage watcher: egress/storage/MAU checked daily; alert at 70%.
- Import the existing `client_errors` habit into Sentry; keep `activity_log` as the
  business audit trail.
- A one-page **runbook**: what to do when auth fails / egress spikes / deploy breaks —
  written once, linked from the repo README.
- Quarterly drill: restore a backup to a scratch project; prove RTO.

---

## 7. The migration plan (phases, cutover, and what "done" means)

**Sequencing logic:** smallest-blast-radius roles first; the money paths last (they get
the most E2E coverage before any user touches them). Each phase ends with real staff
using the new app for that scope, old app one tap away.

| Phase | Scope | Exit criterion |
|---|---|---|
| **0. Foundation** | Repo, CI gates, Sentry, staging Supabase, design tokens, auth (login/roles/guard), generated DB types. Port `domain/` pure logic **with unit tests locking current behavior** (iron math fixtures, triage order, honorifics, money). | CI red-blocks a seeded bug; login E2E green; domain tests green against known fixtures. |
| **1. Ironman + Rider** | `s-ironman` queue (Bangla), iron parcel flow; rider home, deliveries, tasks. Realtime on orders. | Oli and both riders work a full week on the new app only. |
| **2. Orders core** | Orders list + triage + search (server-side), order detail + journey, status updates, **intake**, invoice PDF, Ready message. | Managers take real orders end-to-end for a week; invoice + WhatsApp verified on iPhone & Android. |
| **3. Money** | Payments, collections, expenses, finance/P&L, cash recon — behind hardened RLS (§6.5). | A month-close reconciles to the old app's numbers exactly. |
| **4. Intelligence & ops** | Cockpit home (3 states, six-card score), Iron Floor page + count + alerts, Weekly (+10 AM cron kept), Outsourced, reorder loop, analytics, team admin, notifications/push. | Feature-parity checklist from `PROJECT_BRIEF.md` §9 fully ticked. |
| **5. Cutover & retirement** | Full-team default; Capacitor points at new URL; old app kept read-only 90 days at a legacy URL, then archived. | 30 incident-free days; v220 archived with a tag. |

**Feature parity source of truth:** `docs/PROJECT_BRIEF.md` (28 screens, every flow). The
rebuild is done when that inventory is checked off — not before.

**Working model:** built in a separate repo by AI agents (Codex/Claude) under PR review;
this repo stays the stable production system until Phase 5. Realistic calendar with
focused agent-driven development and the founder testing weekly: **~10–14 weeks**.

---

## 8. The 10-year operating standard (what must be true forever after cutover)

1. `main` is protected; nothing merges without green CI (types, lint, unit, E2E).
2. Zero empty catch blocks (lint-enforced). Every error is handled, logged, or surfaced.
3. All schema changes are CLI migrations in the repo, applied by pipeline, staging first.
4. Sentry alert routes to a human; weekly 15-minute health review (errors, egress, p95).
5. Backups verified by quarterly restore drill — a backup that's never been restored
   doesn't exist.
6. Dependencies updated monthly by bot PR (Renovate) — riding boring mainstream tech is
   what makes 2036 maintenance possible.
7. Any new feature ships with: types, at least one test, and a line in the brief.
8. The runbook stays one page and current.
9. One rule from the old app is constitutional: **Dhaka time, everywhere, always.**
10. And the old app's soul survives: no silent failure states — if something is wrong,
    the system says so, in plain words, to the right person.

---

## 9. What NOT to do (over-engineering traps that would betray the 10-year goal)

- **No microservices, no Kubernetes, no custom backend.** ~10 users. Supabase + a typed
  SPA is the correct size; complexity is the enemy of the decade.
- **No database rewrite.** The schema is good. Harden RLS, keep the data.
- **No framework-of-the-month.** React + Vite + Postgres will be boring in 2036 too —
  that's the point.
- **No big-bang rewrite-and-switch.** Strangler-fig or nothing; the business can't stop.
- **No feature invention during migration.** Parity first (the brief is the contract);
  new ideas queue for after Phase 5. (One founder-approved exception per phase, max.)
- **Don't discard the Bangla staff UX, the honorific logic, or the design language** —
  they are product, not debt.

---

## 10. Closing assessment

Velto Ops v220 is a hand-built machine that a skilled operator has kept winning with —
but it is one typo from a company-wide outage, one growth year from its scaling cliffs,
and one resignation from unmaintainability. The founder's call to rebuild now, before the
backfoot compounds, is the right call at the right time.

The plan above is deliberately unglamorous: same database, boring typed stack, tests as
law, alarms that page a human, staff migrated role-by-role with a one-tap rollback. That
is what Toyota reliability and German engineering actually look like in software — not
more moving parts, but fewer, each one specified, verified, and watched.

**Recommended first action:** stand up the new repo with Phase 0's CI skeleton and port
the `domain/` logic with its locking tests — the crown jewels move first, everything else
follows them.

*Assessment date: 2026-08-30 · App version assessed: v220 · Evidence: measured from the
live codebase (metrics in §3–§4); feature inventory in `docs/PROJECT_BRIEF.md`.*
