-- ============================================================================
-- Velto — Team Tasks (v151)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- A shared team to-do: anyone creates a task and assigns it to a teammate;
-- everyone can see the board; the assignee sees it under "Assigned to me".
-- Notifications (assign + 30-min reminder) are handled separately in v152.
-- ============================================================================

create table if not exists public.tasks (
  id               uuid primary key default gen_random_uuid(),
  title            text not null,
  type             text not null default 'other',   -- pickup | delivery | call | process | other
  assigned_to      uuid,                             -- profiles.id / auth uid of the assignee
  assigned_to_name text,                             -- snapshot for display
  assigned_by      uuid,
  assigned_by_name text,
  due_at           timestamptz,                      -- when it needs doing (drives the reminder)
  outlet_code      text,                             -- 'S11' | 'RUAP' | 'ALL'
  priority         text not null default 'normal',   -- low | normal | high
  status           text not null default 'open',     -- open | done
  done_at          timestamptz,
  done_by_name     text,
  notified         boolean not null default false,   -- assign push sent
  reminded         boolean not null default false,   -- 30-min reminder push sent
  created_at       timestamptz not null default now()
);
create index if not exists tasks_open_idx     on public.tasks (status, due_at);
create index if not exists tasks_assignee_idx on public.tasks (assigned_to, status);

alter table public.tasks enable row level security;

-- Shared board for a small trusted team: everyone reads all, anyone creates,
-- anyone updates (tick off / edit) and removes. Tighten later if needed.
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated using (true);
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated with check (true);
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update to authenticated using (true) with check (true);
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete to authenticated using (true);

-- VERIFY
select 'tasks table ready' as status;
