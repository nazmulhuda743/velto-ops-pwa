-- ============================================================================
-- Velto — Ironman ops: manager notifications + issue escalation.
--
--  1) READY → the outlet manager is pinged the moment Oli marks an order
--     'Ready to Pick from Facility'.
--  2) ISSUE → when Oli reports a problem (সমস্যা), Velto immediately creates a
--     HIGH-priority task for that outlet's manager (S11=Bappy, RUAP=Monir),
--     pings them, and then RE-PINGS every 30 minutes until it's resolved.
--
-- Server-driven (triggers + a 10-min cron) so it fires even if a phone is off.
-- Run ONCE in Supabase → SQL Editor. Replace <SERVICE_ROLE_KEY>. Safe to re-run.
-- ============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- escalation bookkeeping on the issue
alter table public.floor_issues add column if not exists task_id     uuid;
alter table public.floor_issues add column if not exists notified_at timestamptz;
alter table public.floor_issues add column if not exists escalations int default 0;

-- Push helper (idempotent, same one the reminders/SLA engines use).
create or replace function public._velto_push(base text, key text, uid uuid, title text, body text)
  returns void language plpgsql security definer set search_path = public as $$
begin
  if uid is null then return; end if;
  perform net.http_post(
    url     := base || '/fcm-send',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||key),
    body    := jsonb_build_object('user_id', uid, 'title', title, 'body', body, 'url','./','tag','iron'));
  perform net.http_post(
    url     := base || '/notify-push',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||key),
    body    := jsonb_build_object('target_user', uid, 'title', title, 'body', body, 'url','./'));
end $$;

-- The manager for an outlet: exact-outlet manager first (S11→Bappy, RUAP→Monir),
-- then an 'all' manager, then any manager, then an admin. Always returns one.
create or replace function public._iron_mgr(oc text)
  returns table(uid uuid, uname text) language sql stable security definer set search_path = public as $$
  select id, name from public.profiles
   where active is true and role in ('manager','admin')
   order by (role='manager' and outlet = oc) desc,
            (role='manager' and outlet = 'all') desc,
            (role='manager') desc,
            (role='admin') desc,
            created_at asc nulls last
   limit 1;
$$;

-- ---- 1) ISSUE reported by the ironman → task + immediate push -------------
create or replace function public.on_iron_issue()
  returns trigger language plpgsql security definer set search_path = public as $$
declare
  service_key text := '<SERVICE_ROLE_KEY>';   -- <<< EDIT: Settings → API → service_role
  base text := 'https://erutxtnepbejdxkoimeo.supabase.co/functions/v1';
  rep_role text; mgr record; tid uuid; lbl text;
begin
  select role into rep_role from public.profiles where id = NEW.reported_by;
  if coalesce(rep_role,'') <> 'ironman' then return NEW; end if;   -- only ironman issues escalate this way
  select * into mgr from public._iron_mgr(NEW.outlet_code);
  if mgr.uid is null then return NEW; end if;

  lbl := coalesce(nullif(NEW.note,''), NEW.issue_type);
  insert into public.tasks
    (title, type, assigned_to, assigned_to_name, assignee_ids, assignee_names,
     assigned_by_name, due_at, outlet_code, priority, status, description, order_number)
  values
    ('🚩 ' || coalesce(NEW.order_number,'') || ' — ইস্ত্রিতে সমস্যা',
     'process', mgr.uid, mgr.uname, array[mgr.uid], array[mgr.uname],
     'Velto Auto', now(), NEW.outlet_code, 'high', 'open',
     'ইস্ত্রিম্যান সমস্যা জানিয়েছে: ' || lbl || '। এখনই দেখুন ও সমাধান করুন।', NEW.order_number)
  returning id into tid;

  update public.floor_issues set task_id = tid, notified_at = now(), escalations = 0 where id = NEW.id;
  perform public._velto_push(base, service_key, mgr.uid,
    '🚩 জরুরি — ' || coalesce(NEW.order_number,''),
    'ইস্ত্রিতে সমস্যা: ' || lbl || '। এখনই ব্যবস্থা নিন।');
  return NEW;
