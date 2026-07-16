// Velto AI Copilot — drafts a genuinely personal WhatsApp retention message.
//
// The reorder engine in the PWA decides WHO to contact and WHY (stage, cadence,
// churn risk). This function decides WHAT to say, in Nazmul's voice, using the
// customer's real context. The app always has a template fallback, so this
// function may safely return an error and nothing breaks.
//
// Deploy:   supabase functions deploy ai-copilot
// Secret:   supabase secrets set OPENAI_API_KEY=sk-...
// Optional: supabase secrets set OPENAI_MODEL=gpt-4o-mini   (default)
//
// Called from index.html via:  sb.functions.invoke('ai-copilot', { body: {...} })

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// What each lifecycle stage is trying to achieve — keeps the model on-goal.
const STAGE_INTENT: Record<string, string> = {
  thank: "Thank them warmly for a recent order and gently invite honest feedback. Do NOT sell anything.",
  nudge: "It's about a week since delivery, so their laundry is piling up again. Warmly offer to book the next pickup. Low pressure.",
  standing: "Offer to set up a standing weekly pickup on a fixed day so their laundry simply takes care of itself.",
  overdue: "They've drifted past their usual ordering rhythm. Reconnect personally and make coming back effortless.",
  winback: "They've been dormant for a long time. Win them back sincerely — acknowledge the gap, take responsibility, invite one more try. No gimmicks, no heavy discounting.",
  loyal: "Celebrate a loyalty milestone. Pure founder-to-customer gratitude. No discount and no ask.",
  scheduled: "You promised to follow up today. Honour it warmly and pick up where the last conversation left off.",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const key = Deno.env.get("OPENAI_API_KEY");
    if (!key) return json({ error: "OPENAI_API_KEY not set" }, 400);

    const b = await req.json().catch(() => ({} as Record<string, unknown>));
    const first = String(b.name ?? "").trim().split(/\s+/)[0] || "there";
    const stage = String(b.stage ?? "nudge");
    const intent = STAGE_INTENT[stage] ?? STAGE_INTENT.nudge;
    const lang = String(b.lang ?? "auto");
    const langRule =
      lang === "bn"
        ? "Write in natural, warm Bangla. Everyday English words that Dhaka customers actually use (pickup, delivery, order) are fine."
        : lang === "en"
        ? "Write in warm, natural English."
        : "Use the tone a Dhaka customer would appreciate — mostly natural English, warm and local; a Bangla word or two is fine only if it feels genuinely natural.";

    // Only surface facts that exist — never force the model to invent context.
    const facts: string[] = [];
    if (num(b.orderCount)) facts.push(`${num(b.orderCount)} orders so far`);
    if (num(b.ltv)) facts.push(`lifetime spend about ৳${num(b.ltv)}`);
    if (num(b.lastValue)) facts.push(`last order about ৳${num(b.lastValue)}`);
    if (b.daysSince != null && b.daysSince !== "") facts.push(`${num(b.daysSince)} days since their last delivery`);
    if (num(b.cadence)) facts.push(`normally orders roughly every ${num(b.cadence)} days`);
    if (Array.isArray(b.services) && b.services.length) facts.push(`recent services: ${(b.services as string[]).slice(0, 4).join(", ")}`);
    if (b.zone) facts.push(`area: ${String(b.zone)}`);
    if (b.lastNote) facts.push(`note from the last conversation: "${String(b.lastNote).slice(0, 160)}"`);
    if (b.vip) facts.push("this is a high-value / VIP customer");
    if (b.riskPct != null) facts.push(`internal churn-risk estimate about ${num(b.riskPct)}%`);

    const sys = [
      "You are Nazmul, the founder of Velto — a premium laundry and dry-cleaning service in Uttara, Dhaka, Bangladesh.",
      "You personally write short WhatsApp messages to customers. You sound like a real person who genuinely cares — never like a marketing bot.",
      "Hard rules:",
      "- 2 to 4 short sentences. Warm, respectful, confident. It must feel handwritten.",
      "- At most ONE emoji, and only if it feels natural. Usually none.",
      "- NEVER invent facts, prices, offers, or discounts. Do not promise money off unless explicitly told to.",
      "- You may lean on the customer's real context, but naturally — do not recite statistics back at them.",
      "- Always end with an easy, low-pressure way for them to reply or book.",
      "- No subject line, no greeting header, no signature block beyond a natural sign-off. Return only the message body.",
      langRule,
    ].join("\n");

    const user = [
      `Customer's first name: ${first}`,
      `Goal of this message: ${intent}`,
      facts.length ? `Context you may draw on lightly: ${facts.join("; ")}.` : "",
      b.variety ? "Give a fresh alternative phrasing that feels clearly different from a standard template." : "",
      "Return ONLY the ready-to-send message text.",
    ].filter(Boolean).join("\n");

    const model = Deno.env.get("OPENAI_MODEL") || "gpt-4o-mini";
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        temperature: b.variety ? 0.9 : 0.7,
        max_tokens: 240,
        messages: [
          { role: "system", content: sys },
          { role: "user", content: user },
        ],
      }),
    });
    if (!r.ok) {
      const t = await r.text();
      return json({ error: `openai ${r.status}`, detail: t.slice(0, 300) }, 502);
    }
    const d = await r.json();
    const message = String(d?.choices?.[0]?.message?.content ?? "").trim();
    if (!message) return json({ error: "empty completion" }, 502);
    return json({ message, sendWindow: sendWindow(stage), model });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

// Best WhatsApp read windows in Dhaka — late morning and early evening.
function sendWindow(stage: string): string {
  if (stage === "thank") return "within 24h of delivery";
  if (stage === "winback" || stage === "overdue") return "11:00–13:00 or 19:00–21:00 (Dhaka)";
  return "11:00–12:30 or 19:30–21:00 (Dhaka)";
}
function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}
function json(o: unknown, status = 200): Response {
  return new Response(JSON.stringify(o), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
