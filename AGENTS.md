# AGENTS.md — instructions for AI coding agents working on Velto Ops

**Read `docs/PROJECT_BRIEF.md` in full before doing anything.** It is the complete
source of truth (architecture, data model, every feature, gotchas, history).

## What this project is
Velto Ops is a **live production PWA** running a real two-outlet laundry business.
The entire front end is a **single file, `index.html`** (~1.3 MB, vanilla JS, **no build
step**). Backend is **Supabase**; hosting is **Vercel**, which **auto-deploys production
from the `main` branch**. Merging to `main` ships to real users in ~30 seconds.

## Hard rules
1. **Never break** sign-in, order intake, invoice, ready-message, payments, or the
   service worker. This is a running business.
2. **Small, verified, reversible changes.** Load `index.html` (headless or in a browser)
   and confirm **zero console errors** before shipping.
3. **On every front-end release, bump all three version markers together:**
   - `const APP_VERSION='vNNN'` in `index.html`
   - the `>vNNN<` text inside `<span id="verBadge">` in `index.html`
   - `const CACHE = 'velto-ops-vNNN'` in `sw.js`
4. **No new frameworks, bundlers, or npm runtime deps** in the front end. Match the
   existing vanilla style (template-literal HTML, `he()` escaping, `toast()`,
   `dhakaDateStr()`, feature-prefixed function names).
5. **Ask a human before touching** authentication, RLS, the Supabase client config
   (do NOT change the `lock` option — it fixes a real sign-in hang), or `sw.js`.
6. **Database schema changes are hand-written idempotent SQL in `supabase/`** that a
   **human runs manually** in the Supabase SQL Editor. Never assume they auto-apply;
   ship UI that degrades gracefully when a table doesn't exist yet.
7. **Timezone is always Asia/Dhaka (UTC+6).** Money is integer Taka (৳).
8. **Secrets:** the Supabase anon key in `index.html` is public and fine. **Never**
   commit or log the service_role key.

## Where things are
- `index.html` — the app (front end + all logic). Navigate by function prefix:
  `ord*` orders, `_vh*` manager home, `_iron*`/`renderIronFloorPage` iron floor,
  `weekly*` weekly pickups, `outsource*`/`partner*` outsourced ironmen, `task*`, `exp*`.
- `sw.js` — service worker (cache, offline, push, photo egress saver).
- `supabase/*.sql` — schema migrations (idempotent). `supabase/functions/` — edge functions.
- `docs/PROJECT_BRIEF.md` — the full brief. Read it first.

## Deploying
Branch → commit → PR → **review** → merge to `main` → Vercel deploys automatically.
Production URL: `https://velto-ops-pwa.vercel.app`. Because merge = instant production,
review every PR before merging.