end $$;

drop trigger if exists trg_iron_issue on public.floor_issues;
create trigger trg_iron_issue after insert on public.floor_issues
  for each row execute function public.on_iron_issue();

-- ---- 2) READY → ping the outlet manager -----------------------------------
create or replace function public.on_iron_ready()
  returns trigger language plpgsql security definer set search_path = public as $$
declare
  service_key text := '<SERVICE_ROLE_KEY>';   -- <<< EDIT: same service_role key
  base text := 'https://erutxtnepbejdxkoimeo.supabase.co/functions/v1';
  mgr record; cnt int;
begin
  if NEW.order_status = 'Ready to Pick from Facility'
     and coalesce(OLD.order_status,'') <> 'Ready to Pick from Facility' then
    select * into mgr from public._iron_mgr(NEW.outlet_code);
    if mgr.uid is not null then
      cnt := coalesce(NEW.iron_count, NEW.total_items, 0);
      perform public._velto_push(base, service_key, mgr.uid,
        '✅ ' || coalesce(NEW.order_number,'') || ' — ইস্ত্রি শেষ',
        cnt || 'টি জিনিস নিতে প্রস্তুত (facility থেকে)।');
    end if;
  end if;
  return NEW;
end $$;

drop trigger if exists trg_iron_ready on public.orders;
create trigger trg_iron_ready after update of order_status on public.orders
  for each row execute function public.on_iron_ready();

-- ---- 3) ESCALATION cron — re-nag every 30 min until resolved ---------------
create or replace function public.escalate_iron_issues()
  returns jsonb language plpgsql security definer set search_path = public as $$
declare
  service_key text := '<SERVICE_ROLE_KEY>';   -- <<< EDIT: same service_role key
  base text := 'https://erutxtnepbejdxkoimeo.supabase.co/functions/v1';
  r record; mgr record; lbl text; mins int; n int := 0;
begin
  -- issues whose task is done → stop nagging (auto-resolve)
  update public.floor_issues fi
     set status = 'resolved', resolved_at = coalesce(fi.resolved_at, now())
    from public.tasks t
   where t.id = fi.task_id and t.status = 'done' and fi.status = 'open';

  -- still open + 30 min since the last ping → ping again
  for r in
    select fi.id, fi.order_number, fi.outlet_code, fi.note, fi.issue_type, fi.created_at
      from public.floor_issues fi
      left join public.tasks t on t.id = fi.task_id
     where fi.status = 'open' and fi.task_id is not null
       and coalesce(t.status,'open') <> 'done'
       and fi.notified_at is not null
       and fi.notified_at < now() - interval '30 minutes'
  loop
    select * into mgr from public._iron_mgr(r.outlet_code);
    if mgr.uid is null then continue; end if;
    lbl := coalesce(nullif(r.note,''), r.issue_type);
    mins := floor(extract(epoch from (now() - r.created_at)) / 60.0)::int;
    perform public._velto_push(base, service_key, mgr.uid,
      '⏰ এখনও সমাধান হয়নি — ' || coalesce(r.order_number,''),
      'ইস্ত্রির সমস্যা (' || lbl || ') ' || mins || ' মিনিট ধরে খোলা। সমাধান করুন।');
    update public.floor_issues set notified_at = now(), escalations = coalesce(escalations,0) + 1 where id = r.id;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'nagged', n);
end $$;

grant execute on function public.escalate_iron_issues() to service_role;

select cron.unschedule('velto-iron-escalate')
 where exists (select 1 from cron.job where jobname = 'velto-iron-escalate');
select cron.schedule('velto-iron-escalate', '*/10 * * * *', $cron$ select public.escalate_iron_issues(); $cron$);

select jobname, schedule, active from cron.job where jobname = 'velto-iron-escalate';
select 'ironman ops (notify + escalation) ready' as status;
