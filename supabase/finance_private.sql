-- ============================================================================
-- Velto — PRIVATE finance per manager.
-- Only admins & managers may log/edit expenses. Each MANAGER sees, edits and
-- deletes ONLY the expenses they created themselves — never the owner's or
-- another manager's. The ADMIN (owner) still sees & controls everything, for a
-- correct business-wide P&L. Enforced in the database (RLS), not just the UI.
-- Run in Supabase → SQL Editor. Additive & idempotent — safe to re-run.
-- ============================================================================

-- Role helpers (create if the earlier upgrades weren't run).
create or replace function public.is_admin() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin' and active is true);
$$;
grant execute on function public.is_admin() to authenticated;

create or replace function public.is_manager() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('admin','manager') and active is true);
$$;
grant execute on function public.is_manager() to authenticated;

-- Stamp the creator automatically, so a row is always owned even if a future
-- code path forgets to send it. (The app already sends created_by = the user.)
alter table public.expenses add column if not exists created_by uuid;
alter table public.expenses alter column created_by set default auth.uid();
create index if not exists expenses_created_by_idx on public.expenses (created_by);

alter table public.expenses enable row level security;

-- SELECT — admin sees all; everyone else sees only their own rows.
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select to authenticated
  using ( public.is_admin() or created_by = auth.uid() );

-- INSERT — only admins & managers may log an expense, and only as themselves.
drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert to authenticated
  with check ( public.is_manager() and created_by = auth.uid() );

-- UPDATE — admin may edit any; a manager may edit only their own.
drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses for update to authenticated
  using      ( public.is_admin() or created_by = auth.uid() )
  with check ( public.is_admin() or created_by = auth.uid() );

-- DELETE — admin may delete any; a manager may delete only their own.
drop policy if exists expenses_delete on public.expenses;
create policy expenses_delete on public.expenses for delete to authenticated
  using ( public.is_admin() or created_by = auth.uid() );

select 'finance is now private per manager' as status;
