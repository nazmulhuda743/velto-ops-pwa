-- ============================================================================
-- Velto — Log Expense (v130) · Redesign Phase 5
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- Every staff member can log an expense (amount, category, outlet, note,
-- optional bill photo). Feeds Analytics — collections in vs expenses out.
-- ============================================================================

-- If an OLDER, differently-shaped expenses table already exists (from an early
-- experiment), move it aside as a timestamped backup — never deleted — so the
-- correct table can be built. Detected by the missing 'spent_on' column.
do $$
begin
  if to_regclass('public.expenses') is not null
     and not exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name='expenses'
                        and column_name='spent_on') then
    execute 'alter table public.expenses rename to expenses_backup_'||to_char(now(),'YYYYMMDDHH24MISS');
    raise notice 'Existing expenses table had a different shape — renamed to a backup, building the correct one.';
  end if;
end $$;

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
-- Belt-and-braces: if expenses existed with 'spent_on' but missed newer columns.
alter table public.expenses add column if not exists category        text not null default 'misc';
alter table public.expenses add column if not exists outlet_code     text not null default 'S11';
alter table public.expenses add column if not exists note            text;
alter table public.expenses add column if not exists photo_path      text;
alter table public.expenses add column if not exists created_by      uuid;
alter table public.expenses add column if not exists created_by_name text;

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
