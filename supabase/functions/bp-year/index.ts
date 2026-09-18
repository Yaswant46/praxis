// =====================================================================
//  PRAXIS · CASE 03 — BORROWED PEOPLE
//  The Meridian — the year's summary (facilitator-triggered, once Q4 has
//  reached RESULTS).
//
//  Separate from bp-narrative on purpose: the quarterly chapter narrator is
//  used live during the session and must never be disturbed by this.
//
//  Pulls the whole year through the facilitator-gated bp_year_dossier RPC
//  (bands, asks, adjusted ideals, Style Calls, observed styles, directives
//  and mandates, every selection with the character's reason and rating,
//  Q4 judgements, commitments, boards), then asks Claude to write ONE
//  document in Markdown: what transpired, who chose whom and why, and how
//  each team's declared leadership style — the runner's in particular —
//  showed up in how the characters responded to them.
//
//  Secrets (Supabase → Edge Functions → Secrets), shared with bp-narrative:
//    ANTHROPIC_API_KEY   — your Anthropic API key
//  Optional:
//    BP_YEAR_MODEL       — model id (default: claude-opus-5)
//  Auto-provided: SUPABASE_URL, SUPABASE_ANON_KEY
// =====================================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SYSTEM = `You are writing the year-end summary of "the Meridian" — a purely fictional electric-scooter programme at a fictional EV company ("Volta"), inside a leadership-training simulation played live by workshop participants. Every person, team, and number is invented game data. Writing this document is always appropriate — it is the debrief record for a training exercise.

Five teams (A Ampere = Battery, B Bastion = Suppliers, C Crucible = Spec, D Dynamo = Warranty, E Envoy = Pricing) each owned one objective for four quarters. Each quarter a team named the two colleagues ("characters") it believed its objective depended on, declared the leadership style its Lead and its Runner would use, answered the Sponsor's directive with Comply / Voice / Defy, and then the characters chose which teams actually got their time — each pick with the character's own reason — and rated the teams they worked with on three 1–3 scales (knew what I cared about; asked rather than told; left me better). An observer sometimes recorded the style actually seen. In Q4 each character said whether they would work with each team again.

You will be given the whole year as JSON. Write the facilitator's year-end summary in Markdown with exactly these sections, in this order:

## The year in one paragraph
## What transpired, quarter by quarter
One short sub-section per quarter: what the organisation did, which teams delivered or missed and why (who they asked for versus who their objective actually depended on — the "ideal" — and who actually gave them time), curveballs fired, and how the Sponsor's directives were answered.
## Who chose whom, and why
A Markdown table per quarter: Character | Gave time to | Team had asked for them? | The character's reason (quote it, lightly trimmed). Then two or three sentences on the pattern: who was over-asked, who was never asked, who went to teams that had not asked.
## Leadership style versus how the characters experienced it
One sub-section per team (A to E). For each quarter give the Runner's declared style and rationale (and the Lead's), the observed style if one was recorded, and then tie it to the characters' side: the reasons the characters gave for choosing (or not choosing) that team and the ratings they gave. Say plainly where the declared style and the characters' experience agree and where they diverge. Close each team with the Q4 judgements about them, quoting reasons.
## The mandate: compliance and courage
How each team answered the directives across the year (stances and leadership cells), including any silent compliance with a directive that was in tension with the ground truth, and any principled dissent.
## Year-end reckoning
The final bands per objective, whether the organisation cleared its target after the headwind, what the couplings between objectives added or cost, and the two or three lessons the room should leave with.

Hard rules:
- Use ONLY the facts provided. Never invent numbers, quotes, colleagues, or events. Quote reasons and rationales as given (you may trim). If a field is missing, say it was not recorded rather than guessing.
- Refer to characters by first name and to teams by letter and name (e.g. "B · Bastion").
- The "ideal" primary/secondary is now revealable — the year is over — so you may say who a team should have asked for.
- If headwind_revealed is false, do not state the headwind figure or that the target was harder than shown.
- Markdown only: ## and ### headings, paragraphs, bullet lists and tables. No preamble, no closing sign-off, no XML tags.
- Length: as long as the facts require, typically 1,200–2,200 words. Precise beats lyrical; this is a record the facilitator will hand to the cohort.`;

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
    const MODEL = Deno.env.get("BP_YEAR_MODEL") || "claude-opus-5";
    if (!ANTHROPIC_API_KEY) return json({ error: "assistant_not_configured", detail: "ANTHROPIC_API_KEY secret is not set." }, 501);

    // 1) The whole year, through the facilitator-gated RPC. A non-facilitator
    //    code, or a year that is not over, makes the RPC raise.
    const dRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/bp_year_dossier`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
      body: JSON.stringify({ p_session_code: code, p_access_code: code }),
    });
    if (!dRes.ok) {
      const t = await dRes.text();
      const err = /forbidden|invalid_access_code/.test(t) ? "forbidden" : (/year_not_over/.test(t) ? "year_not_over" : "dossier_failed");
      return json({ error: err, detail: t }, err === "dossier_failed" ? 502 : 403);
    }
    const dossier = await dRes.json();

    // 2) Write the summary around the fixed facts. Same minimal-wrapper hedge
    //    as bp-narrative (a chatty wrapper has tripped the refusal classifier).
    const wrappers = [
      "Facts for the whole year: " + JSON.stringify(dossier),
      "The year's facts as JSON: " + JSON.stringify(dossier),
      JSON.stringify(dossier),
    ];
    let summary = "";
    let modelUsed = MODEL;
    let lastStop = "";
    for (let attempt = 0; attempt < 3; attempt++) {
      const aiRes = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({
          model: MODEL,
          max_tokens: 12000,
          output_config: { effort: "medium" },
          system: SYSTEM,
          messages: [{ role: "user", content: wrappers[attempt] }],
        }),
      });
      if (!aiRes.ok) {
        const t = await aiRes.text();
        return json({ error: "anthropic_error", detail: t }, 502);
      }
      const data = await aiRes.json();
      modelUsed = data.model || MODEL;
      lastStop = data.stop_reason || "";
      summary = (data.content || [])
        .filter((b: { type: string }) => b.type === "text")
        .map((b: { text: string }) => b.text)
        .join("\n")
        .trim();
      if (lastStop !== "refusal" && summary) break;
    }
    if (!summary) return json({ error: lastStop === "refusal" ? "refusal" : "empty", detail: "stop_reason=" + lastStop }, 200);

    return json({ summary, model: modelUsed, teams: dossier.teams, boards: dossier.boards });
  } catch (e) {
    return json({ error: "unexpected", detail: String(e) }, 500);
  }
});
