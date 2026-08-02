-- ============================================================================
-- Velto — Log Expense (v130) · Redesign Phase 5
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- Every staff member can log an expense (amount, category, outlet, note,
-- optional bill photo). Feeds Analytics — collections in vs expenses out.
-- ============================================================================

create table if not exists public.expenses (
  id              uuid primary key default gen_random_uuid(),
  amount          numeric not null check (amount > 0),
  category        text not null,             -- washing | marketing | inventory | rent | utilities | salaries | misc
  outlet_code     text not null default 'S11',   -- 'S11' | 'RUAP' | 'ALL' (shared cost)
  spent_on        date not null default (now() at time zone 'Asia/Dhaka')::date,
  note            text,
  photo_path      text,                      -- storage path of the bill photo, if attached
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create index if not exists expenses_date_idx   on public.expenses (spent_on desc);
create index if not exists expenses_outlet_idx on public.expenses (outlet_code);

alter table public.expenses enable row level security;
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses
  for select to authenticated using (true);
drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses
  for insert to authenticated with check (true);
-- (no update/delete policies — an expense log is a record; corrections are new entries)

-- VERIFY
select count(*) as expenses_rows from public.expenses;
