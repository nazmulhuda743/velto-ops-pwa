-- ============================================================================
-- Velto — Ops expansion (v215)
-- Weekly Pickups · Iron Floor board counts · Outsourced Ironmen · auto-tasks.
-- Run ONCE in Supabase → SQL Editor → paste → Run. Safe to re-run (idempotent).
-- The pg_cron job at the bottom fires the weekly-pickup tasks at 10:00 AM Dhaka.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) WEEKLY SUBSCRIPTIONS — recurring pickup customers
-- ---------------------------------------------------------------------------
create table if not exists public.weekly_subscriptions (
  id                 uuid primary key default gen_random_uuid(),
  customer_id        uuid,                       -- optional link to an existing customer
  name               text not null,
  phone              text,
  address            text,
  sector             text,                       -- 'Sector 11' | 'RUAP' | free text
  outlet_code        text default 'S11',         -- 'S11' | 'RUAP'
  days               int[] not null default '{}',-- 0=Sun .. 6=Sat  (JS getDay)
  time_window        text,                        -- '9-11 AM'
  service_category   text,                        -- 'Wash + Iron' | 'Only iron' | 'Dry Cleaning'
  price_per_run      numeric default 0,
  assigned_staff_id  uuid,                        -- the rider who runs this pickup
  assigned_staff_name text,
  status             text not null default 'active',  -- active | paused
  is_vip             boolean not null default false,
  settled            boolean not null default false,  -- true = no outstanding dues
  resumes_on         date,                        -- when a paused subscription resumes
  note               text,
  created_by         uuid,
  created_by_name    text,
  created_at         timestamptz not null default now()
);
create index if not exists wk_sub_status_idx on public.weekly_subscriptions(status, outlet_code);

-- ---------------------------------------------------------------------------
-- 2) IRON BOARD COUNTS — the physical count the ironman/rider does on the board.
--    Split by type because the capacity math differs (wash-iron slower than iron).
-- ---------------------------------------------------------------------------
create table if not exists public.iron_board_counts (
  id              uuid primary key default gen_random_uuid(),
  outlet_code     text default 'S11',
  count_date      date not null default (now() at time zone 'Asia/Dhaka')::date,
  iron_only_pcs   int not null default 0,         -- fast: 10-15/hr
  wash_iron_pcs   int not null default 0,         -- wash-first: ~10/hr
  dc_pcs          int not null default 0,         -- wash-first: ~10/hr
  blazer_pcs      int not null default 0,         -- slow: 20-30 min each
  sharee_pcs      int not null default 0,         -- slow: 20-30 min each
  counted_by_id   uuid,
  counted_by_name text,
  role_counted    text,                           -- 'ironman' | 'rider' | 'manager'
  note            text,
  created_at      timestamptz not null default now()
);
-- newest row per (outlet, day) is authoritative
create index if not exists iron_counts_day_idx on public.iron_board_counts(outlet_code, count_date, created_at desc);

-- ---------------------------------------------------------------------------
-- 3) OUTSOURCED IRONMEN — partners we can push Iron Floor overflow to
-- ---------------------------------------------------------------------------
create table if not exists public.outsource_partners (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  ptype          text default 'freelance',        -- 'in-house pool' | 'freelance' | 'vendor'
  location       text,                             -- 'Sector 11'
  phone          text,
  rate_per_pc    numeric default 0,                -- ৳/pc
  daily_capacity int default 0,                    -- pcs they can take per day
  on_time_pct    numeric default 100,
  tenure         text,                             -- '3 yrs' | free text
  frees_at       text,                             -- e.g. 'frees ~6 PM' (optional note)
  active         boolean not null default true,
  note           text,
  created_by     uuid,
  created_by_name text,
  created_at     timestamptz not null default now()
);

create table if not exists public.outsource_assignments (
  id             uuid primary key default gen_random_uuid(),
  partner_id     uuid not null references public.outsource_partners(id) on delete cascade,
  assign_date    date not null default (now() at time zone 'Asia/Dhaka')::date,
  pcs_wash       int not null default 0,           -- wash-iron pcs placed
  pcs_iron       int not null default 0,           -- iron-only pcs placed
  pcs            int not null default 0,           -- total pcs
  rate_per_pc    numeric default 0,
  amount         numeric default 0,                -- pcs * rate
  paid           numeric default 0,
  status         text not null default 'placed',   -- placed | received | paid
  outlet_code    text default 'S11',
  created_by     uuid,
  created_by_name text,
  note           text,
  created_at     timestamptz not null default now()
);
create index if not exists outsrc_assign_idx on public.outsource_assignments(partner_id, assign_date, status);

-- ---------------------------------------------------------------------------
-- 4) TASKS — dedupe columns so auto-created weekly tasks never duplicate
-- ---------------------------------------------------------------------------
alter table public.tasks add column if not exists source     text;
alter table public.tasks add column if not exists source_ref text;
alter table public.tasks add column if not exists dedupe_key text;
create unique index if not exists tasks_dedupe_uidx on public.tasks(dedupe_key) where dedupe_key is not null;

