-- ============================================================================
-- Velto — Finance cost structure (recurring / spread / capital) + editable
-- expenses. Makes the P&L honest: a big one-time buy is amortised over months
-- instead of cratering a single month, and setup capital never touches P&L.
-- Run in Supabase → SQL Editor. Additive & idempotent — safe to re-run.
-- ============================================================================

-- cost_type: how the money hits the monthly P&L
--   'recurring' — every month (rent, salary, wash bills, marketing) → full amount in its month
--   'spread'    — one-time purchase amortised over spread_months (equipment, inventory stock-up)
--   'capital'   — setup / one-off (deposit, fit-out, license) → NEVER in P&L, tracked as invested
alter table public.expenses add column if not exists cost_type    text not null default 'recurring';
alter table public.expenses add column if not exists spread_months int;               -- for 'spread' (1..N)
alter table public.expenses add column if not exists spread_start  date;               -- amortisation start (defaults to spent_on)

-- Existing rows are current running costs → recurring (owner can re-tag any in the app).
update public.expenses set cost_type = 'recurring' where cost_type is null;
-- Give spread rows a sane window/start if they were somehow set without one.
update public.expenses set spread_months = 1 where cost_type = 'spread' and (spread_months is null or spread_months < 1);
update public.expenses set spread_start  = spent_on where cost_type = 'spread' and spread_start is null;

create index if not exists expenses_costtype_idx on public.expenses (cost_type, spent_on desc);

-- Editable finance: managers/admins may correct a mis-tagged or wrong expense
-- (the whole point — reverse a mistake from the app). Everyone can still add.
alter table public.expenses enable row level security;
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select to authenticated using (true);
drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert to authenticated with check (true);
drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses for update to authenticated using (public.is_manager()) with check (public.is_manager());
drop policy if exists expenses_delete on public.expenses;
create policy expenses_delete on public.expenses for delete to authenticated using (public.is_manager());

-- is_manager() may not exist yet if the tasks upgrade wasn't run — create it.
create or replace function public.is_manager() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('admin','manager') and active is true);
$$;
grant execute on function public.is_manager() to authenticated;

select 'finance structure ready' as status;
