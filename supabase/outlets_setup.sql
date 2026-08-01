-- ============================================================================
-- Velto — Multi-outlet foundation (v124) · "Velto Sector 11" + "Velto RUAP"
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
--
--   • SAFETY GUARD          — inspects how order numbers are generated today
--                             and REFUSES to proceed if the one dangerous
--                             pattern (max-scan) is detected. Nothing is
--                             changed in that case.
--   • outlets               — outlet registry: name, contact, review link,
--                             own number prefix + independent counter.
--                             Sector 11 keeps VEL-xxxxx untouched;
--                             RUAP starts fresh at VELR-01001.
--   • orders.outlet_code    — which outlet owns the order (existing 1,400+
--                             orders stay Sector 11 via the default).
--   • activity_log.outlet_code — outlet on the team activity feed.
--   • profiles.outlet       — PERMISSION per person: 'S11' | 'RUAP' | 'all'.
--                             Founder is set to 'all' automatically.
--   • claim_outlet_number() — atomic, tamper-proof per-outlet numbering.
--
-- Everything is additive; the app self-heals if this hasn't run yet.
-- ============================================================================

-- ---------- 0. SAFETY GUARD (runs first; aborts the script if unsafe) -------
-- VELR- sorts above VEL- alphabetically. That is only a problem if the number
-- generator computes "next" by scanning MAX(order_number). This block reads
-- the actual generator (column default, triggers, and the create RPC) and
-- stops with a clear message if that pattern exists — check the Messages tab
-- for the printed definitions and send them to Claude in that case.
do $$
declare d text; r record; bad boolean := false;
begin
  select column_default into d from information_schema.columns
   where table_schema='public' and table_name='orders' and column_name='order_number';
  raise notice 'order_number column default: %', coalesce(d,'(none)');
  if d is not null and d ilike '%max(%' then bad := true; end if;

  for r in select p.proname, pg_get_functiondef(p.oid) as def
             from pg_trigger t join pg_proc p on p.oid = t.tgfoid
            where t.tgrelid = 'public.orders'::regclass and not t.tgisinternal loop
    raise notice 'orders trigger function %: %', r.proname, left(r.def, 3000);
    if r.def ilike '%order_number%' and r.def ilike '%max(%' then bad := true; end if;
  end loop;

  for r in select pg_get_functiondef(p.oid) as def
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public' and p.proname='create_order_with_items' loop
    raise notice 'RPC create_order_with_items: %', left(r.def, 3000);
    if r.def ilike '%order_number%' and r.def ilike '%max(%' then bad := true; end if;
  end loop;

  if bad then
    raise exception 'SAFETY STOP: your order numbering scans MAX(order_number), which the new VELR- prefix could disturb. NOTHING was changed. Copy the definitions printed in the Messages tab and send them to Claude — a one-line fix will be prepared first.';
  end if;
  raise notice 'Numbering generator is safe for the VELR- prefix. Proceeding.';
end $$;