-- ---------------------------------------------------------------------------
-- RLS — shared trusted team, same convention as the rest of Velto
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['weekly_subscriptions','iron_board_counts','outsource_partners','outsource_assignments']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I_sel on public.%I', t, t);
    execute format('create policy %I_sel on public.%I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists %I_ins on public.%I', t, t);
    execute format('create policy %I_ins on public.%I for insert to authenticated with check (true)', t, t);
    execute format('drop policy if exists %I_upd on public.%I', t, t);
    execute format('create policy %I_upd on public.%I for update to authenticated using (true) with check (true)', t, t);
    execute format('drop policy if exists %I_del on public.%I', t, t);
    execute format('create policy %I_del on public.%I for delete to authenticated using (true)', t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5) AUTO-TASKS — build today's pickup/delivery runs + tomorrow's follow-ups
--    from active weekly subscriptions. Idempotent via dedupe_key.
-- ---------------------------------------------------------------------------
create or replace function public.create_weekly_pickup_tasks() returns void
language plpgsql security definer as $$
declare
  d_today  date := (now() at time zone 'Asia/Dhaka')::date;
  d_tom    date := d_today + 1;
  dow_tod  int  := extract(dow from (now() at time zone 'Asia/Dhaka'))::int;
  dow_tom  int  := extract(dow from ((now() at time zone 'Asia/Dhaka') + interval '1 day'))::int;
  s        record;
  ids      uuid[];
  nms      text[];
begin
  -- TODAY → a pickup task (AM) and a delivery task (PM) for the assigned rider
  for s in select * from public.weekly_subscriptions where status = 'active' and dow_tod = any(days) loop
    ids := case when s.assigned_staff_id is not null then array[s.assigned_staff_id] else '{}'::uuid[] end;
    nms := case when s.assigned_staff_name is not null then array[s.assigned_staff_name] else '{}'::text[] end;
    insert into public.tasks(title,type,assignee_ids,assignee_names,assigned_to,assigned_to_name,assigned_by_name,
                             due_at,outlet_code,priority,status,note,source,source_ref,dedupe_key)
    values('Weekly pickup · '||s.name||coalesce(' ('||s.time_window||')',''),'pickup',ids,nms,
           s.assigned_staff_id,s.assigned_staff_name,'Velto (auto)',
           ((d_today::timestamp) + interval '9 hour') at time zone 'Asia/Dhaka',
           coalesce(s.outlet_code,'S11'), case when s.is_vip then 'high' else 'normal' end,'open',
           coalesce(s.address,'')||coalesce(' · '||s.service_category,'')||' · ৳'||coalesce(s.price_per_run,0)||'/run',
           'weekly',s.id::text,'wk:'||s.id::text||':'||d_today::text||':pickup')
    on conflict (dedupe_key) do nothing;

    insert into public.tasks(title,type,assignee_ids,assignee_names,assigned_to,assigned_to_name,assigned_by_name,
                             due_at,outlet_code,priority,status,note,source,source_ref,dedupe_key)
    values('Weekly delivery · '||s.name,'delivery',ids,nms,
           s.assigned_staff_id,s.assigned_staff_name,'Velto (auto)',
           ((d_today::timestamp) + interval '17 hour') at time zone 'Asia/Dhaka',
           coalesce(s.outlet_code,'S11'),'normal','open',
           'Return the finished '||coalesce(s.service_category,'items')||' to '||coalesce(s.address,s.name),
           'weekly',s.id::text,'wk:'||s.id::text||':'||d_today::text||':delivery')
    on conflict (dedupe_key) do nothing;
  end loop;

  -- TOMORROW → a HIGH-priority confirm/follow-up the day before
  for s in select * from public.weekly_subscriptions where status = 'active' and dow_tom = any(days) loop
    ids := case when s.assigned_staff_id is not null then array[s.assigned_staff_id] else '{}'::uuid[] end;
    nms := case when s.assigned_staff_name is not null then array[s.assigned_staff_name] else '{}'::text[] end;
    insert into public.tasks(title,type,assignee_ids,assignee_names,assigned_to,assigned_to_name,assigned_by_name,
                             due_at,outlet_code,priority,status,note,source,source_ref,dedupe_key)
    values('Confirm tomorrow''s pickup · '||s.name||coalesce(' ('||s.time_window||')',''),'call',ids,nms,
           s.assigned_staff_id,s.assigned_staff_name,'Velto (auto)',
           ((d_today::timestamp) + interval '19 hour') at time zone 'Asia/Dhaka',
           coalesce(s.outlet_code,'S11'),'high','open',
           'Message '||s.name||' to confirm tomorrow''s '||coalesce(s.time_window,'pickup')||' — '||coalesce(s.address,''),
           'weekly',s.id::text,'wk:'||s.id::text||':'||d_tom::text||':followup')
    on conflict (dedupe_key) do nothing;
  end loop;
end $$;

-- Fire it once now so you see tasks immediately (safe — idempotent).
select public.create_weekly_pickup_tasks();

-- Schedule: 10:00 AM Dhaka == 04:00 UTC.
create extension if not exists pg_cron;
select cron.unschedule('velto-weekly-pickup-tasks')
where exists (select 1 from cron.job where jobname = 'velto-weekly-pickup-tasks');
select cron.schedule('velto-weekly-pickup-tasks','0 4 * * *',
  $$ select public.create_weekly_pickup_tasks(); $$);

-- VERIFY
select 'velto v215 ops ready' as status;
select jobname, schedule, active from cron.job where jobname = 'velto-weekly-pickup-tasks';
