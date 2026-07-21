-- Velto — Express service (+৳100) support.
-- Adds two columns to the orders table so an order can be marked Express and the
-- fee is recorded for the invoice. Safe to run more than once (IF NOT EXISTS).
--
-- Run this in the Supabase SQL editor BEFORE (or right as) you deploy the app
-- update. The app self-heals if these columns are missing (it just won't show
-- express), but running this first makes the feature live immediately.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS express      boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS express_fee  integer DEFAULT 0;
