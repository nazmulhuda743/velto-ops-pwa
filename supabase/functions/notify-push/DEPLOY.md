# Deploy `notify-push` (Task notifications — v152)

This function sends the two task pushes: **"new task for you"** (when someone
assigns) and **"task due soon"** (30-ish min before, via the cron). It reuses
the same `push_subscriptions` table and VAPID keys as your order notifications.

## 1. Deploy the function

**Option A — Supabase CLI (recommended):**
```bash
supabase functions deploy notify-push --project-ref erutxtnepbejdxkoimeo
```

**Option B — Dashboard:** Edge Functions → Create function → name it exactly
`notify-push` → paste the contents of `index.ts` → Deploy.

## 2. Set the function secrets

These must match the ones your **order** push already uses. In the Dashboard:
Edge Functions → notify-push → Secrets (or `supabase secrets set`):

- `VAPID_PUBLIC_KEY`  — same public key that's in the app
  (`BKfil2EzKdsq4sgYTbn3gnyFQeUcCIeAyDELKaXzaMdTyWPr0XyAY3uYRNa2Caw2qqu0p7m3LVx7berRVGtKqow`)
- `VAPID_PRIVATE_KEY` — the private key you already set for the order push function
- `VAPID_SUBJECT`     — e.g. `mailto:ops@velto.app`

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided automatically.

## 3. Turn on the reminder timer

Run `supabase/task_reminders_cron.sql` in the SQL Editor (replace
`<SERVICE_ROLE_KEY>` with your service_role key). That schedules a check every
5 minutes.

## 4. Test

- Assign a task in the app → the assignee's phone should get "🗒️ New task for you".
- Create a task due ~10 minutes out → within a few minutes the cron should push
  "⏰ Task due soon".

If nothing arrives, check: the device has push enabled (Settings → notifications
test button already in the app), the three VAPID secrets are set, and the cron
job shows `active = true` (the verify query at the bottom of the cron SQL).

## Notes

- **Targeting:** the function sends to the assignee's own devices when
  `push_subscriptions` has a `user_id` column; otherwise it broadcasts to the
  whole team (fine for a small team — everyone sees the task). To target
  precisely later, add a `user_id uuid` column to `push_subscriptions` and have
  `save_push_subscription` store `auth.uid()`.
- The function is idempotent per task for reminders (it sets `reminded = true`
  after sending, so no repeats).
