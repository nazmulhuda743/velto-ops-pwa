-- ============================================================================
-- Velto — Order SLA automation: the accountability loop.
--
-- Runs 2x/day (10am + 6pm Dhaka). Three ways a chase begins/continues:
--
--  1) ORDER CHASE — an order rots, Velto opens a task for Bappy & Monir:
--       • IRON not delivered > 24h
--       • WASH not delivered > 48h, EXCLUDING Fridays (van off Friday)
--       • READY/QC-passed/Out-for-delivery but undelivered > 24h
--     The manager must respond with a PROMISE (reason + a delivery deadline).
--     The task then SLEEPS until that deadline.
--
--  2) BROKEN PROMISE — the promised time passes and it's still not delivered:
--     the SAME task RE-OPENS (attempt #N), the broken promise is stamped into
--     its history, and it escalates to the CEO.
--
--  3) IGNORED — the manager never responded and the task sat untouched ~6h:
--     Velto VOIDS that task and fires a new one AT THE MANAGER —
--     "why is this being ignored?" — logged to the CEO, with its own reason
--     picker. Answering it re-opens the original order chase.
--
-- Only delivering the order ends the loop. Run ONCE in Supabase → SQL Editor.
-- Replace <SERVICE_ROLE_KEY>. Safe to re-run.
-- ============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- SLA bookkeeping on the task (the whole trail lives here → "in database").
alter table public.tasks add column if not exists sla_kind         text;         -- iron24 | wash48 | ready24 | ignored
alter table public.tasks add column if not exists sla_reason       text;         -- chosen reason chip
alter table public.tasks add column if not exists sla_note         text;         -- what the customer said / note to CEO
alter table public.tasks add column if not exists sla_promise_at   timestamptz;  -- the deadline Velto will check
alter table public.tasks add column if not exists sla_reopens      int default 0;-- times a broken promise re-opened it
alter table public.tasks add column if not exists sla_escalated    boolean default false;
alter table public.tasks add column if not exists sla_history      jsonb default '[]'::jsonb;  -- attempt trail
alter table public.tasks add column if not exists sla_where        text;         -- "Zone · Customer" for the card
alter table public.tasks add column if not exists sla_delivery_note text;        -- note for the rider
alter table public.tasks add column if not exists sla_voided       boolean default false; -- order chase parked after an ignore
alter table public.tasks add column if not exists sla_parent       uuid;         -- accountability task → its order chase
alter table public.tasks add column if not exists sla_active_since timestamptz;  -- when it (re)became an open ask
alter table public.tasks add column if not exists sla_idle_ms      bigint;       -- idle time captured when voided
create index if not exists tasks_sla_idx on public.tasks (order_number, sla_kind, status);
-- Backfill the idle clock for any chase tasks that predate this column.
update public.tasks set sla_active_since = coalesce(sla_active_since, due_at, created_at)
 where sla_kind is not null and sla_active_since is null;

-- Push helper (idempotent, same as the reminders upgrade).
create or replace function public._velto_push(base text, key text, uid uuid, title text, body text)
  returns void language plpgsql security definer set search_path = public as $$
begin
  if uid is null then return; end if;
  perform net.http_post(
    url     := base || '/fcm-send',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||key),
    body    := jsonb_build_object('user_id', uid, 'title', title, 'body', body, 'url','./','tag','sla-task'));
  perform net.http_post(
    url     := base || '/notify-push',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||key),
    body    := jsonb_build_object('target_user', uid, 'title', title, 'body', body, 'url','./'));
end $$;

-- ---- The engine ------------------------------------------------------------
create or replace function public.create_sla_tasks()
  returns jsonb language plpgsql security definer set search_path = public as $$
declare
  service_key text := '<SERVICE_ROLE_KEY>';   -- <<< EDIT: Settings → API → service_role
  base text := 'https://erutxtnepbejdxkoimeo.supabase.co/functions/v1';
  ESC_AFTER   int := 1;                        -- escalate to CEO once a promise is broken this many times
  IDLE_HOURS  int := 6;                        -- untouched this long → void + question the manager
  bappy uuid; monir uuid; ids uuid[]; names text[]; admins uuid[];
  o record; ex record; ig record; u uuid;
  is_wash boolean; kind text; hrs int; raw_h numeric; fridays int; ready_since timestamptz;
  new_reopens int; esc boolean; ev jsonb; idle_ms bigint; mgr text; dur text;
  cust text; label text; opened int := 0; reopened int := 0; ignored int := 0;
