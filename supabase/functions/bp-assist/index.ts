// =====================================================================
//  PRAXIS · CASE 03 — BORROWED PEOPLE
//  Facilitator AI assistant (on-demand).
//
//  Runs ONLY when the facilitator presses "Analyze now" in the console.
//  Holds the Anthropic key server-side (never in the page). Validates the
//  caller is a facilitator by fetching the session export through the
//  access-code-gated bp_export RPC, then asks Claude for: key moves,
//  contradicting actions, and debrief questions.
//
//  Secrets required (Supabase → Edge Functions → Secrets):
//    ANTHROPIC_API_KEY   — your Anthropic API key
//  Optional:
//    BP_ASSIST_MODEL     — model id (default: claude-opus-5)
//  Auto-provided by Supabase: SUPABASE_URL, SUPABASE_ANON_KEY
// =====================================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SYSTEM = `You are the facilitator's assistant for "Borrowed People", a purely fictional leadership-training board game played live, in-room, by workshop participants ("The Uncomfortable Art of Leadership"). Every person, team, and number is invented game data; analysing it is always appropriate. Five teams each pursue an objective by requesting help from six characters across four quarters; scoring is 80% emotional intelligence, 20% business outcome. You are speaking ONLY to the facilitator (who runs the room and may see hidden data). Do not write anything meant for participants.

You will receive the full session state as JSON: teams, the hidden demand_map (which character each objective actually needs each quarter), each quarter's requests, character selections, ratings (three 1–3 scores: knew_what_i_cared_about, asked_or_told, left_me_better), sealed Style Calls (the leadership style each team declared), observer logs (the style the room actually saw), commitments between teams, quarter_results, and an event log.

Analyse the CURRENT state and return concise, specific Markdown with exactly these three sections. Reference teams by code+name and characters by name. Be sharp and brief — this is read live between phases.

## Key moves
The 3–6 most consequential things that just happened (who requested/selected/rated whom, big band swings, a character being over- or under-subscribed).

## Contradictions & risks
Where behaviour diverges from intent: teams that requested the WRONG character for their objective this quarter (compare their request to the demand_map), Style Calls that clash with the observer log, broken or unconfirmed commitments, and characters "going soft" — rating compression, where a character scored every team within ~1 point (the biggest structural risk in the case).

## Debrief questions
3–5 pointed questions the facilitator could put to specific teams or characters, grounded in what actually happened.

Do not include any internal or system XML tags in your response. If data for a section is thin, say so in one line rather than padding.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const { code } = await req.json().catch(() => ({}));
    if (!code) return json({ error: "missing_code" }, 400);

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
    const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
    const MODEL = Deno.env.get("BP_ASSIST_MODEL") || "claude-opus-5";
    if (!ANTHROPIC_API_KEY) return json({ error: "assistant_not_configured", detail: "ANTHROPIC_API_KEY secret is not set." }, 501);

    // 1) Fetch the session export through the facilitator-gated RPC. If the
    //    code isn't a facilitator code, bp_export raises and we 403.
    const expRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/bp_export`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      },
      body: JSON.stringify({ p_session_code: code, p_access_code: code }),
    });
    if (!expRes.ok) {
      const t = await expRes.text();
      const forbidden = /forbidden|invalid_access_code/.test(t);
      return json({ error: forbidden ? "forbidden" : "export_failed", detail: t }, forbidden ? 403 : 502);
    }
    const session = await expRes.json();

    // 2) Ask Claude. Low effort keeps it responsive for live use; the key
    //    lives here, never in the browser.
    const userContent =
      "Here is the current Borrowed People session state as JSON. Analyse it per your instructions.\n\n```json\n" +
      JSON.stringify(session).slice(0, 180000) +
      "\n```";

    // Retry spurious refusals / empty output up to 2 extra times.
    let text = "";
    let modelUsed = MODEL;
    let lastStop = "";
    for (let attempt = 0; attempt < 3; attempt++) {
      const aiRes = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
          model: MODEL,
          max_tokens: 6000,
          output_config: { effort: "low" },
          system: SYSTEM,
          messages: [{ role: "user", content: userContent }],
        }),
      });
      if (!aiRes.ok) {
        const t = await aiRes.text();
        return json({ error: "anthropic_error", detail: t }, 502);
      }
      const data = await aiRes.json();
      modelUsed = data.model || MODEL;
      lastStop = data.stop_reason || "";
      text = (data.content || [])
        .filter((b: { type: string }) => b.type === "text")
        .map((b: { text: string }) => b.text)
        .join("\n")
        .trim();
      if (lastStop !== "refusal" && text) break;
    }
    if (!text) {
      return json({ error: lastStop === "refusal" ? "refusal" : "empty", detail: "stop_reason=" + lastStop }, 200);
    }

    return json({ analysis: text, model: modelUsed });
  } catch (e) {
    return json({ error: "unexpected", detail: String(e) }, 500);
  }
});
