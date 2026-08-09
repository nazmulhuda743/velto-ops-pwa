-- ============================================================================
-- Velto — Floor Issues / সমস্যা জানান (v162)
-- Workers report a problem (stain, torn, supplies out, machine broken…) with a
-- photo; managers decide (re-wash / call customer / resolve) and the worker is
-- told instantly via a task. Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================

create table if not exists public.floor_issues (
  id               uuid primary key default gen_random_uuid(),
  order_number     text,
  issue_type       text not null,          -- stain|torn|color|button|count|lost|supplies|machine|other
  note             text,
  photo_path       text,
  outlet_code      text,
  status           text not null default 'open',   -- open | resolved
  decision         text,                            -- rewash | call | resolve
  reported_by      uuid, reported_by_name text,
  notify_to        uuid, notify_to_name  text,
  resolved_by_name text, resolved_at timestamptz,
  created_at       timestamptz not null default now()
);
create index if not exists floor_issues_open_idx on public.floor_issues (status, created_at desc);

alter table public.floor_issues enable row level security;
drop policy if exists floor_issues_select on public.floor_issues;
create policy floor_issues_select on public.floor_issues for select to authenticated using (true);
drop policy if exists floor_issues_insert on public.floor_issues;
create policy floor_issues_insert on public.floor_issues for insert to authenticated with check (true);
drop policy if exists floor_issues_update on public.floor_issues;
create policy floor_issues_update on public.floor_issues for update to authenticated using (true) with check (true);

-- Realtime (ignore "already member" on re-run)
do $$ begin
  alter publication supabase_realtime add table public.floor_issues;
exception when duplicate_object then null; end $$;

select 'floor_issues ready' as status;