begin
  -- People.
  select id into bappy from public.profiles where active is true and name ilike '%bappy%' order by created_at nulls last limit 1;
  select id into monir from public.profiles where active is true and name ilike '%monir%' order by created_at nulls last limit 1;
  select array_agg(id order by ord), array_agg(coalesce(name,'') order by ord)
    into ids, names
    from (select id, name, 1 ord from public.profiles where id = bappy
          union all select id, name, 2 ord from public.profiles where id = monir) q;
  if ids is null or array_length(ids,1) is null then
    return jsonb_build_object('ok', false, 'reason', 'Bappy/Monir not found in profiles');
  end if;
  select array_agg(id) into admins from public.profiles where active is true and role = 'admin';

  -- PASS 1 — order delivered/cancelled: end every chase on it for good.
  update public.tasks t
     set status = 'done', done_at = coalesce(t.done_at, now()), sla_promise_at = null,
         sla_history = coalesce(t.sla_history,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
           'n', jsonb_array_length(coalesce(t.sla_history,'[]'::jsonb)) + 1,
           'ts', round(extract(epoch from now()) * 1000), 'type', 'delivered', 'who', 'Velto'))
    from public.orders od
   where t.sla_kind is not null and t.order_number = od.order_number
     and coalesce(od.order_status,'') in ('Delivered','Cancelled')
     and (t.status <> 'done' or t.sla_promise_at is not null);

  -- PASS 2 — a promised deadline passed and it's still not delivered: RE-OPEN.
  for ex in
    select t.id, t.order_number, t.sla_history, t.sla_reopens, t.sla_promise_at
      from public.tasks t
      join public.orders od on od.order_number = t.order_number
     where t.sla_kind in ('iron24','wash48','ready24') and t.status = 'done'
       and coalesce(t.sla_voided,false) = false
       and t.sla_promise_at is not null and t.sla_promise_at < now()
       and coalesce(od.order_status,'') not in ('Delivered','Cancelled')
  loop
    new_reopens := coalesce(ex.sla_reopens,0) + 1;
    esc := new_reopens >= ESC_AFTER;
    ev := jsonb_build_object(
            'n', jsonb_array_length(coalesce(ex.sla_history,'[]'::jsonb)) + 1,
            'ts', round(extract(epoch from now()) * 1000), 'type', 'broken', 'who', 'Velto',
            'promise', round(extract(epoch from ex.sla_promise_at) * 1000), 'esc', esc);
    update public.tasks
       set status = 'open', done_at = null, due_at = now(), priority = 'high',
           sla_reopens = new_reopens, sla_promise_at = null, sla_escalated = esc,
           sla_reason = null, sla_active_since = now(),
           title = '🔴 ' || ex.order_number || ' — promise broken, still not delivered',
           sla_history = coalesce(ex.sla_history,'[]'::jsonb) || ev
     where id = ex.id;
    foreach u in array ids loop
      perform public._velto_push(base, service_key, u, '🔴 Promise broken — ' || ex.order_number,
              'Not delivered by the promised time. Re-opened (×' || new_reopens || '). Answer again.');
    end loop;
    if esc and admins is not null then
      foreach u in array admins loop
        perform public._velto_push(base, service_key, u, '👑 Escalated — ' || ex.order_number,
                'A delivery promise was broken ' || new_reopens || '×. Needs a manager.');
      end loop;
    end if;
    reopened := reopened + 1;
  end loop;

  -- PASS 2.5 — order chase IGNORED (no response, sat untouched): VOID + question the manager.
  for ig in
    select t.id, t.order_number, t.assignee_ids, t.assignee_names, t.assigned_to, t.assigned_to_name,
           t.outlet_code, t.sla_where, t.sla_active_since, t.sla_history
      from public.tasks t
      join public.orders od on od.order_number = t.order_number
     where t.sla_kind in ('iron24','wash48','ready24') and t.status = 'open'
       and coalesce(t.sla_voided,false) = false
       and t.sla_reason is null                                   -- never got a viable response
       and t.sla_active_since is not null
       and t.sla_active_since < now() - make_interval(hours => IDLE_HOURS)
       and coalesce(od.order_status,'') not in ('Delivered','Cancelled')
       and not exists (select 1 from public.tasks a
                        where a.sla_kind = 'ignored' and a.sla_parent = t.id and a.status <> 'done')
  loop
    idle_ms := round(extract(epoch from (now() - ig.sla_active_since)) * 1000);
    dur := (idle_ms/3600000)::int || 'h ' || ((idle_ms%3600000)/60000)::int || 'm';
    select coalesce(string_agg(split_part(n,' ',1),' & '),'Manager') into mgr from unnest(ig.assignee_names) n;

    -- void the original (parked; it re-opens once the manager explains)
    update public.tasks
       set sla_voided = true, status = 'done', done_at = now(), sla_idle_ms = idle_ms,
           sla_history = coalesce(ig.sla_history,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
             'n', jsonb_array_length(coalesce(ig.sla_history,'[]'::jsonb)) + 1,
             'ts', round(extract(epoch from now()) * 1000), 'type', 'voided', 'who', 'Velto', 'idle', idle_ms))
     where id = ig.id;

    -- fire the accountability task at the manager, logged to the CEO
    insert into public.tasks
      (title, type, assigned_to, assigned_to_name, assignee_ids, assignee_names,
       assigned_by_name, due_at, outlet_code, priority, status, description, order_number,
       sla_kind, sla_parent, sla_escalated, sla_active_since, sla_idle_ms, sla_where, sla_history)
    values
      (mgr || ', why is ' || ig.order_number || ' being ignored?',
       'process', ig.assigned_to, ig.assigned_to_name, ig.assignee_ids, ig.assignee_names,
       'Velto Auto', now(), coalesce(ig.outlet_code,'S11'), 'high', 'open',
       'A high-priority task sat untouched for ' || dur ||
         '. Tell us what happened — this is logged to the CEO. The original task re-opens the moment you respond.',
       ig.order_number, 'ignored', ig.id, true, now(), idle_ms, ig.sla_where,
       jsonb_build_array(jsonb_build_object('n',1,'ts',round(extract(epoch from now())*1000),
         'type','ignored_opened','who','Velto','idle',idle_ms)));

    foreach u in array ig.assignee_ids loop
      perform public._velto_push(base, service_key, u, '⏰ Why is ' || ig.order_number || ' ignored?',
              'A high-priority task sat untouched ' || dur || '. Explain — this is logged to the CEO.');
    end loop;
    if admins is not null then
      foreach u in array admins loop
        perform public._velto_push(base, service_key, u, '👑 Ignored — ' || ig.order_number,
                mgr || ' left it untouched ' || dur || '. Accountability task fired.');
      end loop;
    end if;
    ignored := ignored + 1;
  end loop;

  -- PASS 3 — brand-new breaches: open attempt #1 (only if no chase exists yet).
  for o in
    select id, order_number, order_status, service_category, created_at,
           outlet_code, name_snapshot, zone_snapshot
      from public.orders
     where coalesce(order_status,'') not in ('Delivered','Cancelled')
       and created_at is not null
  loop
    if exists (select 1 from public.tasks where sla_kind is not null and order_number = o.order_number) then
      continue;                                        -- already tracked (open, sleeping, voided, or accountability)
    end if;

    kind := null; hrs := null;
    raw_h := extract(epoch from (now() - o.created_at)) / 3600.0;
    is_wash := o.service_category is not null
               and (o.service_category @> array['Wash + Iron'] or o.service_category @> array['Dry Cleaning']);
    if is_wash then
      select count(*) into fridays
        from generate_series((o.created_at at time zone 'Asia/Dhaka')::date,
                             (now()        at time zone 'Asia/Dhaka')::date, interval '1 day') g
       where extract(dow from g) = 5;
      if (raw_h - 24 * fridays) > 48 then kind := 'wash48'; hrs := floor(raw_h)::int; end if;
    else
      if raw_h > 24 then kind := 'iron24'; hrs := floor(raw_h)::int; end if;
    end if;
    if o.order_status in ('QC Passed','Ready','Out for Delivery') then
      select min(al.created_at) into ready_since from public.activity_log al
       where al.order_number = o.order_number and al.kind = 'status'
         and al.detail in ('QC Passed','Ready','Out for Delivery');
      if ready_since is not null and (now() - ready_since) > interval '24 hours' then
        kind := 'ready24'; hrs := floor(extract(epoch from (now() - ready_since)) / 3600.0)::int;
      end if;
    end if;
    if kind is null then continue; end if;

    cust  := coalesce(nullif(o.name_snapshot,''), 'the customer');
    label := case kind when 'wash48' then 'wash order stuck ' || hrs || 'h'
                       when 'iron24' then 'iron order stuck ' || hrs || 'h'
                       else 'ready ' || hrs || 'h, not dispatched' end;
    ev := jsonb_build_array(jsonb_build_object(
            'n', 1, 'ts', round(extract(epoch from now()) * 1000),
            'type', 'opened', 'who', 'Velto', 'hrs', hrs, 'kind', kind));

    insert into public.tasks
      (title, type, assigned_to, assigned_to_name, assignee_ids, assignee_names,
       assigned_by_name, due_at, outlet_code, priority, status, description, order_number,
       sla_kind, sla_history, sla_where, sla_active_since)
    values
      ('⚠️ ' || o.order_number || ' — ' || label,
       'process', ids[1], names[1], ids, names,
       'Velto Auto', now(), coalesce(o.outlet_code,'S11'), 'high', 'open',
       o.order_number || ' (' || cust || ') is ' || label ||
         '. Make a promise: pick a reason and set when it will be delivered.',
       o.order_number, kind, ev,
       nullif(trim(coalesce(o.zone_snapshot,'') || ' · ' || cust), ' · '), now());

    foreach u in array ids loop
      perform public._velto_push(base, service_key, u, '⚠️ Order needs chasing',
              o.order_number || ' — ' || label || '. Promise a delivery time.');
    end loop;
    opened := opened + 1;
  end loop;

  return jsonb_build_object('ok', true, 'opened', opened, 'reopened', reopened,
                            'ignored', ignored, 'assignees', names);
end $$;

grant execute on function public.create_sla_tasks() to service_role;

-- Cron: 2x/day at 10am + 6pm Dhaka (UTC+6) → 04:00 and 12:00 UTC.
select cron.unschedule('velto-sla-tasks')
 where exists (select 1 from cron.job where jobname = 'velto-sla-tasks');
select cron.schedule('velto-sla-tasks', '0 4,12 * * *', $cron$ select public.create_sla_tasks(); $cron$);

select jobname, schedule, active from cron.job where jobname = 'velto-sla-tasks';
select 'order SLA automation (accountability loop) ready' as status;
