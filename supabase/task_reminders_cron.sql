-- ============================================================================
-- Velto — Task reminder scheduler (v152)
-- Fires the "⏰ Task due soon" push. Runs every 5 minutes; the notify-push
-- function finds tasks due within the next ~35 min and reminds the assignee.
--
-- PREREQ: deploy the notify-push Edge Function first (see the deploy guide).
-- Run this ONCE in Supabase → SQL Editor. Replace <SERVICE_ROLE_KEY> below with
-- your project's service_role key (Settings → API → service_role). Safe to re-run.
-- ============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Remove any previous copy so re-running is clean.
select cron.unschedule('velto-task-reminders')
where exists (select 1 from cron.job where jobname = 'velto-task-reminders');

-- Every 5 minutes: ask notify-push to send reminders for tasks coming due.
select cron.schedule(
  'velto-task-reminders',
  '*/5 * * * *',
  $$
  select net.http_post(
    url     := 'https://erutxtnepbejdxkoimeo.supabase.co/functions/v1/notify-push',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer <SERVICE_ROLE_KEY>'
               ),
    body    := jsonb_build_object('mode', 'reminders')
  );
  $$
);

-- VERIFY (should list the job)
select jobname, schedule, active from cron.job where jobname = 'velto-task-reminders';
