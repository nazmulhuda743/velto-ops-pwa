# Velto Ops — Complete Project Brief

> **Read this first.** This document is the single source of truth for the Velto Ops
> application: what it is, how it is built, how it deploys, every feature, the full
> data model, the conventions, the gotchas, and the history. It is written for an AI
> coding agent (Codex) and for the founder. Nothing important is intentionally left out.
> Current production version at time of writing: **v220**.

---

## 0. TL;DR for the agent

- **Velto Ops** is a production PWA that runs a real two-outlet laundry/dry-clean
  business in Uttara, Dhaka. It is used daily by the owner, managers, riders,
  workers and the ironman.
- **The entire front end is ONE file:** `index.html` (~1.3 MB, ~11,700 lines).
  Vanilla JavaScript, no framework, **no build step**. You edit `index.html` directly.
- **Backend is Supabase** (Postgres + Auth + Storage + Realtime + Edge Functions +
  pg_cron). Schema changes are hand-written SQL in `supabase/*.sql`, run manually by
  a human in the Supabase SQL Editor.
- **Hosting is Vercel**, which auto-deploys production from the **`main`** branch.
  Push to `main` → it is live in ~30s. Feature branches make preview deploys only.
- **A service worker (`sw.js`)** makes it installable/offline and caches assets.
  Every release bumps three version markers (see §6). Miss one and clients serve stale code.
- There is also a thin **Capacitor Android wrapper** (`apk/`) that loads the live URL.
- **Golden rule:** this is live software for a running business. Small, verified,
  reversible changes. Never break sign-in, order intake, invoice, or payments.

---

## 1. Business context (what the software actually runs)

**Velto** is a laundry, wash-iron and dry-cleaning business with:
- **Two retail outlets:** `Velto Sector 11` (code `S11`) and `Velto RUAP` (code `RUAP`).
- **One central Iron Facility** where the in-house ironman (Oli Ullah / "Oli") irons garments.
- **A wash plant / vendor** (external) that does washing. The vendor does **no ironing**;
  all wash-iron and dry-clean items come back to Velto's facility for ironing.

**Physical flow of an order:**
1. Customer drops off / rider picks up garments at an outlet.
2. **Only-iron** items go straight to the Iron Facility.
3. **Wash-iron** and **dry-clean** items go to the wash plant first, come back (usually
   next evening ~9–10 PM), then go to the Iron Facility.
4. Ironed items return to the outlet, pass QC, become **Ready**, then are delivered.

**People / roles:** `admin` (owner — full access), `manager` (per-outlet ops + finance),
`rider` (deliveries/pickups + tasks), `worker` (floor/QC), `ironman` (the iron facility queue).

**Founder / primary admin:** Nazmul (email `nazmulhuda0327@gmail.com`).

**Language:** UI is mostly English with Bengali (Bangla) in staff-facing flows (workers,
riders, ironman). Currency is Bangladeshi Taka (৳). Timezone is **Asia/Dhaka (UTC+6)** —
all "today"/date logic must use Dhaka time (`dhakaDateStr()` helper).

---

## 2. Tech stack

| Layer | Choice | Notes |
|---|---|---|
| Front end | Single `index.html`, vanilla JS/CSS | No React/build. Scoped `<style>` blocks, inline SVG. |
| Fonts | Space Grotesk / Inter / JetBrains Mono | Embedded as base64 `@font-face` in the file. |
| Auth/DB/Storage | Supabase | Postgres + GoTrue auth + Storage + Realtime + Edge Functions + pg_cron/pg_net. |
| Supabase JS | `@supabase/supabase-js@2.110.6` | **Vendored** at `vendor/supabase-js-2.110.6.js` (self-hosted since v218); CDN is fallback. |
| PDF | `jspdf@2.5.1` | Loaded from CDN (jsdelivr, cdnjs fallback) for invoices. |
| Hosting | Vercel | Deploys `main` to production `https://velto-ops-pwa.vercel.app`. |
| PWA | `sw.js` + `manifest.webmanifest` | Installable, offline shell, push notifications. |
| Native | Capacitor (`apk/`) | Android wrapper loading the live URL; built by GitHub Actions. |
| Push | Web Push + FCM (native) | Edge functions `notify-push`, `fcm-send`. |