-- ---------- 1. Outlets registry --------------------------------------------
create table if not exists public.outlets (
  code       text primary key,             -- 'S11' | 'RUAP'
  name       text not null,
  tagline    text not null default 'Premium Laundry & Dry Cleaning',
  address    text,
  phone      text,
  review_url text,                         -- per-outlet Google review link
  prefix     text not null,                -- order-number prefix
  next_no    int  not null,                -- next number this outlet hands out
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- Sector 11: keeps its legacy VEL sequence (counter mirrored for future use).
insert into public.outlets (code, name, prefix, next_no)
select 'S11', 'Velto Sector 11', 'VEL',
       coalesce((select max((regexp_match(order_number,'(\d+)'))[1]::int)
                   from public.orders where order_number like 'VEL-%'), 1110) + 1
where not exists (select 1 from public.outlets where code='S11');

-- RUAP: fresh independent sequence → first order is VELR-01001.
insert into public.outlets (code, name, prefix, next_no)
select 'RUAP', 'Velto RUAP', 'VELR', 1001
where not exists (select 1 from public.outlets where code='RUAP');

-- If an earlier draft seeded a different RUAP prefix, correct it (idempotent).
update public.outlets set prefix='VELR' where code='RUAP' and prefix<>'VELR';

alter table public.outlets enable row level security;
drop policy if exists outlets_select on public.outlets;
create policy outlets_select on public.outlets
  for select to authenticated using (true);
-- (no insert/update policies on purpose — counters change only through the
--  security-definer function below, so nobody can tamper with sequences)

-- ---------- 2. Outlet ownership on orders -----------------------------------
alter table public.orders
  add column if not exists outlet_code text not null default 'S11';
create index if not exists orders_outlet_idx on public.orders (outlet_code);

-- ---------- 3. Outlet on the activity feed (only if the feed table exists) --
do $$
begin
  if to_regclass('public.activity_log') is not null then
    alter table public.activity_log add column if not exists outlet_code text;
    update public.activity_log set outlet_code='S11' where outlet_code is null;
  end if;
end $$;

-- ---------- 4. Outlet PERMISSION per person ----------------------------------
-- 'S11' or 'RUAP' = fixed outlet (no switch shown in the app, zero friction).
-- 'all' = founder/overview: can switch Sector 11 / RUAP / All outlets.
alter table public.profiles
  add column if not exists outlet text not null default 'S11';

-- Founder gets 'all' automatically.
update public.profiles p set outlet='all'
  from auth.users u
 where u.id = p.id and lower(u.email) = 'nazmulhuda0327@gmail.com';

-- Assign RUAP staff whenever hired (edit the email, run just this line):
-- update public.profiles p set outlet='RUAP' from auth.users u
--  where u.id=p.id and lower(u.email)='ruap.staff@example.com';

-- ---------- 5. Atomic per-outlet numbering -----------------------------------
-- Called by the app right after an order is created at a non-S11 outlet:
-- bumps that outlet's counter and renumbers the order in one atomic step.
create or replace function public.claim_outlet_number(p_outlet text, p_order uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_no     int;
  v_prefix text;
  v_num    text;
begin
  update public.outlets
     set next_no = next_no + 1
   where code = p_outlet and active
  returning next_no - 1, prefix into v_no, v_prefix;

  if v_no is null then
    return null;                      -- unknown/inactive outlet → caller keeps VEL number
  end if;

  v_num := v_prefix || '-' || lpad(v_no::text, 5, '0');

  update public.orders
     set order_number = v_num,
         outlet_code  = p_outlet
   where id = p_order;

  return v_num;
end;
$$;

revoke all on function public.claim_outlet_number(text, uuid) from public;
grant execute on function public.claim_outlet_number(text, uuid) to authenticated;

-- ---------- 6. RUAP details, whenever known ----------------------------------
-- update public.outlets set address='House xx, Road xx, RUAP, Uttara', phone='01XXXXXXXXX' where code='RUAP';
-- update public.outlets set review_url='https://g.page/r/XXXX/review' where code='RUAP';
-- update public.outlets set review_url='https://g.page/r/XXXX/review' where code='S11';

-- ---------- VERIFY ------------------------------------------------------------
select code, name, prefix, next_no, active from public.outlets order by code;
select outlet_code, count(*) from public.orders group by outlet_code;
select p.name, p.role, p.outlet from public.profiles p order by p.name;

-- ---------- ROLLBACK (only if ever needed) ------------------------------------
-- drop function if exists public.claim_outlet_number(text, uuid);
-- alter table public.orders   drop column if exists outlet_code;
-- alter table public.profiles drop column if exists outlet;
-- alter table public.activity_log drop column if exists outlet_code;
-- drop table if exists public.outlets;
-- (The app self-heals against all of these — it just goes back to single-outlet.)
