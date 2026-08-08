-- ============================================================================
-- Velto — allow admins & managers to DELETE an expense (v149)
-- Run ONCE in Supabase: Dashboard → SQL Editor → paste → Run. Safe to re-run.
-- Without this, the Finance page delete button is blocked by row-level security.
-- ============================================================================

drop policy if exists expenses_delete on public.expenses;
create policy expenses_delete on public.expenses
  for delete to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('admin','manager')
    )
  );

-- VERIFY
select 'expenses_delete policy ready' as status;
