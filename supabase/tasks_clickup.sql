-- ============================================================================
-- Velto — Tasks upgrade: multi-assignee + status stages + subtasks + comments
-- (ClickUp-style). Additive & idempotent — existing tasks keep working.
-- Run in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================

-- Manager-or-admin helper (used to gate multi-assignee creation).
create or replace function public.is_manager() returns boolean
  language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('admin','manager') and active is true);
$$;
grant execute on function public.is_manager() to authenticated;

-- New columns (kept alongside assigned_to, which stays = the FIRST assignee so
-- every existing query, reminder and notification keeps functioning).
alter table public.tasks add column if not exists assignee_ids   uuid[] not null default '{}';
alter table public.tasks add column if not exists assignee_names text[] not null default '{}';
alter table public.tasks add column if not exists description     text;
alter table public.tasks add column if not exists subtasks        jsonb not null default '[]';

-- Backfill existing single-assignee tasks into the arrays.
update public.tasks
   set assignee_ids   = array[assigned_to],
       assignee_names = array[coalesce(assigned_to_name, '')]
 where assigned_to is not null
   and cardinality(assignee_ids) = 0;

-- Status stages are: 'open' (To-do) | 'doing' (In progress) | 'done'. We keep
-- the legacy 'open' value so the reminder function/cron keep working unchanged.

create index if not exists tasks_assignees_gin on public.tasks using gin (assignee_ids);

-- Only managers/admins may assign a task to MORE THAN ONE person; anyone can
-- still create a single-assignee task. (Reads/updates stay open to the team.)
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated
  with check ( cardinality(coalesce(assignee_ids, '{}')) <= 1 or public.is_manager() );

-- ---- Comments (ClickUp-style thread on each task) -------------------------
create table if not exists public.task_comments (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.tasks(id) on delete cascade,
  body        text not null,
  author_id   uuid,
  author_name text,
  created_at  timestamptz not null default now()
);
create index if not exists task_comments_task_idx on public.task_comments (task_id, created_at);

alter table public.task_comments enable row level security;
drop policy if exists task_comments_select on public.task_comments;
create policy task_comments_select on public.task_comments for select to authenticated using (true);
drop policy if exists task_comments_insert on public.task_comments;
create policy task_comments_insert on public.task_comments for insert to authenticated with check (true);

-- Realtime for live comments + task changes (ignore "already added").
do $$ begin alter publication supabase_realtime add table public.task_comments; exception when duplicate_object then null; end $$;

select 'tasks clickup upgrade ready' as status;
