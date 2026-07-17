// Praxis — score-behavioural Edge Function
//
// Scores a participant's written leadership response on three dimensions using
// Claude. The Anthropic API key lives ONLY here (Supabase project secret), never
// in the client — this is why the scoring must run server-side.
//
// Dimensions (each 1–5):
//   clarity               — is the reasoning clear and structured?
//   stakeholder_awareness — does it account for the people impact?
//   ethical_alignment     — does it hold against stated company values?
// total (max 15) → people_score normalised to 0–100.
//
// Required env vars (Supabase project secrets):
//   ANTHROPIC_API_KEY — console.anthropic.com key
//
// Request body: { response_text: string, round_context?: string }
// Response:     { clarity, stakeholder_awareness, ethical_alignment, total, people_score }
//
// ⚠️ SECRECY NOTE: this function RETURNS the score, so it is for GM/server use.
// The participant "submit → score hidden during play" flow must store the score
// in a GM-only table (decision_secrets — next increment) and return only {ok},
// NOT surface the numbers to the participant. Do not wire the raw return into a
// participant-visible view.

// deno-lint-ignore-file no-explicit-any

const ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages";
const MODEL = "claude-sonnet-4-6";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
}

function clamp1to5(n: any): number {
  const x = Math.round(Number(n));
  if (!Number.isFinite(x)) return 1;
  return Math.max(1, Math.min(5, x));
}

const SYSTEM_PROMPT =
  "You are a leadership assessor for a business simulation. You score a participant's " +
  "written response to a leadership decision on three dimensions, each an integer 1-5:\n" +
  "- clarity: is the reasoning clear, structured, and specific (not vague)?\n" +
  "- stakeholder_awareness: does it account for the impact on people (team, customers, partners)?\n" +
  "- ethical_alignment: does it hold against a company's stated values and long-term integrity?\n" +
  "Score strictly and consistently. 3 is a competent, average response; 5 is exceptional; " +
  "1 is absent or actively poor. Judge only the reasoning shown, do not reward length. " +
  "Return ONLY the three integer scores in the required JSON object.";

const OUTPUT_SCHEMA = {
  type: "object",
  properties: {
    clarity: { type: "integer" },
    stakeholder_awareness: { type: "integer" },
    ethical_alignment: { type: "integer" },
  },
  required: ["clarity", "stakeholder_awareness", "ethical_alignment"],
  additionalProperties: false,
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "POST only" }, 405);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return jsonResponse({ error: "server_not_configured: ANTHROPIC_API_KEY missing" }, 500);

  let body: any;
  try { body = await req.json(); } catch { return jsonResponse({ error: "invalid_json" }, 400); }

  const responseText = String(body.response_text ?? "").slice(0, 4000).trim();
  const roundContext = String(body.round_context ?? "").slice(0, 2000);
  if (!responseText) return jsonResponse({ error: "response_text required" }, 400);

  const userPrompt =
    (roundContext ? `Decision context:\n${roundContext}\n\n` : "") +
    `Participant's written response:\n"""\n${responseText}\n"""\n\n` +
    "Score clarity, stakeholder_awareness, and ethical_alignment (each 1-5).";

  let claudeResp: Response;
  try {
    claudeResp = await fetch(ANTHROPIC_ENDPOINT, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1000,
        system: SYSTEM_PROMPT,
        output_config: { format: { type: "json_schema", schema: OUTPUT_SCHEMA } },
        messages: [{ role: "user", content: userPrompt }],
      }),
    });
  } catch (e) {
    return jsonResponse({ error: "upstream_unreachable", detail: String(e) }, 502);
  }

  if (!claudeResp.ok) {
    const txt = await claudeResp.text();
    return jsonResponse({ error: "anthropic_error", status: claudeResp.status, detail: txt.slice(0, 500) }, 502);
  }

  const data = await claudeResp.json();
  if (data.stop_reason === "refusal") return jsonResponse({ error: "refused" }, 502);

  const textBlock = (data.content || []).find((b: any) => b.type === "text");
  let parsed: any = null;
  try { parsed = JSON.parse(textBlock?.text ?? "{}"); } catch { /* fall through */ }
  if (!parsed || typeof parsed !== "object") {
    return jsonResponse({ error: "unparseable_model_output" }, 502);
  }

  const clarity = clamp1to5(parsed.clarity);
  const stakeholder_awareness = clamp1to5(parsed.stakeholder_awareness);
  const ethical_alignment = clamp1to5(parsed.ethical_alignment);
  const total = clarity + stakeholder_awareness + ethical_alignment; // max 15
  const people_score = Math.round((total / 15) * 100);

  return jsonResponse({ clarity, stakeholder_awareness, ethical_alignment, total, people_score });
});