**Supabase project:** `velto-production`, region **Northeast Asia (Tokyo) `ap-northeast-1`**,
plan: **Pro** (upgraded from Free after an egress-cap incident — see §17).
URL: `https://erutxtnepbejdxkoimeo.supabase.co`. The **anon key** lives in `index.html`
(this is normal and safe — anon keys are public; row-level security is the real guard).
The **service_role key** is NOT in the repo; it is pasted by a human into cron SQL when needed.

---

## 3. Repository layout

```
velto-ops-pwa/
├── index.html                     # THE APP. ~1.3MB / ~11.7k lines. Front end + all logic.
├── sw.js                          # Service worker (cache, offline, push, egress saver).
├── manifest.webmanifest           # PWA manifest.
├── vercel.json                    # Headers: CSP, cache-control, security headers.
├── vendor/
│   └── supabase-js-2.110.6.js     # Self-hosted Supabase client (v218+).
├── supabase/                      # Hand-written SQL migrations + edge functions.
│   ├── *.sql                      # ~30 migration files (see §7). Run manually, idempotent.
│   └── functions/
│       ├── notify-push/index.ts   # Web Push sender (task assign + reminders).
│       ├── fcm-send/index.ts      # Native Android push via FCM.
│       └── ai-copilot/index.ts    # AI assist edge function.
├── apk/                           # Capacitor Android wrapper (README, capacitor.config.json, scripts).
├── .github/workflows/build-apk.yml# CI that compiles the Android APK.
├── icon-*.png, favicon.png, etc.  # PWA icons.
└── docs/PROJECT_BRIEF.md          # This file.
```

Also present: three `*.patch` files at the repo root (historical AI-feature patches) — informational only.

---

## 4. How the single-file front end is organized

`index.html` is large but consistently structured. Reading order:

1. **`<head>` + `<style>`** — CSS custom properties in `:root` (global palette), then
   scoped component styles. The manager-home "cockpit" uses its own `--v*` token set
   scoped under `.vh` and the new ops screens.
2. **`<body>`** — the login gate (`#loginGate`), the top bar, then **one `<section
   class="screen" id="s-...">` per screen** inside `<div class="scroll">`, then the
   bottom nav, then modals/sheets.
3. **`<script>` (the big one)** — constants, Supabase client init, auth
   (`initAuth/doLogin/afterAuth/unlockApp`), data loaders (`loadOrders`,
   `loadCustomers`, …), per-screen render functions, and all feature modules.
4. Smaller trailing `<script>` blocks (popstate handler, etc.).

**Navigation:** `openScreen(id, title)` (and `navTo(id)` / `go(btn)` for nav buttons)
hide all `.screen`s and show one, then run that screen's init/render. Each new screen
must (a) add a `<section class="screen" id="s-x">`, (b) add an `if(id==='s-x'){...}`
hook in `openScreen`.

**Finding things fast:** functions are named by feature prefix — `ord*` (orders),
`_vh*` (manager home cockpit), `_iron*`/`renderIronFloorPage` (iron floor), `weekly*`
(weekly pickups), `outsource*`/`partner*` (outsourced ironmen), `task*`, `exp*`
(expenses), `ro*` (reorder loop), `cust*`. Grep by prefix.

---

## 5. Deployment model — how code goes live

**Production = the `main` branch on GitHub, auto-deployed by Vercel.**

- Commit/merge to `main` → Vercel builds and serves it at the production URL in ~30s.
- Any other branch → Vercel makes a **preview** deployment only (not seen by staff).
- Therefore: **to ship, your change must reach `main`.** In Codex with GitHub connected,
  the normal flow works: branch → commit → PR → merge to `main` → live. **No installer
  scripts needed.**

**Historical note (important context):** this project was previously developed in a
sandbox that was **blocked from `git push`** (org egress 403). So releases were shipped
as self-contained `go-live-vNNN.command` bash installers (embedding a base64 gzip
tarball of `index.html`+`sw.js`) that the founder ran locally to push to `main`. That
workflow is a workaround for the push block — **you do not need it** if your environment
can push to GitHub. Just push to `main`.

**Supabase schema changes are NOT automated.** If your change needs new tables/columns/
policies, write an idempotent SQL file in `supabase/`, and tell the human to run it in
Supabase → SQL Editor. The app should degrade gracefully until it's run (see the
`_opsErrIsMissing` pattern for "table doesn't exist yet" handling).

---

