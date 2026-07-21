-- ============================================================================
-- Velto — Wash-risk & Care Advisory (v103)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
--   • order_risks           — one row per flagged garment (bleed/shrink/damage…)
--   • orders.advisory_status — 'pending' | 'approved' | 'declined' | null
-- The app self-heals if these are missing (orders still load, feature hidden).
-- ============================================================================

-- ---------- 1. Wash-risk records --------------------------------------------
create table if not exists public.order_risks (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null,
  item_name       text not null,
  risk_type       text,
  note            text,
  photo_paths     text[] default '{}',
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create index if not exists order_risks_order_idx   on public.order_risks (order_id);
create index if not exists order_risks_created_idx on public.order_risks (created_at desc);

alter table public.order_risks enable row level security;

-- Signed-in staff can read and add risk records (mirrors order_stains).
drop policy if exists order_risks_select on public.order_risks;
create policy order_risks_select on public.order_risks
  for select to authenticated using (true);

drop policy if exists order_risks_insert on public.order_risks;
create policy order_risks_insert on public.order_risks
  for insert to authenticated with check (true);

-- ---------- 2. Approval status on the order ---------------------------------
alter table public.orders
  add column if not exists advisory_status text;

-- Done.
