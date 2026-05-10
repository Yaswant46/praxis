// Praxis — send-cohort-emails Edge Function
//
// Sends one credential email per team to the team's representative.
// Authenticated callers only: the function relays the caller's JWT to
// Supabase so it can read the cohort's teams via RLS — i.e. only the
// owning Game Master (or master admin) can read the credentials, and
// therefore only they can send them.
//
// Required env vars (Supabase project secrets):
//   SUPABASE_URL                — auto-populated by Supabase
//   SUPABASE_ANON_KEY           — auto-populated
//   RESEND_API_KEY              — your Resend API key
//   PRAXIS_FROM_EMAIL           — verified Resend sender, e.g. praxis@your-domain.com
//   PRAXIS_APP_BASE_URL         — public URL the email links into,
//                                 e.g. https://yaswant46.github.io/praxis
//
// Request body:  { session_id: UUID, team_ids?: UUID[] }
//   - team_ids omitted → send to every team in the cohort
//   - team_ids present  → send only to the listed teams (resend flow)
//
// Response: { sent: number, failed: number, results: [{ team_id, ok, error? }] }

// deno-lint-ignore-file no-explicit-any
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const RESEND_ENDPOINT = "https://api.resend.com/emails";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function escapeHtml(s: string): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function buildEmailHtml(opts: {
  cohortName: string;
  caseName: string;
  totalRounds: number;
  teamDisplayName: string;
  username: string;
  password: string;
  loginUrl: string;
}): string {
  const e = escapeHtml;
  return `<!doctype html>
<html><body style="margin:0;padding:0;background:#0b0f14;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#e6eaf0">
<div style="max-width:560px;margin:0 auto;padding:32px 24px">
  <div style="text-align:center;margin-bottom:24px">
    <div style="font-size:24px;font-weight:800;letter-spacing:-0.5px;color:#c8ff00">Praxis</div>
    <div style="font-size:12px;color:#8a93a3;letter-spacing:1.5px;text-transform:uppercase;margin-top:4px">Scenario Simulation</div>
  </div>
  <div style="background:#11161d;border:1px solid #1f2630;border-radius:12px;padding:28px 24px">
    <h1 style="margin:0 0 8px;font-size:18px;font-weight:700">You're invited to a Praxis cohort</h1>
    <p style="margin:0 0 20px;font-size:14px;line-height:1.55;color:#b9c0cc">
      <strong style="color:#fff">${e(opts.cohortName)}</strong> — ${e(opts.caseName)} · ${opts.totalRounds} rounds
    </p>
    <p style="margin:0 0 24px;font-size:14px;line-height:1.55;color:#b9c0cc">
      You are the representative for <strong style="color:#fff">${e(opts.teamDisplayName)}</strong>. Forward this email to your teammates so they can join.
    </p>
    <table style="width:100%;border-collapse:collapse;margin-bottom:24px;font-size:13px">
      <tr>
        <td style="padding:10px 12px;background:#0b0f14;border:1px solid #1f2630;border-radius:6px 6px 0 0;color:#8a93a3;width:120px">Team</td>
        <td style="padding:10px 12px;background:#0b0f14;border:1px solid #1f2630;border-left:0;border-radius:0 6px 0 0;color:#fff;font-weight:600">${e(opts.teamDisplayName)}</td>
      </tr>
      <tr>
        <td style="padding:10px 12px;background:#0b0f14;border:1px solid #1f2630;border-top:0;color:#8a93a3">Username</td>
        <td style="padding:10px 12px;background:#0b0f14;border:1px solid #1f2630;border-top:0;border-left:0;font-family:'SFMono-Regular',Menlo,Consolas,monospace;color:#c8ff00">${e(opts.username)}</td>
      </tr>
      <tr>
        <td style="padding:10px 12px;background:#0b0f14;border:1px solid #1f2630;border-top:0;border-radius:0 0 0 6px;color:#8a93a3">Password</td>
        <td style="padding:10px 12px;background:#0b0f14;border:1px solid #1f2630;border-top:0;border-left:0;border-radius:0 0 6px 0;font-family:'SFMono-Regular',Menlo,Consolas,monospace;color:#c8ff00">${e(opts.password)}</td>
      </tr>
    </table>
    <div style="text-align:center;margin-bottom:20px">
      <a href="${e(opts.loginUrl)}"
         style="display:inline-block;background:#c8ff00;color:#0b0f14;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:700;font-size:14px">
         Enter the simulation →
      </a>
    </div>
    <p style="margin:0;font-size:12px;line-height:1.55;color:#8a93a3;text-align:center">
      Or paste this link in your browser:<br>
      <span style="color:#b9c0cc;word-break:break-all">${e(opts.loginUrl)}</span>
    </p>
  </div>
  <p style="margin:18px 0 0;font-size:11px;color:#5d6573;text-align:center">
    Confidential. Share only with your team.
  </p>
</div>
</body></html>`;
}

