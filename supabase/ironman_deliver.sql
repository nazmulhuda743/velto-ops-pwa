-- ============================================================================
-- Velto — Ironman split (Step 2): deliver the iron parcel independently.
--
-- When Oli marks the iron parcel ready (iron_stage='ready'), the manager can
-- hand those items to the customer straight away — iron_stage → 'delivered' —
-- while the wash items keep processing. The order closes normally when the
-- rest is out.
--
-- Just two columns. Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================

alter table public.orders add column if not exists iron_delivered_at timestamptz;
alter table public.orders add column if not exists iron_delivered_by text;

select 'ironman deliver (iron parcel delivery) ready' as status;