## 6. The versioning ritual (do this on EVERY front-end release)

Three markers must move together or clients get stale/broken caches:

1. `index.html` badge: the `>vNNN<` inside `<span id="verBadge">…</span>` (top bar).
2. `index.html` constant: `const APP_VERSION='vNNN';`
3. `sw.js`: `const CACHE = 'velto-ops-vNNN';`

The service worker is **network-first for the HTML shell** (so new code lands on reload)
and deletes old caches on activate — except the **`velto-media-v1`** photo cache, which is
kept on purpose (see §7 storage / §17 egress). After shipping, the user must fully close
and reopen the installed PWA for the new SW to activate; the badge should read the new version.

---

## 7. Supabase backend

### 7.1 Convention
All tables use **permissive RLS for `authenticated`** (a small trusted team): `select`,
`insert`, `update`, `delete` policies each `using (true) / with check (true)`. Access
control is enforced in the **app UI by role**, not by RLS (except a few SECURITY DEFINER
helpers like `is_admin()` for team management). Every migration is **idempotent**
(`create table if not exists`, `add column if not exists`, `drop policy if exists`) and
labelled "Run ONCE in Supabase → SQL Editor. Safe to re-run."

### 7.2 Tables (referenced by the app)
`orders`, `order_items`, `order_photos`, `order_stains`, `order_risks`, `payments`,
`customers`, `customer_stats`, `customer_duplicates`, `profiles`, `outlets`,
`outlet_targets`, `expenses`, `cash_recons`, `tasks`, `task_comments`, `activity_log`,
`floor_issues`, `feedback`, `reorder_actions`, `ai_plans`, `kpi_events`, `price_list`,
`device_tokens`, `push_subscriptions`, `client_errors`,
**and the v215 ops tables:** `weekly_subscriptions`, `iron_board_counts`,
`outsource_partners`, `outsource_assignments`.

### 7.3 Migration files (`supabase/*.sql`) and what each does
- `outlets_setup.sql` — multi-outlet foundation (S11 + RUAP), outlet codes on rows.
- `outlet_targets_setup.sql` — per-outlet monthly goals (revenue, orders, new customers).
- `numbering_fix.sql` / `numbering_permafix.sql` — gap-free per-outlet order numbers
  (`claim_outlet_number` RPC). Order numbers look like `VELR-00007` / `VELS-…`.
- `ai-upgrade.sql` — data-driven AI feature tables.
- `advisory_setup.sql` — wash-risk / care advisory: `order_risks`, `order_stains`,
  advisory status on orders (customer approval before processing risky garments).
- `express_setup.sql` — Express service (+৳100): `express`, `express_fee` on orders.
- `activity_setup.sql` — `activity_log` (every action: order taken, status change,
  payment, delivery) with actor + timestamp.
- `expenses_setup.sql` / `finance_structure.sql` / `finance_private.sql` /
  `expenses_delete_policy.sql` — expenses + P&L: recurring vs spread (amortised) vs
  capital cost types; managers see only their own expenses; admins see all.
- `cash_recon_setup.sql` — weekly drawer count vs app-computed cash, per outlet.
- `tasks_setup.sql` / `tasks_clickup.sql` / `tasks_realtime.sql` /
  `task_reminders_cron.sql` — team tasks: multi-assignee, status stages, subtasks,
  comments; realtime buzz on assign; pg_cron every 5 min fires "due soon" reminders
  via the `notify-push` edge function.
- `profiles_avatar.sql` — profile photos.
- `team_admin.sql` / `velto_team_fix.sql` — admin can change roles/outlets/disable
  members; `is_admin()` SECURITY DEFINER avoids RLS recursion; heals `active=NULL` rows.
- `ironman_facility.sql` / `ironman_split.sql` / `ironman_deliver.sql` /
  `ironman_ops.sql` — the Iron Facility model: mixed orders split into an independent
  "iron parcel" (`iron_stage`, `iron_items[]`, `iron_count`, `iron_sent_at`,
  `iron_ready_at`, `iron_delivered_at`, `iron_priority`, `iron_finish_by`), and manager
  notifications when Oli marks ready.
- `floor_issues_setup.sql` — workers report a floor problem with photo; manager decides.
- `order_sla_automation.sql` — accountability loop: pg_cron 2×/day (10am + 6pm Dhaka)
  drives delivery-chase escalations.
