// Velto AI Copilot — two jobs in one function:
//
//   mode: "message" (default) → drafts a personal WhatsApp message to send now.
//   mode: "plan"              → after a CSR logs what a customer said, decides the
//                               NEXT move: channel, timing, angle, and a ready message.
//
// The reorder engine in the PWA decides WHO to contact and WHY (stage, cadence,
// churn risk, new-customer status). This function decides WHAT to say and, in
// plan mode, WHEN and HOW to follow up next. The app always has a rule-based
// fallback, so this function may safely return an error and nothing breaks.
//
// Deploy:   supabase functions deploy ai-copilot
// Secret:   supabase secrets set OPENAI_API_KEY=sk-...
// Optional: supabase secrets set OPENAI_MODEL=gpt-4o-mini   (default)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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
    const mode = String(b.mode ?? "message");
    const model = Deno.env.get("OPENAI_MODEL") || "gpt-4o-mini";

    // --- brief mode: a sharp, prioritized morning brief for the founder ---
    if (mode === "brief") {
      const s = (b.stats ?? {}) as Record<string, unknown>;
      const owner = String(b.name ?? "Nazmul").trim().split(/\s+/)[0] || "Nazmul";
      const facts: string[] = [];
      if (num(s.deliverToday)) facts.push(`${num(s.deliverToday)} orders to deliver today`);
      if (num(s.overdue)) facts.push(`${num(s.overdue)} deliveries already running late`);
      if (num(s.collectN)) facts.push(`৳${num(s.collectAmt).toLocaleString()} uncollected across ${num(s.collectN)} orders`);
      if (num(s.atRisk)) facts.push(`${num(s.atRisk)} repeat customers slipping away${num(s.atRiskAmt) ? ` (about ৳${num(s.atRiskAmt).toLocaleString()} of repeat revenue at risk)` : ""}`);
      if (num(s.dueSoon)) facts.push(`${num(s.dueSoon)} regulars predicted to reorder soon`);
      if (num(s.advisory)) facts.push(`${num(s.advisory)} orders awaiting the customer's wash-approval`);
      if (s.monthRevenue != null && s.monthTarget) facts.push(`month revenue ৳${num(s.monthRevenue).toLocaleString()} against a ৳${num(s.monthTarget).toLocaleString()} target`);
      if (!facts.length) facts.push("nothing urgent is outstanding");
      const sys = [
        "You are the operations chief of Velto, a premium laundry & dry-cleaner in Uttara, Dhaka.",
        `Write a crisp morning brief to the founder, ${owner}. 2 to 3 sentences, plain and direct, like a sharp right-hand who already did the thinking.`,
        "Lead with the single most important thing to do FIRST. Velto's revenue is the repeat base — protecting slipping regulars and catching predicted reorders matters as much as today's deliveries.",
        "Be specific with the numbers given. Never invent facts. No greeting fluff beyond the first word, no emoji, no bullet points — flowing sentences only.",
        "Return ONLY JSON: {\"brief\":\"...\"}",
      ].join("\n");
      const user = `Today's numbers: ${facts.join("; ")}.`;
      const d = await chat(key, model, sys, user, 0.6, 200, true);
      if (d.error) return json({ brief: "" }, 200);
      const parsed = safeJson(d.text);
      return json({ brief: parsed && parsed.brief ? String(parsed.brief).slice(0, 600) : "" });
    }

    // --- vision mode: inspect garment photos and flag wash/dry-clean/iron risk ---
    if (mode === "vision") {
      const vmodel = Deno.env.get("OPENAI_VISION_MODEL") || "gpt-4o-mini";
      const images = Array.isArray(b.images)
        ? (b.images as string[]).filter((u) => typeof u === "string" && u.length > 10).slice(0, 5)
        : [];
      if (!images.length) return json({ error: "no images" }, 400);
      const TYPES = [
        "Colour may bleed / run",
        "Dark or red / indigo — loose dye",
        "Dust or dirt on collar / cuffs (sets if ironed)",
        "Delicate — beads / sequins / zari work",
        "Dry-clean only — no water wash",
        "Shrinkage risk",
        "Pre-existing damage may worsen",
        "Embroidery / print may lift",
        "Other — see note",
      ];
      const vsys = [
        "You are a senior garment-care inspector for Velto, a premium laundry and dry-cleaner in Uttara, Dhaka.",
        "You are shown photos of the garments a customer just dropped off. Flag ONLY genuine risks a shop must confirm BEFORE washing, dry-cleaning, or ironing.",
        "A photo cannot prove colour-fastness — so you flag SUSPICION, never certainty. Recommend a quick test where it applies.",
        "Look for: deep / saturated or red / maroon / indigo dyes likely to bleed; silk, saree or clearly delicate fabric; beads, sequins, zari or heavy embroidery that can snag or lift; visible dust or dirt on collar / cuffs that will set permanently if ironed; obvious pre-existing damage (tears, holes, weak seams); leather or suede trims; items that read as dry-clean-only.",
        "Be conservative and honest. A plain white or light cotton shirt, a normal t-shirt, ordinary trousers with nothing visible = NO risk. Never invent a risk to seem useful.",
        `risk_type MUST be exactly one of: ${TYPES.map((t) => `"${t}"`).join(", ")}.`,
        "The photos are given in order, indexed from 0. For each risk, set imageIndex to the 0-based photo it is seen in.",
        'Return ONLY compact JSON: {"risks":[{"garment":"short human name e.g. Red silk saree","risk_type":"<one exact value from the list>","confidence":"high|medium|low","reason":"<=14 words describing what you see","imageIndex":<int>}]}',
        'If nothing is genuinely risky, return {"risks":[]}.',
      ].join("\n");
      const userContent: Array<Record<string, unknown>> = [
        { type: "text", text: "Inspect these garment photos and flag only genuine wash / dry-clean / iron risks." },
      ];
      images.forEach((u) => userContent.push({ type: "image_url", image_url: { url: u } }));
      const r = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          model: vmodel, temperature: 0.2, max_tokens: 800,
          response_format: { type: "json_object" },
          messages: [{ role: "system", content: vsys }, { role: "user", content: userContent }],
        }),
      });
      if (!r.ok) { const t = await r.text(); return json({ error: `openai ${r.status}`, detail: t.slice(0, 300) }, 502); }
      const d = await r.json();
      const parsed = safeJson(String(d?.choices?.[0]?.message?.content ?? ""));
      const rawRisks = parsed && Array.isArray(parsed.risks) ? parsed.risks : [];
      const norm = (t: string) => {
        const s = String(t || "");
        return TYPES.find((x) => x.toLowerCase() === s.toLowerCase()) || TYPES.find((x) => s && x.toLowerCase().includes(s.toLowerCase().slice(0, 8))) || "Other — see note";
      };
      const risks = rawRisks.slice(0, 12).map((x: Record<string, unknown>) => ({
        garment: String(x.garment ?? "Garment").slice(0, 70),
        risk_type: norm(String(x.risk_type ?? "")),
        confidence: ["high", "medium", "low"].includes(String(x.confidence)) ? String(x.confidence) : "medium",
        reason: String(x.reason ?? "").slice(0, 160),
        imageIndex: Number.isFinite(Number(x.imageIndex)) ? Math.max(0, Math.min(images.length - 1, Math.round(Number(x.imageIndex)))) : 0,
      }));
      return json({ risks, model: vmodel });
    }

    const first = String(b.name ?? "").trim().split(/\s+/)[0] || "there";
    const stage = String(b.stage ?? "nudge");
    const lang = String(b.lang ?? "auto");
    const langRule =
      lang === "bn"
        ? "Write in natural, warm Bangla. Everyday English words Dhaka customers use (pickup, delivery, order) are fine."
        : lang === "en"
        ? "Write in warm, natural English."
        : "Use the tone a Dhaka customer would appreciate — mostly natural English, warm and local; a Bangla word or two is fine only if it feels genuinely natural.";

    // Shared context both modes draw on — only real facts, never invented.
    const facts: string[] = [];
    if (b.isNew) facts.push("FIRST-TIME customer who has not reordered yet — their 2nd order is critical; be extra warm and careful, never pushy");
    if (num(b.orderCount)) facts.push(`${num(b.orderCount)} orders so far`);
    if (num(b.ltv)) facts.push(`lifetime spend about ৳${num(b.ltv)}`);
    if (num(b.lastValue)) facts.push(`last order about ৳${num(b.lastValue)}`);
    if (b.daysSince != null && b.daysSince !== "") facts.push(`${num(b.daysSince)} days since their last delivery`);
    if (num(b.cadence)) facts.push(`normally orders roughly every ${num(b.cadence)} days`);
    if (Array.isArray(b.services) && b.services.length) facts.push(`recent services: ${(b.services as string[]).slice(0, 4).join(", ")}`);
    if (b.zone) facts.push(`area: ${String(b.zone)}`);
    if (b.vip) facts.push("high-value / VIP customer");
    if (b.riskPct != null) facts.push(`internal churn-risk estimate about ${num(b.riskPct)}%`);

    // Full follow-up history — this is what makes each message and plan specific.
    const hist = Array.isArray(b.history) ? (b.history as Array<Record<string, unknown>>).slice(0, 6) : [];
    const histLines = hist
      .map((h) => {
        const o = String(h.outcome ?? "").trim();
        const n = String(h.note ?? "").trim();
        const d = num(h.daysAgo);
        if (!o && !n) return "";
        return `- ${d}d ago: ${o}${n ? ` — "${n}"` : ""}`;
      })
      .filter(Boolean);

    // Escalation ladder — the whole point of logging every follow-up is that the
    // NEXT message must be smarter and more personal than the last. Sending the
    // same generic nudge 2–3 times is worthless; customers tune it out.
    const attempt = Math.max(1, num(b.attempt) || histLines.length + 1);
    const services = Array.isArray(b.services) ? (b.services as string[]).filter(Boolean) : [];
    const garment = services.slice(0, 3).join(", ");
    const g = garment ? ` (their ${garment})` : "";
    const escalation =
      attempt <= 1
        ? "This is the FIRST follow-up. Keep it light and friendly — a simple, warm check-in."
        : attempt === 2
        ? `This is the SECOND follow-up — the first didn't land. Do NOT repeat it. Make it noticeably more personal: reference what they actually bring us${g}, give one concrete, specific reason this is a good moment to book again, and open in a completely different way.`
        : attempt === 3
        ? `This is the THIRD follow-up — two haven't worked. Drop the standard nudge entirely. Write as Nazmul personally, one-to-one: gently acknowledge you've reached out before, be genuine and human, tie it to their specific garments/routine${g}, and make them feel individually noticed — not part of a list.`
        : `This is follow-up #${attempt} — several haven't worked. Be warm and low-pressure, acknowledge you don't want to keep bothering them, give them an easy out, and make one last genuinely personal invitation tied to their history${g}. Absolutely no generic template language.`;
    const antiRepeat =
      "CRITICAL: every follow-up to the same person must be clearly DIFFERENT from the previous ones — new opening line, new angle, and more personal/garment-specific each time. Reusing the same style of message is the fastest way to be ignored, and it loses orders.";

    if (mode === "plan") {
      const sys = [
        "You are the retention strategist for Velto, a premium laundry service in Uttara, Dhaka.",
        "A staff member just logged what a customer said after a follow-up. Decide the single best NEXT move.",
        "Think like a caring shop owner, not a call centre. Rules of judgement:",
        "- If they complained or sound unhappy → next channel is a Call, soon, to make it right before any selling.",
        "- If they already said no / not interested → back off: longer wait, gentle channel, no pressure.",
        "- If they replied positively / booked → light touch, thank/confirm, don't over-contact.",
        "- If two or more texts went unanswered → switch to a Call.",
        "- First-time customers who haven't reordered are the top priority — protect that relationship, keep it warm and personal.",
        "Return ONLY compact JSON, no prose, matching:",
        '{"nextChannel":"Call|WhatsApp|Wait","nextInDays":<int 1-60>,"angle":"<=6 word label","reasoning":"one short sentence for the staff","message":"the ready-to-send message for that next touch"}',
        "The message must obey: 2-4 short sentences, at most one emoji, no invented prices/discounts, warm and handwritten, easy reply at the end.",
        langRule,
      ].join("\n");
      const user = [
        `Customer first name: ${first}`,
        `Current lifecycle stage: ${stage}`,
        b.lastOutcome ? `What the staff just logged: "${String(b.lastOutcome).slice(0, 200)}"` : "",
        facts.length ? `Context: ${facts.join("; ")}.` : "",
        histLines.length ? `Recent follow-up history:\n${histLines.join("\n")}` : "",
        escalation,
        antiRepeat,
      ].filter(Boolean).join("\n");

      const d = await chat(key, model, sys, user, 0.8, 340, true);
      if (d.error) return json(d, d.status || 502);
      const parsed = safeJson(d.text);
      if (!parsed || !parsed.nextChannel) return json({ error: "bad plan json", raw: (d.text || "").slice(0, 200) }, 502);
      return json({
        nextChannel: String(parsed.nextChannel).slice(0, 20),
        nextInDays: clampInt(parsed.nextInDays, 1, 60, 3),
        angle: String(parsed.angle ?? "").slice(0, 60),
        reasoning: String(parsed.reasoning ?? "").slice(0, 240),
        message: String(parsed.message ?? "").slice(0, 900),
        model,
      });
    }

    // --- message mode (default) ---
    const intent = STAGE_INTENT[stage] ?? STAGE_INTENT.nudge;
    const sys = [
      "You are Nazmul, the founder of Velto — a premium laundry and dry-cleaning service in Uttara, Dhaka, Bangladesh.",
      "You personally write short WhatsApp messages to customers. You sound like a real person who genuinely cares — never like a marketing bot.",
      "Hard rules:",
      "- 2 to 4 short sentences. Warm, respectful, confident. It must feel handwritten.",
      "- At most ONE emoji, and only if it feels natural. Usually none.",
      "- NEVER invent facts, prices, offers, or discounts. Do not promise money off unless explicitly told to.",
      "- Draw on the customer's real context and history, but naturally — do not recite statistics back at them.",
      "- Always end with an easy, low-pressure way for them to reply or book.",
      "- Return only the message body: no subject, no header, no signature block beyond a natural sign-off.",
      langRule,
    ].join("\n");
    const user = [
      `Customer's first name: ${first}`,
      `Goal of this message: ${intent}`,
      facts.length ? `Context you may draw on lightly: ${facts.join("; ")}.` : "",
      histLines.length ? `What's happened with them recently (use to make it specific, don't recite):\n${histLines.join("\n")}` : "",
      escalation,
      antiRepeat,
      b.variety ? "Give a fresh alternative phrasing that feels clearly different from anything sent before." : "",
      "Return ONLY the ready-to-send message text.",
    ].filter(Boolean).join("\n");

    const d = await chat(key, model, sys, user, b.variety ? 1.0 : 0.85, 260, false);
    if (d.error) return json(d, d.status || 502);
    const message = (d.text || "").trim();
    if (!message) return json({ error: "empty completion" }, 502);
    return json({ message, sendWindow: sendWindow(stage), model });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

