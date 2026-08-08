// ============================================================================
// Velto — notify-push  (v152)
// Sends Web Push for the Tasks feature. Two modes:
//   1) Assign:    POST {target_user, title, body, url}   → the app calls this
//                 the moment a task is assigned.
//   2) Reminders: POST {mode:"reminders"}                → pg_cron calls this
//                 every few minutes; it finds tasks due in the next ~35 min
//                 that haven't been reminded yet and pushes "due soon".
//
// Reuses the SAME push_subscriptions table and VAPID keys as your order
// notifications. Set these Function secrets (same values you already use for
// the order push): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.
// ============================================================================
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const VAPID_PUBLIC  = Deno.env.get("VAPID_PUBLIC_KEY")  ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT")     ?? "mailto:ops@velto.app";
webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

const supa = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function subsFor(targetUser: string | null) {
  // Prefer devices belonging to the assignee; fall back to the whole team if
  // the push_subscriptions table has no user_id column (or none matched).
  if (targetUser) {
    const r = await supa.from("push_subscriptions").select("endpoint,p256dh,auth").eq("user_id", targetUser);
    if (!r.error && r.data && r.data.length) return r.data;
  }
  const all = await supa.from("push_subscriptions").select("endpoint,p256dh,auth");
  return all.data ?? [];
}

async function push(sub: any, payload: string) {
  await webpush.sendNotification(
    { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
    payload,
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }

  const messages: Array<{ target: string | null; title: string; body: string; url: string }> = [];

  if (body.mode === "reminders") {
    const now = Date.now();
    const soon = new Date(now + 35 * 60 * 1000).toISOString();       // due within 35 min
    const floor = new Date(now - 10 * 60 * 1000).toISOString();      // not already long overdue
    const { data: due } = await supa
      .from("tasks").select("*")
      .eq("status", "open").eq("reminded", false)
      .not("due_at", "is", null)
      .gte("due_at", floor).lte("due_at", soon);
    for (const t of due ?? []) {
      messages.push({
        target: t.assigned_to ?? null,
        title: "⏰ Task due soon",
        body: `${t.title}${t.assigned_to_name ? " · " + t.assigned_to_name : ""}`,
        url: "./",
      });
      await supa.from("tasks").update({ reminded: true }).eq("id", t.id);
    }
  } else {
    messages.push({
      target: body.target_user ?? null,
      title: body.title ?? "🗒️ New task",
      body: body.body ?? "",
      url: body.url ?? "./",
    });
  }

  let sent = 0, failed = 0;
  for (const m of messages) {
    const subs = await subsFor(m.target);
    const payload = JSON.stringify({ title: m.title, body: m.body, url: m.url, tag: "velto-task" });
    for (const s of subs) {
      try { await push(s, payload); sent++; }
      catch { failed++; }
    }
  }

  return new Response(JSON.stringify({ ok: true, messages: messages.length, sent, failed }), {
    headers: { ...CORS, "Content-Type": "application/json" },
  });
});