- `payment_reverse.sql` — reverse a mistaken payment (`reverse_payment` RPC).
- `cockpit.sql` — CEO/admin cockpit server-side aggregate over both outlets
  (`cockpit_stats` RPC).
- `device_tokens_setup.sql` — native FCM device tokens per installed app.
- **`velto_v215_ops.sql`** — the ops expansion: creates `weekly_subscriptions`,
  `iron_board_counts` (5 tally buckets), `outsource_partners`, `outsource_assignments`;
  adds `source/source_ref/dedupe_key` to `tasks`; a `create_weekly_pickup_tasks()`
  plpgsql function; and a **pg_cron job at 10:00 AM Dhaka (04:00 UTC)** that
  auto-creates today's pickup/delivery tasks + tomorrow's high-priority follow-ups.

### 7.4 RPCs (Postgres functions called from the app)
`create_order_with_items`, `set_order_status`, `fix_order`, `claim_outlet_number`,
`merge_customers`, `reverse_payment`, `upsert_target`, `dashboard_counts`,
`dashboard_stats`, `cockpit_stats`, `save_push_subscription`, `delete_push_subscription`.

### 7.5 Edge functions (`supabase/functions/`)
- `notify-push` — Web Push (VAPID) sender; task-assign pushes + reminder sweep.
- `fcm-send` — native Android push via Firebase Cloud Messaging.
- `ai-copilot` — AI assistant endpoint.

### 7.6 Storage
Order/customer/expense **photos** live in Supabase Storage. Objects are immutable
(uploaded to new paths), so `sw.js` caches them cache-first in `velto-media-v1` (per
device, survives version bumps) to cut egress.

---

## 8. Data model deep-dive (the tables you'll touch most)

### 8.1 `orders` (+ `order_items`)
Key columns used by the app (`buildOrderObj` maps these into a JS object):
`id, order_number, customer_id, name_snapshot, phone_snapshot, zone_snapshot,
address_snapshot, order_status, total_amount, amount_paid, payment_method,
rider_assigned, total_items, order_date, created_at, delivery_date, pickup_date,
service_category (text[]), express, express_fee, advisory_status,
iron_stage, iron_items (jsonb[]), iron_count, iron_ready_at, iron_delivered_at,
outlet_code`.

`order_items`: `order_id, service_category, item_name, quantity, quoted_price,
reference_price, unit, hanger, note, item_group`. In the app each line is
`{svc, name, qty, price}` on `order.lines`.

**Service categories (`CATS`):** exactly `["Ironing", "Wash + Iron", "Dry Cleaning"]`.
- `Ironing` = only-iron (skips wash plant).
- `Wash + Iron` = washed then ironed.
- `Dry Cleaning` = plant then (in-house) ironed.

### 8.2 Order status pipeline (canonical, in order)
```
New → Picked → In Wash Plant → In Velto Facility → Ready to Pick from Facility
    → In Velto Outlet → QC Passed → Ready → Out for Delivery → Delivered   (+ Cancelled)
```
The manager-home flow view and the order-detail 6-stage journey map onto this:
`Pickup(New,Picked) · Wash plant(In Wash Plant) · Ironing(In Velto Facility, Ready to
Pick from Facility) · QC(In Velto Outlet, QC Passed) · Ready · Delivered(Out for
Delivery, Delivered)`.

### 8.3 `profiles` (auth + role)
`id (=auth uid), name, role (admin|manager|rider|worker|ironman), active (bool),
outlet (S11|RUAP|all), avatar_url`. Login reads this in `afterAuth`; a cached copy in
localStorage (`velto_profile_<uid>`) lets the app open offline.

### 8.4 `tasks`
`title, note, type (pickup|delivery|call|process|other), assignee_ids[], assignee_names[],
assigned_to, assigned_to_name, assigned_by_name, due_at, outlet_code, priority
(low|normal|high), status (open|done), subtasks[], source, source_ref, dedupe_key`.
The `dedupe_key` (unique) makes weekly auto-tasks idempotent (`wk:<subId>:<date>:<kind>`).

### 8.5 v215 ops tables
- **`weekly_subscriptions`** — recurring pickup customers: `name, phone, address,
  sector, outlet_code, days (int[] 0=Sun..6=Sat), time_window, service_category,
  price_per_run, assigned_staff_id/name (rider), status (active|paused), is_vip,
  settled, resumes_on`.
