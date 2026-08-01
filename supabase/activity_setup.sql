-- ============================================================================
-- Velto — Recent Activity log (v121)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- Records every action (order taken, status change, payment, delivery…) with
-- the staff who did it and an accurate timestamp — the team's shared memory.
-- ============================================================================

create table if not exists public.activity_log (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null,            -- order_new | new_customer | status | payment | delivered
  order_number   text,
  customer_name  text,
  actor_name     text,                     -- staff who did it
  detail         text,                     -- e.g. the new status value
  amount         numeric,                  -- for payments
  created_at     timestamptz not null default now()
);
create index if not exists activity_log_created_idx on public.activity_log (created_at desc);

alter table public.activity_log enable row level security;
drop policy if exists activity_log_select on public.activity_log;
create policy activity_log_select on public.activity_log for select to authenticated using (true);
drop policy if exists activity_log_insert on public.activity_log;
create policy activity_log_insert on public.activity_log for insert to authenticated with check (true);

-- ---- Backfill the last 7 days so the feed is populated immediately ----
-- Orders taken
insert into public.activity_log (kind, order_number, customer_name, actor_name, amount, created_at)
select 'order_new', order_number, name_snapshot, 'Staff', total_amount, created_at
from public.orders
where created_at >= now() - interval '7 days' and coalesce(order_status,'') <> 'Cancelled';

-- Payments collected
insert into public.activity_log (kind, order_number, customer_name, actor_name, amount, created_at)
select 'payment', o.order_number, o.name_snapshot, coalesce(nullif(p.received_by,''),'Staff'), p.amount, p.created_at
from public.payments p
left join public.orders o on o.id = p.order_id
where p.created_at >= now() - interval '7 days';

-- Deliveries done (stamp them at noon UTC of the delivery date so they group on the right Dhaka day)
insert into public.activity_log (kind, order_number, customer_name, actor_name, created_at)
select 'delivered', order_number, name_snapshot, coalesce(nullif(rider_assigned,''),'Rider'), (delivery_date::timestamptz + interval '12 hours')
from public.orders
where order_status = 'Delivered' and delivery_date is not null and delivery_date >= (now() - interval '7 days')::date;

-- Done. The app writes new events here automatically from now on.
