-- ============================================================================
-- Velto — Per-outlet Monthly Targets (v141)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- Each outlet gets its OWN monthly goals (revenue, orders, new customers,
-- repeat rate, collection rate), editable independently from the app.
-- The All-outlets view keeps the existing company-wide targets.
-- ============================================================================

create table if not exists public.outlet_targets (
  outlet_code          text    not null,          -- 'S11' | 'RUAP'
  month                date    not null,          -- first day of the month
  revenue_goal         numeric not null default 0,
  orders_goal          int     not null default 0,
  new_customers_goal   int     not null default 0,
  repeat_rate_goal     numeric not null default 0,
  collection_rate_goal numeric not null default 0,
  updated_at           timestamptz not null default now(),
  primary key (outlet_code, month)
);

alter table public.outlet_targets enable row level security;
drop policy if exists outlet_targets_select on public.outlet_targets;
create policy outlet_targets_select on public.outlet_targets
  for select to authenticated using (true);
drop policy if exists outlet_targets_insert on public.outlet_targets;
create policy outlet_targets_insert on public.outlet_targets
  for insert to authenticated with check (true);
drop policy if exists outlet_targets_update on public.outlet_targets;
create policy outlet_targets_update on public.outlet_targets
  for update to authenticated using (true) with check (true);

-- VERIFY
select 'outlet_targets ready' as status;