- **`iron_board_counts`** — a physical tally of the ironman's board (used when the
  manager doesn't trust the computed number): `count_date, outlet_code, iron_only_pcs,
  wash_iron_pcs, dc_pcs, blazer_pcs, sharee_pcs, counted_by_id/name, role_counted`.
  Newest row per (outlet, day) wins and **overrides** the computed board.
- **`outsource_partners`** — external/overflow ironmen: `name, ptype (in-house pool|
  freelance|vendor), location, phone, rate_per_pc, daily_capacity, on_time_pct, tenure,
  frees_at, active`.
- **`outsource_assignments`** — pcs placed with a partner: `partner_id, assign_date,
  pcs_wash, pcs_iron, pcs, rate_per_pc, amount, paid, status (placed|received|paid),
  outlet_code`. Card metrics (free capacity, in-hand, month pcs, earned, due) are
  computed client-side in `_partnerMetrics`.

---

## 9. Complete screen / feature inventory (28 screens)

Manager/admin home is the "adaptive cockpit" (`renderVeltoHome`); other roles get their
own home. Screens (`s-*`):

- **`s-home`** — Command Center. Classic top (greeting, search, New Order hero, quick
  tiles: Update/Customers/Tasks/Expense + **Iron Floor/Weekly/Outsourced** for managers)
  **plus** the adaptive cockpit below (`_vh*`): proactive alerts, "What needs you now"
  triage, **Iron Floor panel**, **Today's Score** (6 cards, all states), Live Flow,
  Signals, Opportunities, Brief, Manager Tools. Three states by Dhaka time/health:
  morning · problem (busy) · closing (after 7pm). **All three now show the full
  six-card score** (Revenue, AOV, Orders today, Due deliveries, On-time, Recovered).
- **`s-new`** — Order intake (~40s): customer, items by category, quotes, express,
  stains/risks, advisory. Uses `create_order_with_items`.
- **`s-orders`** — Orders command view: header stats, "Needs Action" triage
  (commitment→blocked→money→improve, catches late/due-today/EXPRESS), "All Live"
  segment, filter chips, **newest-first** default, search spans full history incl.
  delivered-with-dues.
- **`s-detail`** — Order detail: intelligence, next action, **6-stage journey with live
  "since HH:MM · elapsed"**, promise health, iron parcel status, invoice, ready message.
- **`s-update`** — quick status update by order id.
- **`s-customers`** / **`s-custdetail`** / **`s-dupes`** — customer base (admin), detail,
  duplicate merge (`merge_customers`).
- **`s-deliveries`** — delivery board.
- **`s-collect`** — collections (outstanding dues).
- **`s-reorder`** — Reorder Loop: who's due to order again, thank-you/follow-up/win-back
  buckets, contacted tracking.
- **`s-tasks`** — team tasks (ClickUp-style: assignees, priority, subtasks, comments).
- **`s-finance`** / **`s-money`** — expenses + P&L (cost types, private per manager),
  cash reconciliation. `s-money` admin-only.
- **`s-kpi`** / **`s-cohort`** / **`s-cockpit`** — analytics, cohorts, CEO cockpit.
- **`s-team`** — team & access admin (roles/outlets/disable).
- **`s-settings`** — profile, avatar, push diagnostics, version.
- **`s-notifications`** — notification feed.
- **`s-issues`** — floor issues (worker-reported problems).
- **Role homes:** `s-worker` (কাজ/QC), `s-rider` (ডেলিভারি/tasks), `s-ironman`
  (ইস্ত্রি — the facility queue).
- **v215 ops screens:** **`s-ironfloor`** (full Iron Floor page), **`s-ironcount`**
  (Count the board), **`s-weekly`** (Weekly Pickups), **`s-outsource`** (Outsourced Ironmen).

### Cross-cutting flows worth knowing
- **Ready message:** when an order → `Ready`, an auto-prompted WhatsApp template is
  composed with the customer's honorific + second name ("Mr <SecondName>", never bare
  "Mr") and a **payment-aware amount line** (Paid / Due / partial breakdown).
  Functions: `readyMsgName`, `sendReadyMsg`.
- **Invoice PDF:** jsPDF; the PDF blob is **pre-built when the modal opens**
  (`_prewarmInvoicePdf`) so `navigator.share({files})` fires inside the user gesture
  (fixes iOS/PWA "text only" sharing). Native APK path uses a `VeltoSaver` bridge.

---

## 10. The Iron Floor / ops expansion (v215–v220) in detail

This is the newest, most complex subsystem — the ironing operation's brain. Live-data,
manager/owner only. Engine: `_ironFloorData()`.

### 10.1 The honest range rate model
The same piece count is very different hours depending on the mix, so hours are a
**range**, not a point. Minutes per piece `[fast, slow]` (`_IRON_RATE`):
- **only-iron** `[4, 6]` → 10–15/hr
- **wash-iron** `[6, 6]` → ~10/hr
- **dry-clean** `[6, 6]` → ~10/hr
- **blazer** `[20, 30]` → 2–3/hr
- **sharee/saree** `[20, 30]` → 2–3/hr

Capacity: **1 ironman × 8h = 480 min/day** (`_IRON_CAP_MIN`). `_ironHours(buckets)`
returns `{lo, hi, mid}`; `_ironOverflow` returns pcs beyond one 8h shift as a range.
Garment classifier `_ironGarment(name)` detects blazer/saree by name; `_ironBucket`
maps `(svc, name)` to one of the five speed buckets.

### 10.2 What it computes
From `ordersData` (+ order status), it classifies iron-bound pieces into pipeline
positions (on the board / in wash plant / returning tonight / upstream / ironed today)
and produces: today's intake mix (by service), board load hours-range + %, overflow
(outsource count), pipeline forecast (in plant → back tonight → tomorrow's load), pieces
ironed today (throughput, from `iron_ready_at`), and **proactive alerts**:
- 🔴 **today over capacity** (board hours mid > 8h),
- ⚠️ **tomorrow iron-heavy** (forecast > 8h → confirm count → outsource decision),
- 🧑‍🏭 **ironman under target** (afternoon, real backlog, output below pace — capped so
  quiet days never false-accuse).

### 10.3 Count the board (`s-ironcount`)
On-demand physical tally with steppers for the 5 buckets; hours/days/overflow recompute
live; "Counted by" picks the ironman/rider/manager. Saving to `iron_board_counts`
**overrides** the computed board for that day (the whole point: use it when the system
number isn't trusted).

### 10.4 Weekly Pickups (`s-weekly`)
Subscriptions with day chips, price/run, assigned rider, SETTLED/VIP/PAUSED badges;
"today's recurring runs" card; add/edit customer. **Auto-tasks**: a pg_cron job at
**10:00 AM Dhaka** runs `create_weekly_pickup_tasks()` — today → pickup (AM) + delivery
(PM) tasks for the assigned rider; tomorrow → a **HIGH-priority confirm/follow-up**.
A client-side idempotent `materializeWeeklyTasks()` also seeds them (upsert on
`dedupe_key`, `ignoreDuplicates`) so it works even before the cron fires; no duplicates.

### 10.5 Outsourced Ironmen (`s-outsource`)
Partners sorted by free capacity with AVAILABLE/NEARLY FULL/FULL badges, ৳/pc, on-time%,
free-of-capacity, month pcs, earned/due, **edit button**, and a **tap-to-call phone
chip**. "N pcs to place" pulls from the Iron Floor overflow. Assign flow inserts an
`outsource_assignment`. Full partners → Waitlist.

---

## 11. Roles & permissions (UI-enforced)

| Capability | admin | manager | rider | worker | ironman |
|---|---|---|---|---|---|
| Adaptive cockpit home | ✓ | ✓ | — | — | — |
| Iron Floor / Weekly / Outsourced tiles | ✓ | ✓ | — | — | — |
| Full customer list (`s-customers`) | ✓ | search only | search | search | search |
| Finance (`s-finance`) | ✓ | ✓ (own expenses) | — | — | — |
| P&L / Money (`s-money`), Cockpit | ✓ | — | — | — | — |
| Team & access (`s-team`) | ✓ | — | — | — | — |
| Own role home | — | — | `s-rider` | `s-worker` | `s-ironman` |

Role comes from `profiles.role`; the login flow calls `applyRole()` + `applyOutletUI()`
to shape the nav and tiles. RLS is permissive; **UI is the gate** — keep it that way
unless deliberately hardening.

---

## 12. Coding conventions / house style

- **Vanilla only.** No new frameworks, bundlers, npm runtime deps in the front end.
- **Match the surrounding code:** template-literal HTML built in JS, `he()` for HTML-
  escaping user data, `toast()` for feedback, `openSheet/closeSheet` or the ops
  `_opsModal` for modals, `dhakaDateStr()` for dates, `_vhTk()` for ৳ formatting.
- **Feature-prefixed function names** (see §4). Add new screens via a `<section
  class="screen">` + an `openScreen` hook + a `render*` function + a `load*` loader.
- **Graceful DB degradation:** wrap Supabase calls in try/catch; detect "table not
  created yet" with the `_opsErrIsMissing` pattern and show a "run setup SQL" hint
  instead of crashing.
- **Never let a render throw strand the user** — the auth path especially is guarded.
- **Every ship:** bump the 3 version markers (§6). Keep changes small and verified.
- **Timezone:** always Dhaka. **Money:** integer Taka, `toLocaleString`.
- Test approach used historically: headless Chromium (Playwright) loads `index.html`
  with globals mocked, asserts no page errors + function presence + render output +
  math invariants. There is no unit-test framework in-repo; tests were external harnesses.

---

## 13. Version history (high level)

- **v143–v196** — core build: multi-outlet, numbering, advisory, express, tasks
  (ClickUp), finance/P&L, cash recon, ironman facility + split + deliver, floor issues,
  SLA automation, team admin, cockpit, reorder loop, analytics, native push/APK.
- **v197–v206** — Adaptive Manager Home (3 states) + lag/status/photo fixes; pixel
  passes; classic-top-with-cockpit-below; unified top bar; Orders command view; Needs
  Action triage; Order Detail redesign.
- **v207–v213** — Ready message (honorific + payment-aware); newest-first + full-history
  search; 6-stage live journey; invoice PDF reliably attaches; closing score gains
  Orders-today + Due-deliveries (2nd row).
- **v214** — Iron Floor cockpit panel (first version of the ironing brain).
- **v215** — Ops expansion: Iron Floor page, Count the board, Weekly Pickups, Outsourced
  Ironmen; range rate model; `velto_v215_ops.sql`; home tiles; 10 AM task cron.
- **v216** — Outsourced: edit action + tap-to-call phone.
- **v217** — Daytime Today's Score restores Orders-today + Due-deliveries cards.
- **v218** — **Bulletproof sign-in:** vendored supabase-js (self-hosted, SW-precached),
  20s sign-in watchdog, 10s profile watchdog, login health probe/banner, post-auth guard.
- **v219** — Today's Score shows all six cards in **every** home state (the "problem"
  state used to collapse to two).
- **v220** — **Sign-in hang root-cause fix** + **egress saver** (see §17).

---

## 14. Known issues, constraints & gotchas (READ before editing)

1. **Single 1.3 MB file, no build step.** Edits are direct and global. A syntax error
   anywhere breaks the whole app (including login). Always verify the file parses.
2. **Version ritual is load-bearing.** Forgetting to bump `sw.js` CACHE means clients
   keep the old cached bundle.
3. **Supabase free-tier egress is the historical failure mode** — see §17. Now on Pro,
   but photo egress discipline (the `velto-media-v1` cache; reasonable image sizes)
   still matters as the business grows.
4. **RLS is permissive; the UI is the access gate.** Do not assume the database will
   stop a wrong-role action.
5. **Secrets:** the anon key is in `index.html` (fine/public). Never commit the
   service_role key. Never log it.
6. **Realtime + status sync** historically flaky under load; there are backstops
   (visibility + periodic reconcile) — preserve them.
7. **Dhaka time everywhere.** Using device/UTC time for "today" produces off-by-one bugs.
8. **iOS PWA quirks:** `navigator.share({files})` needs a fresh user gesture (hence PDF
   pre-warming); custom vibration/notification options are ignored on iOS.
9. **supabase-js auth uses a Web Lock** that can hang in an installed PWA — this app
   disables it (see §17); keep that config.
10. **No automated schema migration.** New SQL must be run by a human; ship UI that
    tolerates its absence.

---

## 15. Recent production incident (post-mortem) — the sign-in outage

**Symptom:** the whole team was signed out and sign-in hung silently (button did
nothing / spun forever), while the Supabase dashboard showed the database "Healthy."

**Two real root causes, both now fixed:**
1. **Free-plan egress overage.** Usage hit **5.12 GB / 5 GB** (over cap). On Free,
   overage → the project gets **restricted** (DB still shows Healthy, but the gateway
   stalls/refuses traffic), which fails token refresh → mass sign-out + sign-in hang.
   The burn was mostly **photos re-downloading on every app open**.
   **Fixes:** (a) founder **upgraded to Pro** (restriction lifts, 250 GB egress, daily
   backups); (b) v220 `sw.js` caches Storage photos once per device in `velto-media-v1`.
2. **supabase-js auth Web Lock hang.** The SDK serialises auth calls behind
   `navigator.locks`; a killed/backgrounded installed-PWA instance can leave the lock
   held, so every later `signInWithPassword`/`getSession` waits forever.
   **Fix (v220):** pass a no-op `lock` to `createClient` (`_veltoNoLock`) — safe because
   Velto is one user per device. Verified headless: with the exact lock held, auth calls
   resolve in ~1 ms.

**Also hardened (v218):** vendored auth library + timeouts + a login-screen health probe
so an unreachable server now shows a clear banner instead of hanging.

**Operational watch item:** keep an eye on Supabase egress; enable/verify daily backups
on Pro (dashboard showed "No backups" on Free).

---

## 16. Suggested roadmap / open items (not yet done)

- Confirm daily backups are running on Pro.
- Optional: image compression at upload to further cut storage/egress.
- Optional: move some permissive RLS to real per-role policies if the team grows.
- Optional: extract repeated inline styles into shared classes (the file is large).
- The Weekly/Outsourced/Count features depend on `velto_v215_ops.sql` being applied in
  Supabase — verify it ran (pages show a "run setup" hint if not).

---

## 17. How to give Codex the entire project

The repo is **private**: `github.com/nazmulhuda743/velto-ops-pwa` (default branch `main`).
Pick whichever fits your Codex setup:

### Option A — Connect GitHub to Codex (best; gives it the live repo + push)
1. In the Codex/ChatGPT interface, open **Settings → Connectors/GitHub** (or the
   "Connect GitHub" prompt when creating a project) and authorize the GitHub app.
2. Grant access to the **`nazmulhuda743/velto-ops-pwa`** repository specifically.
3. Create the Codex project/environment pointing at that repo, branch `main`.
4. Codex can now read all files, branch, commit, and open PRs. **Merging a PR to `main`
   auto-deploys to production via Vercel** — so review before merge.
5. Point Codex at **`docs/PROJECT_BRIEF.md`** (this file) as its first read.

### Option B — Download a ZIP and upload
1. On GitHub: repo → green **Code** button → **Download ZIP** (gets the whole repo at
   `main`).
2. Unzip and upload the folder (or the key files) into the Codex project.
3. Note: this is a snapshot — Codex can't push back; you'd copy changes manually.

### Option C — Clone locally, then hand off
```
git clone https://github.com/nazmulhuda743/velto-ops-pwa.git
cd velto-ops-pwa
```
Then open that folder in your Codex-enabled editor/CLI.

### Give Codex this context prompt (paste it in)
> "This is Velto Ops, a production single-file PWA (`index.html`, vanilla JS, no build
> step) for a two-outlet laundry business, backed by Supabase and deployed to Vercel
> from `main`. Read `docs/PROJECT_BRIEF.md` in full before doing anything. It is live
> software — make small, verified, reversible changes; never break sign-in, order
> intake, invoice, or payments. On every front-end release bump the three version
> markers (APP_VERSION, the `>vNNN<` badge, and the `sw.js` CACHE name). Schema changes
> are hand-written idempotent SQL in `supabase/` that a human runs in the Supabase SQL
> Editor — never assume they're auto-applied. Ask me before touching auth, RLS, or the
> service worker."

### Guardrails to tell Codex
- Don't add frameworks/build steps to the front end.
- Don't change the Supabase client `lock` config (it fixes a real hang).
- Don't commit the service_role key.
- Test by loading `index.html` headless (or in a browser) and checking for zero console
  errors before shipping.
- Production URL: `https://velto-ops-pwa.vercel.app`. Supabase project ref:
  `erutxtnepbejdxkoimeo` (region ap-northeast-1, Pro plan).

---

*End of brief. If something here ever drifts from the code, the code (`index.html`,
`sw.js`, `supabase/*.sql`) is the source of truth — update this file when you make
structural changes.*
