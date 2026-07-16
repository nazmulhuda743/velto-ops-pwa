-- ============================================================================
-- Velto — data-driven AI upgrade (v64)
-- Run this ONCE in your Supabase project: Dashboard → SQL Editor → paste → Run.
-- Creates the two tables the new features need. Safe to re-run (IF NOT EXISTS).
--   • feedback  — customer ratings + comments (feeds risk + recovery)
--   • ai_plans  — the AI's decided next-move after each logged follow-up
-- ============================================================================

-- ---------- 1. Feedback ------------------------------------------------------
create table if not exists public.feedback (
  id              uuid primary key default gen_random_uuid(),
  customer_phone  text,
  order_number    text,
  rating          int check (rating between 1 and 5),
  comment         text,
  channel         text,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create index if not exists feedback_phone_idx    on public.feedback (customer_phone);
create index if not exists feedback_created_idx  on public.feedback (created_at desc);

alter table public.feedback enable row level security;

-- Signed-in staff can read and add feedback. (Mirrors how reorder_actions is used.)
drop policy if exists feedback_select on public.feedback;
create policy feedback_select on public.feedback
  for select to authenticated using (true);

drop policy if exists feedback_insert on public.feedback;
create policy feedback_insert on public.feedback
  for insert to authenticated with check (true);

-- ---------- 2. AI plans (the closed loop) -----------------------------------
create table if not exists public.ai_plans (
  id              uuid primary key default gen_random_uuid(),
  customer_phone  text not null,
  next_channel    text,          -- 'Call' | 'WhatsApp' | 'Wait'
  next_in_days    int,
  follow_up_on    date,
  angle           text,          -- short label of the approach
  reasoning       text,          -- one line the staff sees
  message         text,          -- pre-drafted next message
  source_outcome  text,          -- what the CSR logged that triggered this
  created_by_name text,
  created_at      timestamptz not null default now()
);
create index if not exists ai_plans_phone_idx   on public.ai_plans (customer_phone);
create index if not exists ai_plans_created_idx  on public.ai_plans (created_at desc);

alter table public.ai_plans enable row level security;

drop policy if exists ai_plans_select on public.ai_plans;
create policy ai_plans_select on public.ai_plans
  for select to authenticated using (true);

drop policy if exists ai_plans_insert on public.ai_plans;
create policy ai_plans_insert on public.ai_plans
  for insert to authenticated with check (true);

-- Done. The app auto-detects these tables; until they exist it runs on local
-- data and simply shows less — it never errors.
