-- ============================================================================
-- Velto — native push device tokens (Phase 2 / FCM)
-- Each installed Android app registers its FCM token here so the server can
-- push a buzzing notification to a specific person even when the phone is
-- locked. Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================

create table if not exists public.device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  token        text not null unique,          -- the FCM registration token
  platform     text default 'android',        -- android | ios | web
  user_name    text,
  updated_at   timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

-- A signed-in user can register / see / remove their OWN device tokens.
drop policy if exists device_tokens_select_own on public.device_tokens;
create policy device_tokens_select_own on public.device_tokens
  for select to authenticated using (user_id = auth.uid());

drop policy if exists device_tokens_insert_own on public.device_tokens;
create policy device_tokens_insert_own on public.device_tokens
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists device_tokens_update_own on public.device_tokens;
create policy device_tokens_update_own on public.device_tokens
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists device_tokens_delete_own on public.device_tokens;
create policy device_tokens_delete_own on public.device_tokens
  for delete to authenticated using (user_id = auth.uid());

-- The edge function reads tokens with the service_role key, which bypasses RLS,
-- so no extra policy is needed for the server to send.

select 'device_tokens ready' as status;
