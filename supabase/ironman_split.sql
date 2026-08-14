-- ============================================================================
-- Velto — Ironman split (Step 1): mixed orders → an independent "iron parcel".
--
-- A mixed order (some Ironing items + some Wash+Iron) can't go to the plant as
-- one batch. So the iron work now runs on its OWN track, beside the order's
-- main status:
--     iron_stage:  (null) → 'sent' (at facility) → 'ready' (ironed) → 'delivered'
-- The manager sends only the iron-ready items (iron_items snapshot); the wash
-- items keep flowing on order_status. One order, one bill — two tracks.
--
-- Run ONCE in Supabase → SQL Editor. Replace <SERVICE_ROLE_KEY>. Safe to re-run.
-- Needs ironman_facility.sql + ironman_ops.sql already applied.
-- ============================================================================

create extension if not exists pg_net;

alter table public.orders add column if not exists iron_stage text;    -- sent | ready | delivered
alter table public.orders add column if not exists iron_items jsonb;   -- [{name,qty,svc}] the parcel that was sent
create index if not exists orders_iron_stage_idx on public.orders (iron_stage, iron_finish_by);

-- Move anything already in flight onto the new track (nothing lost).
update public.orders set iron_stage = 'sent'
 where iron_stage is null and order_status = 'In Velto Facility';
update public.orders set iron_stage = 'ready'
 where iron_stage is null and order_status = 'Ready to Pick from Facility';

-- The "ready → ping the manager" notify now fires on the IRON TRACK, not the
-- whole-order status (so it works for mixed orders too). Replaces the v192 one.
create or replace function public.on_iron_ready()
  returns trigger language plpgsql security definer set search_path = public as $$
declare
  service_key text := '<SERVICE_ROLE_KEY>';   -- <<< EDIT: Settings → API → service_role
  base text := 'https://erutxtnepbejdxkoimeo.supabase.co/functions/v1';
  mgr record; cnt int;
begin
  if NEW.iron_stage = 'ready' and coalesce(OLD.iron_stage,'') <> 'ready' then
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
create trigger trg_iron_ready after update of iron_stage on public.orders
  for each row execute function public.on_iron_ready();

select 'ironman split (iron parcel track) ready' as status;
