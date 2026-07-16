# AI Copilot — deploy in 3 steps

This edge function drafts a personal WhatsApp retention message for a customer.
The PWA calls it from the reorder page (the **✨ AI** button on every follow-up
card). If the function is missing or errors, the app silently falls back to the
built-in templates — nothing breaks — so you can ship the frontend first and
turn the AI on whenever you're ready.

## 1. Set the OpenAI key (one time)

```bash
supabase secrets set OPENAI_API_KEY=sk-your-key
# optional — defaults to gpt-4o-mini (cheap + good enough)
supabase secrets set OPENAI_MODEL=gpt-4o-mini
```

## 2. Deploy

```bash
supabase functions deploy ai-copilot
```

`verify_jwt` stays ON (the default). The app is logged in, so `sb.functions.invoke`
sends the user's token automatically and the call is authorized. No config change
needed.

## 3. Test

Open the reorder page → tap **✨ AI** on any customer → a draft appears in an
editable sheet. Edit if you like, tap **Send on WhatsApp**. **↻ Redraft** asks
for a fresh alternative.

## Request body (sent by the app)

```jsonc
{
  "name": "Rahim Uddin",
  "stage": "nudge",          // thank | nudge | standing | overdue | winback | loyal | scheduled
  "lang": "auto",            // auto | en | bn
  "vip": false,
  "orderCount": 4,
  "lastValue": 1200,
  "ltv": 5400,
  "daysSince": 9,
  "cadence": 8,              // their personal ordering rhythm, in days
  "zone": "Sector 4",
  "services": ["Wash & Iron", "Dry Clean"],
  "lastNote": "wanted pickup Friday",
  "riskPct": 62,             // churn-risk estimate from roRisk()
  "variety": 0               // 1 = give a fresh alternative phrasing
}
```

## Response

```jsonc
{ "message": "Hi Rahim, Nazmul from Velto ...", "sendWindow": "11:00–12:30 or 19:30–21:00 (Dhaka)", "model": "gpt-4o-mini" }
```

## Cost

At `gpt-4o-mini`, each draft is a few hundred tokens — well under ~$0.001 per
message. A month of heavy daily follow-ups typically costs a few US dollars.

## Want Claude instead of OpenAI?

Swap the `fetch` block for the Anthropic Messages API (`https://api.anthropic.com/v1/messages`,
header `x-api-key`, model e.g. `claude-haiku-4-5`) and read `ANTHROPIC_API_KEY`.
The request/response contract the app expects stays identical.
