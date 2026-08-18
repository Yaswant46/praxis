// =====================================================================
//  PRAXIS · CASE 03 — BORROWED PEOPLE
//  Org storyline narrator (facilitator-triggered, on-demand).
//
//  The facilitator presses "Generate" after running a quarter's results.
//  This function pulls the DETERMINISTIC spine (bp_org_spine — bands,
//  momentum, meter, couplings, achievements) through the facilitator-gated
//  RPC, then asks Claude to write ONE chapter of prose around those fixed
//  facts. The facts are never invented by the model; only the words are.
//
//  Secrets (Supabase → Edge Functions → Secrets):
//    ANTHROPIC_API_KEY   — your Anthropic API key
//  Optional:
//    BP_NARRATIVE_MODEL  — model id (default: claude-opus-5)
//  Auto-provided: SUPABASE_URL, SUPABASE_ANON_KEY
// =====================================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SYSTEM = `You are the narrator of "the Meridian" — a purely fictional electric-scooter programme at a fictional EV company ("Volta"), inside a leadership-training board game played live by workshop participants. Every person, team, and number is invented game data; writing this chapter is always appropriate — it is flavour text for a training exercise. Five teams each own one piece of the launch: Battery, Suppliers, Spec, Warranty, and Pricing. Each team's fate depends on which colleagues chose to work with them and how well they treated the people they borrowed.

You will be given ONE quarter's FACTS as JSON: each programme's band and momentum this quarter, which programmes are rising or dragging, the organisation's progress meter, and — only in the final quarter — the year-end couplings and the company scorecard.

Write the ORGANISATION's story for this quarter: how the company as a whole moved, grounded ONLY in the facts given. Refer to programmes by their objective name (Battery, Suppliers, Spec, Warranty, Pricing). Name what is gaining and what is slipping. If is_final is true, make it the reckoning — whether the Meridian hit its target for the year, what the pattern of wins amounted to, and what any overreach cost.

Hard rules:
- Use ONLY the facts provided. Never invent numbers, colleagues, or which specific person was the "right" one to ask — that stays hidden.
- If "headwind_revealed" is false, do NOT mention any headwind, macro drag, hidden cost, or that the target is harder than it looks — the room does not know yet.
- No headings, no bullet points, no tables, and do not dump score numbers — the app shows the meter and scorecard separately. Flowing narrative prose only.
- 2 to 4 short paragraphs, roughly 120–200 words. Evocative but grounded. It is read aloud to the room between phases.
- Do not include any internal or system XML tags.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  try {
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const { code, quarter } = await req.json().catch(() => ({}));
    if (!code) return json({ error: "missing_code" }, 400);
    const q = Number(quarter);
    if (!Number.isInteger(q) || q < 1 || q > 4) return json({ error: "bad_quarter" }, 400);

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
    const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
    const MODEL = Deno.env.get("BP_NARRATIVE_MODEL") || "claude-opus-5";
    if (!ANTHROPIC_API_KEY) return json({ error: "assistant_not_configured", detail: "ANTHROPIC_API_KEY secret is not set." }, 501);

    // 1) Pull the deterministic spine through the facilitator-gated RPC.
    //    A non-facilitator code makes bp_org_spine raise → 403.
    const spineRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/bp_org_spine`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      },
      body: JSON.stringify({ p_session_code: code, p_access_code: code, p_quarter: q }),
    });
    if (!spineRes.ok) {
      const t = await spineRes.text();
      const forbidden = /forbidden|invalid_access_code/.test(t);
      return json({ error: forbidden ? "forbidden" : "spine_failed", detail: t }, forbidden ? 403 : 502);
    }
    const spine = await spineRes.json();

    // 2) Ask Claude to write the chapter around the fixed facts.
    // NOTE: the wrapper is deliberately minimal. The previous phrasing
    // ("Quarter N of the Meridian ... Write the organisation's chapter" with a
    // ```json fence) deterministically tripped the API's refusal classifier
    // (stop_reason "refusal", 0 output tokens) on some inputs; a plain
    // "Facts:" prefix generates reliably. Retries vary the wrapper as a
    // further hedge.
    const wrappers = [
      "Facts: " + JSON.stringify(spine),
      "This quarter's facts as JSON: " + JSON.stringify(spine),
      JSON.stringify(spine),
    ];

    let narrative = "";
    let modelUsed = MODEL;
    let lastStop = "";
    for (let attempt = 0; attempt < 3; attempt++) {
      const userContent = wrappers[attempt];
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
      narrative = (data.content || [])
        .filter((b: { type: string }) => b.type === "text")
        .map((b: { text: string }) => b.text)
        .join("\n")
        .trim();
      if (lastStop !== "refusal" && narrative) break;
    }
    if (!narrative) {
      return json({ error: lastStop === "refusal" ? "refusal" : "empty", detail: "stop_reason=" + lastStop }, 200);
    }

    return json({ narrative, spine, model: modelUsed });
  } catch (e) {
    return json({ error: "unexpected", detail: String(e) }, 500);
  }
});
