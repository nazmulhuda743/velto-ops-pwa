-- ============================================================================
-- Velto — CEO / Admin Cockpit: one server-side aggregate over both outlets.
--
-- Reads the data the automations already write (orders + iron_* timestamps +
-- tasks.sla_* accountability history + floor_issues) and returns everything the
-- cockpit renders, in one JSON:
--   • andon        — WIP per stage + oldest age + colour (the line right now)
--   • constraint   — the stage that's piling up (the bottleneck)
--   • north_star   — completed-good-order rate (on-time AND paid AND no issue)
--   • needs_you    — exception cards (management by exception)
--   • head2head    — Bappy vs Monir, pulled from the accountability engine
--   • leak         — delivered-but-unpaid, aged into buckets
--   • pareto       — why the chases happen (fix the top cause = kaizen)
--
-- Also adds orders.delivered_at (set on delivery) so "on-time" and aging are
-- reliable. Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================

-- reliable delivered timestamp -------------------------------------------------
alter table public.orders add column if not exists delivered_at timestamptz;

create or replace function public.on_order_delivered()
  returns trigger language plpgsql security definer set search_path = public as $$
begin
  if NEW.order_status = 'Delivered' and coalesce(OLD.order_status,'') <> 'Delivered'
     and NEW.delivered_at is null then
    NEW.delivered_at := now();
  end if;
  return NEW;
end $$;

drop trigger if exists trg_order_delivered on public.orders;
create trigger trg_order_delivered before update of order_status on public.orders
  for each row execute function public.on_order_delivered();

-- backfill existing delivered orders from the activity log / delivery_date
update public.orders o set delivered_at = coalesce(
    o.delivered_at,
    (select max(al.created_at) from public.activity_log al
      where al.order_number = o.order_number and (al.detail = 'Delivered' or al.kind = 'delivered')),
    o.delivery_date::timestamptz)
 where o.order_status = 'Delivered' and o.delivered_at is null;

-- the cockpit aggregate --------------------------------------------------------
create or replace function public.cockpit_stats()
  returns jsonb language plpgsql security definer set search_path = public as $$
declare
  wk_from   timestamptz := now() - interval '7 days';
  prev_from timestamptz := now() - interval '14 days';
  today     date := (now() at time zone 'Asia/Dhaka')::date;
  intake_c int; intake_h numeric; wash_c int; wash_h numeric;
  iron_c int; iron_h numeric; disp_c int; disp_h numeric; deliv_c int; paid_c int;
  ns_d int; ns_g int; ns_dp int; ns_gp int; ns_rate numeric; ns_prev numeric;
  leak_t numeric; leak1 numeric; leak2 numeric; leak3 numeric;
  andon jsonb; pareto jsonb; leak_out jsonb; spark jsonb; h2h jsonb := '[]'::jsonb;
  cons jsonb := 'null'::jsonb; needs jsonb := '[]'::jsonb; stalled int;
  oc text; mname text; dlv int; ontime int; ot numeric; col numeric; resp numeric; brk int; ign int;
  brc int; brl text[]; brh numeric;
