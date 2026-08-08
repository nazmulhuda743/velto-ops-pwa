-- ============================================================================
-- Velto — profile photos (v157)
-- Adds an avatar_url column and lets each person update their OWN profile
-- (needed so the Settings screen can save a profile photo).
-- Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================
alter table public.profiles add column if not exists avatar_url text;

-- Allow a signed-in user to update their own profile row (name/avatar).
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

select 'profiles.avatar_url ready' as status;
