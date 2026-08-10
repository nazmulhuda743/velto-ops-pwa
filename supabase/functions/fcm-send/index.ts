// ============================================================================
// Velto — fcm-send (Phase 2)
// Sends a native FCM push (buzzes a locked Android phone) to every device
// registered by a given user in the device_tokens table.
//
// Request (POST):
//   { "user_id": "<uuid>", "title": "...", "body": "...", "url": "./", "tag": "task" }
//
// Env (set with:  supabase secrets set FCM_SERVICE_ACCOUNT="$(cat sa.json)" ):
//   FCM_SERVICE_ACCOUNT   the Firebase service-account JSON (one line or raw)
//   SUPABASE_URL          (auto in edge runtime)
//   SUPABASE_SERVICE_ROLE_KEY (auto in edge runtime)
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// --- base64url helpers -------------------------------------------------------
function b64url(bytes: Uint8Array): string {
  let s = btoa(String.fromCharCode(...bytes));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function strToB64url(s: string): string {
  return b64url(new TextEncoder().encode(s));
}
function pemToDer(pem: string): Uint8Array {
  const b64 = pem.replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

// --- get a Google OAuth access token from the service account ----------------
async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${strToB64url(JSON.stringify(header))}.${strToB64url(JSON.stringify(claim))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)),
  );
  const jwt = `${unsigned}.${b64url(sig)}`;

  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const data = await resp.json();
  if (!resp.ok) throw new Error("oauth: " + JSON.stringify(data));
  return data.access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let payload: any;
  try { payload = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  const { user_id, title, body, url, tag } = payload || {};
  if (!user_id || !title) return json({ error: "user_id and title required" }, 400);

  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!saRaw) return json({ error: "FCM_SERVICE_ACCOUNT not set" }, 500);
  let sa: any;
  try { sa = JSON.parse(saRaw); } catch { return json({ error: "FCM_SERVICE_ACCOUNT is not valid JSON" }, 500); }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: rows, error } = await supabase
    .from("device_tokens")
    .select("token")
    .eq("user_id", user_id);
  if (error) return json({ error: "db: " + error.message }, 500);
  const tokens = (rows || []).map((r: any) => r.token).filter(Boolean);
  if (tokens.length === 0) return json({ sent: 0, note: "no devices for this user" });

  let accessToken: string;
  try { accessToken = await getAccessToken(sa); }
  catch (e) { return json({ error: String(e) }, 500); }

  const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  let sent = 0;
  const dead: string[] = [];

  for (const token of tokens) {
    const message = {
      message: {
        token,
        notification: { title, body: body || "" },
        android: {
          priority: "HIGH",
          notification: {
            channel_id: "velto_tasks_v3",    // native channel with the long buzz pattern
            notification_priority: "PRIORITY_MAX",
          },
        },
        data: { url: url || "./", tag: tag || "task" },
      },
    };
    const r = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(message),
    });
    if (r.ok) {
      sent++;
    } else {
      const err = await r.text();
      // Prune tokens FCM says are gone so the table stays clean.
      if (r.status === 404 || r.status === 400 || /UNREGISTERED|INVALID_ARGUMENT/.test(err)) {
        dead.push(token);
      }
    }
  }

  if (dead.length) {
    try { await supabase.from("device_tokens").delete().in("token", dead); } catch (_) {}
  }
  return json({ sent, devices: tokens.length, pruned: dead.length });
});
