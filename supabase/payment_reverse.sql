-- ============================================================================
-- Velto — Reverse a mistaken payment (v135)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- Removes one payment row and recomputes the order's paid amount from the
-- remaining payments — the money goes back to DUE. Every reversal is written
-- to the team activity feed by the app (who did it, when, how much).
-- ============================================================================

create or replace function public.reverse_payment(p_payment uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order uuid;
  v_amt   numeric;
begin
  select order_id, amount into v_order, v_amt
    from public.payments where id = p_payment;
  if v_order is null then
    return null;                       -- already reversed / unknown id
  end if;

  delete from public.payments where id = p_payment;

  -- Recompute from the source of truth (works whether or not any trigger
  -- also maintains amount_paid — the sum is the sum).
  update public.orders
     set amount_paid = coalesce((select sum(amount) from public.payments
                                  where order_id = v_order), 0)
   where id = v_order;

  return v_amt;
end;
$$;

revoke all on function public.reverse_payment(uuid) from public;
grant execute on function public.reverse_payment(uuid) to authenticated;

-- VERIFY
select 'reverse_payment installed' as status;
