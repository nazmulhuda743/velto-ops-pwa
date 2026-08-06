-- ============================================================================
-- Velto — Weekly Cash Reconciliation (v142)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- Records the weekly drawer count per outlet against what the app says was
-- collected in cash — the leak detector. Records are permanent (no edits).
-- ============================================================================

create table if not exists public.cash_recons (
  id              uuid primary key default gen_random_uuid(),
  outlet_code     text not null,             -- 'S11' | 'RUAP'
  week_start      date not null,
  week_end        date not null,
  expected        numeric not null,          -- cash recorded − cash expenses
  counted         numeric not null,          -- what was actually in the drawer
  diff            numeric not null,          -- counted − expected (+over / −short)
  note            text,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create index if not exists cash_recons_week_idx on public.cash_recons (week_end desc);

alter table public.cash_recons enable row level security;
drop policy if exists cash_recons_select on public.cash_recons;
create policy cash_recons_select on public.cash_recons
  for select to authenticated using (true);
drop policy if exists cash_recons_insert on public.cash_recons;
create policy cash_recons_insert on public.cash_recons
  for insert to authenticated with check (true);
-- (no update/delete — a reconciliation is a record; corrections are new entries)

-- VERIFY
select 'cash_recons ready' as status;
