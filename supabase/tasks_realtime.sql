-- ============================================================================
-- Velto — enable realtime on tasks (v153)
-- Lets the app play the live buzz + chime the instant a task is assigned while
-- the app is open. Run ONCE in Supabase → SQL Editor. Safe to re-run.
-- ============================================================================
alter publication supabase_realtime add table public.tasks;

-- VERIFY (tasks should appear in the list)
select tablename from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'tasks';
