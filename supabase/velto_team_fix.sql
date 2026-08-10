-- ============================================================================
-- Velto — Team & access FIX (v168)
-- Guarantees the owner/admin can change roles, outlets, and disable members,
-- heals rows with active=NULL (which silently broke the admin check), and
-- blocks self-promotion (nobody can raise their OWN role).
-- Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================

alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists outlet text default 'S11';

-- ROOT CAUSE of "Could not save": an old role CHECK constraint that predates
-- the rider/worker roles rejects them. Replace it with the full role list.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin','manager','rider','worker','staff'));

-- Heal: rows with active=NULL fail the "active is true" admin check silently.
update public.profiles set active = true where active is null;

-- Who am I? (SECURITY DEFINER so policies can read profiles without recursion)
create or replace function public.is_admin() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin' and active is true);
$$;
grant execute on function public.is_admin() to authenticated;

create or replace function public.my_role() returns text
  language sql security definer stable set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;
grant execute on function public.my_role() to authenticated;

alter table public.profiles enable row level security;

-- Everyone signed-in can read the team list (needed for assignees, team screen).
drop policy if exists profiles_select_all on public.profiles;
create policy profiles_select_all on public.profiles
  for select to authenticated using (true);

-- Admin: full control over every profile row.
drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Own profile: name/photo/phone edits allowed, but the role may NOT change
-- (no self-promotion; admins bypass this via the policy above).
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and role = public.my_role());

-- VERIFY — should list the three policies and count your admins (≥1).
select policyname from pg_policies where tablename = 'profiles' order by 1;
select 'team fix ready — active admins: '||count(*)::text as status
  from public.profiles where role = 'admin' and active is true;