function buildEmailText(opts: {
  cohortName: string;
  caseName: string;
  totalRounds: number;
  teamDisplayName: string;
  username: string;
  password: string;
  loginUrl: string;
}): string {
  return [
    `Praxis — ${opts.cohortName}`,
    `${opts.caseName} · ${opts.totalRounds} rounds`,
    ``,
    `You are the representative for ${opts.teamDisplayName}.`,
    `Forward this email to your teammates so they can join.`,
    ``,
    `Team:     ${opts.teamDisplayName}`,
    `Username: ${opts.username}`,
    `Password: ${opts.password}`,
    ``,
    `Enter the simulation:`,
    opts.loginUrl,
    ``,
    `Confidential. Share only with your team.`,
  ].join("\n");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST")    return jsonResponse({ error: "Method not allowed" }, 405);

  const SUPABASE_URL      = Deno.env.get("SUPABASE_URL");
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  const RESEND_API_KEY    = Deno.env.get("RESEND_API_KEY");
  const FROM_EMAIL        = Deno.env.get("PRAXIS_FROM_EMAIL");
  const APP_BASE_URL      = Deno.env.get("PRAXIS_APP_BASE_URL");

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return jsonResponse({ error: "Supabase env not configured" }, 500);
  if (!RESEND_API_KEY)                     return jsonResponse({ error: "RESEND_API_KEY not set"     }, 500);
  if (!FROM_EMAIL)                         return jsonResponse({ error: "PRAXIS_FROM_EMAIL not set"  }, 500);
  if (!APP_BASE_URL)                       return jsonResponse({ error: "PRAXIS_APP_BASE_URL not set"}, 500);

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return jsonResponse({ error: "Missing bearer token" }, 401);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const sessionId: string | undefined        = body?.session_id;
  const onlyTeamIds: string[] | undefined    = Array.isArray(body?.team_ids) ? body.team_ids : undefined;
  if (!sessionId) return jsonResponse({ error: "session_id is required" }, 400);

  // Build a Supabase client that runs queries AS THE CALLER. Reads of the
  // teams table are gated by RLS, so unauthorized callers get nothing.
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: session, error: sessErr } = await supabase
    .from("sessions")
    .select("id, code, cohort_name, total_rounds, cases(name, slug)")
    .eq("id", sessionId)
    .single();
  if (sessErr || !session) {
    return jsonResponse({ error: "Session not found or not authorized" }, 404);
  }

  let teamsQuery = supabase
    .from("teams")
    .select("id, slot, team_number, display_name, username, password, representative_email")
    .eq("session_id", sessionId)
    .order("team_number", { ascending: true });
  if (onlyTeamIds && onlyTeamIds.length) teamsQuery = teamsQuery.in("id", onlyTeamIds);
  const { data: teams, error: teamsErr } = await teamsQuery;
  if (teamsErr) return jsonResponse({ error: "Failed to load teams: " + teamsErr.message }, 500);
  if (!teams || teams.length === 0) {
    return jsonResponse({ error: "No teams to send to (RLS may have filtered them)" }, 403);
  }

  const cohortName  = session.cohort_name ?? "Praxis Cohort";
  const caseName    = (session as any).cases?.name ?? "Praxis";
  const totalRounds = session.total_rounds ?? 5;
  const baseUrl     = APP_BASE_URL.replace(/\/+$/, "");

  const results: Array<{ team_id: string; ok: boolean; error?: string }> = [];
  let sentTeamIds: string[] = [];

  for (const t of teams) {
    if (!t.representative_email) {
      results.push({ team_id: t.id, ok: false, error: "no representative_email" });
      continue;
    }
    const loginUrl = `${baseUrl}/#/session/${session.code}/team/${t.slot}`;
    const html     = buildEmailHtml({
      cohortName, caseName, totalRounds,
      teamDisplayName: t.display_name,
      username: t.username,
      password: t.password,
      loginUrl,
    });
    const text     = buildEmailText({
      cohortName, caseName, totalRounds,
      teamDisplayName: t.display_name,
      username: t.username,
      password: t.password,
      loginUrl,
    });

    const subject = `Praxis — ${cohortName} · ${t.display_name} login`;

    const resp = await fetch(RESEND_ENDPOINT, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type":  "application/json",
      },
      body: JSON.stringify({
        from: FROM_EMAIL,
        to:   [t.representative_email],
        subject,
        html,
        text,
      }),
    });
    if (resp.ok) {
      results.push({ team_id: t.id, ok: true });
      sentTeamIds.push(t.id);
    } else {
      const err = await resp.text();
      results.push({ team_id: t.id, ok: false, error: `Resend ${resp.status}: ${err.slice(0, 240)}` });
    }
  }

  // Stamp credentials_sent_at on every team that succeeded.
  if (sentTeamIds.length) {
    await supabase
      .from("teams")
      .update({ credentials_sent_at: new Date().toISOString() })
      .in("id", sentTeamIds);
  }

  const sent   = results.filter(r => r.ok).length;
  const failed = results.length - sent;
  return jsonResponse({ sent, failed, results });
});