async function chat(key: string, model: string, sys: string, user: string, temperature: number, max_tokens: number, jsonMode: boolean) {
  const body: Record<string, unknown> = {
    model, temperature, max_tokens,
    messages: [{ role: "system", content: sys }, { role: "user", content: user }],
  };
  if (jsonMode) body.response_format = { type: "json_object" };
  const r = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    const t = await r.text();
    return { error: `openai ${r.status}`, detail: t.slice(0, 300), status: 502 as number };
  }
  const d = await r.json();
  return { text: String(d?.choices?.[0]?.message?.content ?? "") };
}

function safeJson(s: string): Record<string, unknown> | null {
  try { return JSON.parse(s); } catch { /* try to find a JSON object */ }
  const m = s.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch { return null; } }
  return null;
}
function sendWindow(stage: string): string {
  if (stage === "thank") return "within 24h of delivery";
  if (stage === "winback" || stage === "overdue") return "11:00–13:00 or 19:00–21:00 (Dhaka)";
  return "11:00–12:30 or 19:30–21:00 (Dhaka)";
}
function num(v: unknown): number { const n = Number(v); return Number.isFinite(n) ? n : 0; }
function clampInt(v: unknown, lo: number, hi: number, dflt: number): number {
  const n = Math.round(Number(v));
  if (!Number.isFinite(n)) return dflt;
  return Math.max(lo, Math.min(hi, n));
}
function json(o: unknown, status = 200): Response {
  return new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
