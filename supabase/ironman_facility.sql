-- ============================================================================
-- Velto — Ironman facility: data model.
--
-- The central Velto Iron Facility where Oli Ullah irons garments coming back
-- from wash. Managers (Bappy=Sector 11, Monir=RUAP) send orders to him with a
-- priority, a finish-by deadline, and a pinned customer note. He works a
-- prioritised queue and taps "ironing done" → the order flips to a new status
-- 'Ready to Pick from Facility' so the outlet knows it can be collected.
--
-- This migration only adds columns + an index (order_status is free text, so
-- the new status value needs no schema change). Run ONCE in Supabase → SQL
-- Editor. Safe to re-run.
--
-- After Oli logs in once, make him the ironman:
--    update public.profiles set role = 'ironman', name = 'Oli Ullah'
--     where id = '<oli-auth-user-id>';       -- or set role via the Team screen
-- ============================================================================

alter table public.orders add column if not exists iron_priority   text;         -- express | urgent | normal
alter table public.orders add column if not exists iron_finish_by  timestamptz;  -- deadline the ironman should finish by
alter table public.orders add column if not exists iron_note        text;        -- pinned customer instruction for the ironman
alter table public.orders add column if not exists iron_note_by     text;        -- who wrote the note
alter table public.orders add column if not exists iron_note_at     timestamptz; -- when the note was written
alter table public.orders add column if not exists iron_count       int;         -- garments to iron (snapshot at send)
alter table public.orders add column if not exists iron_sent_at     timestamptz; -- when it was sent to the facility
alter table public.orders add column if not exists iron_sent_by     text;        -- which manager sent it
alter table public.orders add column if not exists iron_ready_at    timestamptz; -- when Oli marked it done
alter table public.orders add column if not exists iron_ready_by    text;        -- who marked it done

-- The facility queue is filtered by status + sorted by priority/finish-by.
create index if not exists orders_iron_queue_idx
  on public.orders (order_status, iron_finish_by);

select 'ironman facility data model ready' as status;
