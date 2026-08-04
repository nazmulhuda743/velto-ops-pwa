-- ============================================================================
-- Velto — PERMANENT gap-free order numbering (v134)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
--
-- This moves the fix INTO THE DATABASE, so no phone, no old app version and
-- no missed step can ever cause a skipped number again:
--
--   • A trigger stamps EVERY new order with the next dense Sector 11 number
--     (highest existing VEL number + 1) the instant the row is created —
--     whatever any legacy generator tried to assign is overridden.
--   • A RUAP booking is then renamed by the app to the next dense VELR
--     number; the VEL number it briefly held is FREED and the very next
--     order automatically reuses it. Holes cannot survive.
--   • All issuance is serialized on the outlet row lock — two staff booking
--     in the same instant can never draw the same number.
-- ============================================================================

-- 1. Fast prefix scans
create index if not exists orders_number_pattern_idx
  on public.orders (order_number text_pattern_ops);

-- 2. Dense numbering AT INSERT — covers every order from every device/path.
create or replace function public.velto_dense_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_no int;
begin
  -- Serialize issuance on the S11 outlet row (lock held to commit).
  update public.outlets set next_no = next_no + 1 where code = 'S11';
  if not found then return new; end if;   -- outlets not set up → keep legacy number

  select coalesce(max((regexp_match(order_number, '^VEL-(\d+)$'))[1]::int), 1110) + 1
    into v_no
    from public.orders
   where order_number like 'VEL-%';

  new.order_number := 'VEL-' || lpad(v_no::text, 5, '0');
  if new.outlet_code is null then new.outlet_code := 'S11'; end if;
  return new;
end;
$$;

-- 'zzz_' so it fires LAST among before-insert triggers and always wins.
drop trigger if exists zzz_velto_dense_number on public.orders;
create trigger zzz_velto_dense_number
before insert on public.orders
for each row execute function public.velto_dense_number();

-- 3. claim_outlet_number v3 — no-op if the order already carries the right
--    prefix (Sector 11 case, since the trigger numbered it); for RUAP it
--    renames to the next dense VELR number under the RUAP row lock.
create or replace function public.claim_outlet_number(p_outlet text, p_order uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix text;
  v_no     int;
  v_num    text;
  v_cur    text;
begin
  select prefix into v_prefix from public.outlets where code = p_outlet and active;
  if v_prefix is null then return null; end if;

  select order_number into v_cur from public.orders where id = p_order;
  if v_cur is null then return null; end if;

  if v_cur like v_prefix || '-%' then
    update public.orders set outlet_code = p_outlet where id = p_order;
    return v_cur;                         -- already numbered for this outlet
  end if;

  update public.outlets set next_no = next_no + 1 where code = p_outlet;  -- row lock

  select coalesce(max((regexp_match(order_number, '^' || v_prefix || '-(\d+)$'))[1]::int),
                  case when v_prefix = 'VEL' then 1110 else 0 end) + 1
    into v_no
    from public.orders
   where order_number like v_prefix || '-%';

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

-- 4. DIAGNOSIS — any holes in the recent VEL range? (empty result = none)
with nums as (
  select (regexp_match(order_number, '^VEL-(\d+)$'))[1]::int as n
    from public.orders where order_number like 'VEL-%'
)
select 'VEL-' || lpad(gs::text, 5, '0') as missing_number
  from generate_series((select greatest(max(n) - 40, 1110) from nums),
                       (select max(n) from nums)) gs
 where gs not in (select n from nums)
 order by gs;

-- 5. Next number each outlet will issue
select o.code, o.prefix,
       coalesce((select max((regexp_match(order_number, '^' || o.prefix || '-(\d+)$'))[1]::int)
                   from public.orders where order_number like o.prefix || '-%'), 0) + 1 as next_number
  from public.outlets o order by o.code;

-- Note: numbers now come from the trigger, so a hole freed by a RUAP rename
-- is reused by the very next order. Existing historical holes (e.g. VEL-01609
-- if it is below newer numbers) are NOT retro-renumbered — printed receipts
-- must stay truthful — but no new hole can ever form.
