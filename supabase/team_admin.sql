-- ============================================================================
-- Velto — Team & access admin (v158)
-- Lets an admin change roles/outlets and disable members from the app.
-- Uses a SECURITY DEFINER is_admin() so the policy can't recurse on profiles.
-- Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================
alter table public.profiles add column if not exists phone text;

create or replace function public.is_admin() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and active is true);
$$;

drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

select 'team admin policy ready' as status;
