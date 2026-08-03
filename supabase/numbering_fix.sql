-- ============================================================================
-- Velto — Per-outlet order numbering, NO GAPS (v133)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
--
-- Every outlet now follows its OWN dense sequence:
--   Sector 11:  VEL-01601 → VEL-01602 → VEL-01603 …  (no more skipped numbers)
--   RUAP:       VELR-00001 → VELR-00002 …
--
-- How: the app claims a number for EVERY order right after creation, and the
-- claim function always issues (highest existing number for that prefix) + 1,
-- atomically under a row lock. It self-heals: whatever the legacy generator
-- mints internally is simply renamed away and never seen again. Even the
-- already-skipped VEL-01602 gets reused by the next Sector 11 order.
-- ============================================================================

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
begin
  select prefix into v_prefix from public.outlets where code = p_outlet and active;
  if v_prefix is null then
    return null;                      -- unknown/inactive outlet → caller keeps the legacy number
  end if;

  -- Next number = max(stored counter, live max for this prefix + 1).
  -- The anchored regex means VELR- rows can never leak into the VEL- scan.
  -- The UPDATE takes a row lock on the outlet, so two simultaneous orders
  -- can never draw the same number.
  update public.outlets
     set next_no = greatest(
           next_no,
           coalesce((select max((regexp_match(order_number, '^' || v_prefix || '-(\d+)$'))[1]::int)
                       from public.orders
                      where order_number like v_prefix || '-%'), 0) + 1
         ) + 1
   where code = p_outlet
  returning next_no - 1 into v_no;

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

-- VERIFY: next numbers each outlet would issue right now
select o.code, o.prefix,
       coalesce((select max((regexp_match(order_number, '^' || o.prefix || '-(\d+)$'))[1]::int)
                   from public.orders where order_number like o.prefix || '-%'), 0) + 1 as next_number
from public.outlets o order by o.code;