begin
  -- ANDON: WIP per stage (count + oldest age hours)
  select count(*), coalesce(extract(epoch from (now()-min(created_at)))/3600,0) into intake_c,intake_h
    from public.orders where order_status in ('New','Picked');
  select count(*), coalesce(extract(epoch from (now()-min(created_at)))/3600,0) into wash_c,wash_h
    from public.orders where order_status = 'In Wash Plant';
  select count(*), coalesce(extract(epoch from (now()-min(iron_sent_at)))/3600,0) into iron_c,iron_h
    from public.orders where iron_stage = 'sent';
  select count(*), coalesce(extract(epoch from (now()-min(coalesce(iron_ready_at,created_at)))/3600),0) into disp_c,disp_h
    from public.orders where iron_stage = 'ready'
       or order_status in ('Ready','Ready to Pick from Facility','QC Passed','Out for Delivery','In Velto Outlet');
  select count(*) into deliv_c from public.orders
    where order_status='Delivered' and coalesce(delivered_at,created_at) >= wk_from;
  select count(*) into paid_c from public.orders
    where order_status='Delivered' and coalesce(delivered_at,created_at) >= wk_from
      and coalesce(amount_paid,0) >= coalesce(total_amount,0);

  andon := jsonb_build_array(
    jsonb_build_object('key','intake','label','INTAKE','count',intake_c,'h',round(intake_h,1),
      'color', case when intake_h>=6 then 'red' when intake_h>=2 then 'amber' else 'green' end),
    jsonb_build_object('key','wash','label','WASH','count',wash_c,'h',round(wash_h,1),
      'color', case when wash_h>=40 then 'red' when wash_h>=30 then 'amber' else 'green' end),
    jsonb_build_object('key','iron','label','IRON','count',iron_c,'h',round(iron_h,1),
      'color', case when iron_h>=8 then 'red' when iron_h>=4 then 'amber' else 'green' end),
    jsonb_build_object('key','dispatch','label','DISPATCH','count',disp_c,'h',round(disp_h,1),
      'color', case when disp_h>=3 then 'red' when disp_h>=1 then 'amber' else 'green' end),
    jsonb_build_object('key','deliv','label','DELIV.','count',deliv_c,'color','green'),
    jsonb_build_object('key','paid','label','PAID','count',paid_c,
      'color', case when deliv_c>0 and paid_c::numeric/deliv_c>=0.9 then 'green' else 'amber' end));
  select count(*) into stalled from jsonb_array_elements(andon) e where e->>'color'='red';

  -- CONSTRAINT: worst red WIP stage
  select jsonb_build_object('stage',stage,'count',cnt,'h',round(h,1)) into cons from (
    select * from (values
      ('Iron',iron_c,iron_h, case when iron_h>=8 then 1 else 0 end),
      ('Wash',wash_c,wash_h, case when wash_h>=40 then 1 else 0 end),
      ('Intake',intake_c,intake_h, case when intake_h>=6 then 1 else 0 end),
      ('Dispatch',disp_c,disp_h, case when disp_h>=3 then 1 else 0 end)
    ) s(stage,cnt,h,red) where red=1 order by h desc limit 1) z;

  -- NORTH STAR: completed-good = delivered on-time AND fully paid AND no issue
  select count(*), count(*) filter (where coalesce(amount_paid,0)>=coalesce(total_amount,0)
      and (delivery_date is null or coalesce(delivered_at,created_at) <= (delivery_date::timestamptz + interval '1 day'))
      and not exists (select 1 from public.floor_issues fi where fi.order_number=o.order_number))
    into ns_d, ns_g from public.orders o
    where order_status='Delivered' and coalesce(delivered_at,created_at) >= wk_from;
  select count(*), count(*) filter (where coalesce(amount_paid,0)>=coalesce(total_amount,0)
      and (delivery_date is null or coalesce(delivered_at,created_at) <= (delivery_date::timestamptz + interval '1 day'))
      and not exists (select 1 from public.floor_issues fi where fi.order_number=o.order_number))
    into ns_dp, ns_gp from public.orders o
    where order_status='Delivered' and coalesce(delivered_at,created_at) >= prev_from and coalesce(delivered_at,created_at) < wk_from;
  ns_rate := case when ns_d>0 then round(ns_g::numeric/ns_d*100,1) else 0 end;
  ns_prev := case when ns_dp>0 then round(ns_gp::numeric/ns_dp*100,1) else 0 end;

  select coalesce(jsonb_agg(rate order by d),'[]'::jsonb) into spark from (
    select g::date d,
      (select case when count(*)>0 then round(count(*) filter (where coalesce(amount_paid,0)>=coalesce(total_amount,0)
          and (delivery_date is null or coalesce(delivered_at,created_at) <= (delivery_date::timestamptz + interval '1 day')))::numeric/count(*)*100) else null end
       from public.orders o where order_status='Delivered' and (coalesce(delivered_at,created_at) at time zone 'Asia/Dhaka')::date = g::date) rate
    from generate_series(today-6, today, interval '1 day') g) s;

  -- LEAK: delivered but unpaid, aged
  select coalesce(sum(due),0), coalesce(sum(due) filter (where ad<3),0),
         coalesce(sum(due) filter (where ad>=3 and ad<7),0), coalesce(sum(due) filter (where ad>=7),0)
    into leak_t,leak1,leak2,leak3 from (
      select (coalesce(total_amount,0)-coalesce(amount_paid,0)) due,
             extract(epoch from (now()-coalesce(delivered_at,created_at)))/86400 ad
      from public.orders where order_status='Delivered' and coalesce(total_amount,0)-coalesce(amount_paid,0) > 0) x;
  select coalesce(jsonb_agg(jsonb_build_object('outlet',outlet_code,'due',due) order by due desc),'[]'::jsonb) into leak_out from (
      select outlet_code, sum(coalesce(total_amount,0)-coalesce(amount_paid,0)) due
      from public.orders where order_status='Delivered' and coalesce(total_amount,0)-coalesce(amount_paid,0) > 0
      group by outlet_code) y;

  -- PARETO: why the chases happen
  select coalesce(jsonb_agg(jsonb_build_object('reason',sla_reason,'count',c) order by c desc),'[]'::jsonb) into pareto from (
      select sla_reason, count(*) c from public.tasks
      where sla_reason is not null and sla_kind in ('iron24','wash48','ready24') and created_at >= wk_from
      group by sla_reason) p;

  -- HEAD TO HEAD: per outlet, from the accountability engine
  foreach oc in array array['S11','RUAP'] loop
    select name into mname from public.profiles where role='manager' and outlet=oc and active is true order by created_at nulls last limit 1;
    select count(*), count(*) filter (where delivery_date is null or coalesce(delivered_at,created_at) <= (delivery_date::timestamptz + interval '1 day'))
      into dlv, ontime from public.orders where outlet_code=oc and order_status='Delivered' and coalesce(delivered_at,created_at) >= wk_from;
    ot := case when dlv>0 then round(ontime::numeric/dlv*100) else null end;
    select case when sum(total_amount)>0 then round(sum(amount_paid)/sum(total_amount)*100) else null end into col
      from public.orders where outlet_code=oc and order_status='Delivered' and coalesce(delivered_at,created_at) >= wk_from;
    select coalesce(sum(coalesce(sla_reopens,0)),0) into brk from public.tasks
      where outlet_code=oc and sla_kind in ('iron24','wash48','ready24') and created_at >= wk_from;
    select count(*) into ign from public.tasks where outlet_code=oc and sla_kind='ignored' and created_at >= wk_from;
    select round(avg(r)/60000) into resp from (
      select (select min((e->>'ts')::bigint) from jsonb_array_elements(t.sla_history) e where coalesce(e->>'who','')<>'Velto')
           - (select min((e->>'ts')::bigint) from jsonb_array_elements(t.sla_history) e where e->>'type'='opened') r
      from public.tasks t where t.outlet_code=oc and t.sla_kind in ('iron24','wash48','ready24') and t.created_at >= wk_from) z
      where r is not null and r > 0;
    h2h := h2h || jsonb_build_array(jsonb_build_object(
      'outlet',oc,'name',coalesce(mname,oc),'on_time',ot,'collection',col,'resp_m',resp,'broken',brk,'ignores',ign));
  end loop;

  -- NEEDS YOU: exception cards (management by exception)
  select count(*), coalesce(array_agg(order_number order by iron_sent_at),'{}'), coalesce(extract(epoch from (now()-min(iron_sent_at)))/3600,0)
    into brc, brl, brh from public.orders where iron_stage='sent' and iron_sent_at < now() - interval '5 hours';
  if coalesce(brc,0) > 0 then
    needs := needs || jsonb_build_array(jsonb_build_object(
      'type','iron_backlog','title', brc || ' orders waiting at the press',
      'why','Sitting >5h at iron — the backlog, not the riders.',
      'orders', to_jsonb(brl[1:3]), 'age_h', round(brh,1)));
  end if;
  if coalesce(leak3,0) > 0 then
    needs := needs || jsonb_build_array(jsonb_build_object(
      'type','unpaid_rot','title','৳'|| to_char(leak3,'FM999,999') ||' unpaid 7+ days',
      'why','Delivered money aging past a week — chase collection.', 'age_h', null));
  end if;

  return jsonb_build_object(
    'in_flight', (select count(*) from public.orders where coalesce(order_status,'') not in ('Delivered','Cancelled')),
    'andon', andon, 'stalled', stalled, 'constraint', cons,
    'north_star', jsonb_build_object('rate',ns_rate,'delta',round(ns_rate-ns_prev,1),'spark',spark),
    'needs_you', needs, 'head2head', h2h,
    'leak', jsonb_build_object('total',leak_t,'b1',leak1,'b2',leak2,'b3',leak3,'by_outlet',leak_out),
    'pareto', pareto);
end $$;

grant execute on function public.cockpit_stats() to authenticated;

select 'cockpit stats ready' as status;
