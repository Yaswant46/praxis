/* Headless end-to-end against the LIVE Praxis DB via the anon key — mirrors the
 * app's competitive resolve path (dbGetTeams → PraxisEngine.resolveRound →
 * dbPublishCompetitiveOutcome / dbInsertMarketNews / dbSaveTeamState → read back).
 * Creates a throwaway Suryan session and deletes it (cascade) at the end.
 * Run: node tests/e2e_live.mjs
 */
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const E = require('../praxis_engine.js');
const C = E.SURYAN_CONFIG;

const URL = 'https://towyztagdudjbxfevnus.supabase.co';
const KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRvd3l6dGFnZHVkamJ4ZmV2bnVzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU1NzA0NzQsImV4cCI6MjA5MTE0NjQ3NH0.57SNbO6ZtxxZOgd1OPlE3mT92F62-dTSavqVEWK2ENA';
const H = { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' };

async function rest(method, path, body, prefer) {
  const headers = { ...H }; if (prefer) headers.Prefer = prefer;
  const r = await fetch(URL + '/rest/v1/' + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const txt = await r.text();
  if (!r.ok) throw new Error(method + ' ' + path + ' → ' + r.status + ' ' + txt);
  return txt ? JSON.parse(txt) : null;
}
const log = (...a) => console.log(...a);

(async () => {
  // case id
  const cases = await rest('GET', 'cases?slug=eq.suryan&select=id,mode');
  log('case suryan:', cases[0].mode);

  // 1. session
  const code = 'E2E' + String(Math.floor(Date.now() / 1000)).slice(-3);
  const sess = (await rest('POST', 'sessions',
    { code, case_id: cases[0].id, cohort_name: '__e2e_dryrun__', admin_email: 'e2e@test', current_round: 1, round_open: true, status: 'active' },
    'return=representation'))[0];
  log('session', code, sess.id);

  // 2. teams
  const teamDefs = [['alpha', 'Helios', 'command'], ['beta', 'Aditya', 'coach'], ['gamma', 'Prabha', 'steward'], ['delta', 'Kiran', 'command']];
  const teams = await rest('POST', 'teams',
    teamDefs.map(([slot, name]) => ({ session_id: sess.id, slot, display_name: name, access_code: slot + '01' })),
    'return=representation');
  const byName = {}; teams.forEach(t => byName[t.display_name] = t);
  log('teams:', teams.map(t => t.display_name).join(', '));

  // decision sets per app-round (subset mirroring the smoke sim)
  const D = {
    1: { Helios: { posture: 'Command — decisive' }, Aditya: { posture: 'Coach — develop' }, Prabha: { posture: 'Steward — protect' }, Kiran: { posture: 'Command — decisive' } },
    2: {
      Helios: { hire_crews_bid_count: '4', hire_crews_bid_wage: '13', subcontract_crews: '8', price_index: '0.95', channel_spend: '2', quality_invest: '0', tier1_premium_bid: '2', li1: 'Overrule him — scale subcontracting, move on' },
      Aditya: { hire_crews_bid_count: '2', hire_crews_bid_wage: '10', subcontract_crews: '2', price_index: '1.0', channel_spend: '1', quality_invest: '1', tier1_premium_bid: '4', li1: 'Give him ownership of subcontractor quality, with authority to reject crews' },
      Prabha: { hire_crews_bid_count: '2', hire_crews_bid_wage: '10', subcontract_crews: '0', price_index: '1.05', channel_spend: '0.5', quality_invest: '1.5', tier1_premium_bid: '6', ration_demand: 'Ration — turn away demand to protect quality', li1: 'Back the ops head — cap subcontracting at 20%' },
      Kiran: { hire_crews_bid_count: '0', hire_crews_bid_wage: '9.5', subcontract_crews: '12', price_index: '0.9', channel_spend: '3', quality_invest: '0', tier1_premium_bid: '0', li1: 'Split the difference publicly, decide nothing' },
    },
    3: {
      Helios: { quality_response: 'Deny — the data is wrong', hire_crews_bid_count: '2', hire_crews_bid_wage: '14', subcontract_crews: '8', price_index: '0.95', li2: 'Keep him — the numbers matter more right now' },
      Aditya: { quality_response: 'Recall & rework openly', quality_invest: '1', retention_spend: '0.5', training_invest: '0.5', hire_crews_bid_count: '2', hire_crews_bid_wage: '12', subcontract_crews: '2', price_index: '1.0', li2: 'Demote and rebuild him under a quality mandate; protect the whistleblower visibly' },
      Prabha: { quality_response: 'Recall & rework openly', quality_invest: '1.5', retention_spend: '1', hire_crews_bid_count: '2', hire_crews_bid_wage: '11', subcontract_crews: '0', price_index: '1.05', li2: 'Fire the supervisor publicly, thank the whistleblower publicly' },
      Kiran: { quality_response: 'Quiet fix — no announcement', hire_crews_bid_count: '0', hire_crews_bid_wage: '9.5', subcontract_crews: '12', price_index: '0.9', li2: 'Quiet exit for the supervisor, quiet transfer for the whistleblower' },
    },
    4: {
      Helios: { payment_priority: 'Defer all three — buy time', emergency_capital: 'None', install_pace: 'Full pace', headcount_action: 'Hold everyone', poach_bid: '0', price_index: '0.95' },
      Aditya: { payment_priority: 'Crews first, then vendors, then bank', emergency_capital: 'Equity dilution — ₹15 Cr for 20%', install_pace: 'Slow to 50%', headcount_action: 'Hold everyone', poach_bid: '16', acquire_book: 'Yes', price_index: '1.0' },
      Prabha: { payment_priority: 'Vendors first — honor the relationship', emergency_capital: 'Bridge debt — 24% p.a.', install_pace: 'Slow to 50%', headcount_action: 'Hold everyone', poach_bid: '14', price_index: '1.05' },
      Kiran: { payment_priority: 'Bank first — protect the credit line', emergency_capital: 'None', install_pace: 'Full pace', headcount_action: 'Layoff 20%', poach_bid: '0', price_index: '0.9' },
    },
    5: {
      Helios: { pivot_cni: '20', pivot_om: '20', pivot_harvest: '60', crews_retained: '8', price_index: '1.0', acquisition: 'Sell — take the boom-inflated exit' },
      Aditya: { pivot_cni: '40', pivot_om: '50', pivot_harvest: '10', crews_retained: '20', price_index: '1.0', acquisition: 'Decline — build for the long game' },
      Prabha: { pivot_cni: '30', pivot_om: '60', pivot_harvest: '10', crews_retained: '18', price_index: '1.05', acquisition: 'Negotiate' },
      Kiran: { pivot_cni: '10', pivot_om: '10', pivot_harvest: '80', crews_retained: '5', price_index: '0.9', acquisition: 'Sell — take the boom-inflated exit' },
    },
  };

  // helper: submit a team's decisions for a round (mirrors dbSaveDecision upserts)
  async function submit(round, teamId, fields) {
    const rows = Object.entries(fields).map(([field_id, value]) => ({ session_id: sess.id, team_id: teamId, round, domain_id: 'suryan', field_id, value }));
    await rest('POST', 'decisions', rows, 'resolution=merge-duplicates,return=minimal');
  }
  // helper: fetch all decisions for a round → {teamId:{field:val}} (mirrors dbGetAllDecisions)
  async function getAll(round) {
    const rows = await rest('GET', `decisions?session_id=eq.${sess.id}&round=eq.${round}&select=team_id,field_id,value`);
    const out = {}; rows.forEach(r => { (out[r.team_id] = out[r.team_id] || {})[r.field_id] = r.value; }); return out;
  }
  async function getTeams() { return rest('GET', `teams?session_id=eq.${sess.id}&select=*`); }

  // ── ROUND 0 (posture) ──
  for (const t of teams) await submit(1, t.id, D[1][t.display_name]);
  { // mirror adminResolveRound posture branch
    const decs = await getAll(1);
    for (const t of teams) {
      const p = E.parsePosture((decs[t.id] || {}).posture);
      await rest('PATCH', 'teams?id=eq.' + t.id, { posture: p, state: E.initState(C) }, 'return=minimal');
    }
    log('\nR0 postures recorded:', teams.map(t => t.display_name).join('/'));
  }

  // ── ROUNDS R1..R4 (app-round 2..5) ──
  for (let round = 2; round <= 5; round++) {
    await rest('PATCH', 'sessions?id=eq.' + sess.id, { current_round: round, round_open: true }, 'return=minimal');
    for (const t of teams) await submit(round, t.id, D[round][t.display_name]);
    // resolve (mirror adminResolveRound)
    const decisions = await getAll(round);
    const teamRows = await getTeams();
    const engineTeams = teamRows.map(t => ({ id: t.id, name: t.display_name, posture: t.posture, posture_switched: !!t.posture_switched, state: t.state }));
    const res = E.resolveRound({ config: C, round, teams: engineTeams, decisions });
    // write outcomes + state + news
    for (const t of res.teams) {
      await rest('POST', 'outcomes', [{ session_id: sess.id, team_id: t.id, round, revenue: t.outcome.revenue, gross_margin: t.outcome.gross_margin, cash_runway: t.outcome.cash_runway, market_share: t.outcome.market_share, product_health: t.outcome.product_health, team_capability: t.outcome.team_capability, score: t.outcome.score, detail: t.detail }], 'resolution=merge-duplicates,return=minimal');
      await rest('PATCH', 'teams?id=eq.' + t.id, { state: t.state, posture: t.posture, posture_switched: t.posture_switched }, 'return=minimal');
    }
    await rest('DELETE', `market_news?session_id=eq.${sess.id}&round=eq.${round}`);
    if (res.news.length) await rest('POST', 'market_news', res.news.map(n => ({ session_id: sess.id, round, team_id: n.team_id, headline: n.headline, detail: n.detail, reputation_delta: n.reputation_delta })), 'return=minimal');
    log(`R${round - 1} resolved · ${res.news.length} news · ` + res.teams.map(t => t.name + ' ₹' + t.state.cash.toFixed(1) + 'Cr/rep' + Math.round(t.state.reputation)).join('  '));
  }

  // ── read back the leaderboard data the app would render ──
  const finalTeams = await getTeams();
  const news = await rest('GET', `market_news?session_id=eq.${sess.id}&select=round,headline,reputation_delta&order=round`);
  log('\n── IN-GAME leaderboard (financial-only, from DB) ──');
  finalTeams.map(t => ({ n: t.display_name, fin: (t.state.cumulative_fcf || 0) + (t.state.last_ebitda || 0) })).sort((a, b) => b.fin - a.fin)
    .forEach((r, i) => log('  ' + (i + 1) + '. ' + r.n.padEnd(8) + ' ₹' + r.fin.toFixed(1) + ' Cr'));
  log('  market_news rows persisted:', news.length);

  // ── End Session → full weighted reveal ──
  await rest('PATCH', 'sessions?id=eq.' + sess.id, { status: 'ended', round_open: false }, 'return=minimal');
  const scores = E.computeFinalScores(C, finalTeams.map(t => ({ id: t.id, name: t.display_name, state: t.state })));
  log('\n── END SESSION full reveal (40/25/20/15) ──');
  scores.forEach((s, i) => { const n = finalTeams.find(t => t.id === s.id).display_name; log('  ' + (i + 1) + '. ' + n.padEnd(8) + ' TOTAL ' + s.total + '  [fin ' + (s.financial * 40).toFixed(1) + ' surv ' + (s.survivability * 25).toFixed(1) + ' trust ' + (s.trust * 20).toFixed(1) + ' rep ' + (s.reputation * 15).toFixed(1) + ']'); });

  // ── verify outcomes.detail persisted ──
  const oc = await rest('GET', `outcomes?session_id=eq.${sess.id}&round=eq.5&select=team_id,detail`);
  log('\n  R4 outcomes with detail JSONB:', oc.length, '| sample survivability in detail:', oc[0] && oc[0].detail && oc[0].detail.survivability ? 'present' : 'n/a');

  // ── cleanup ──
  await rest('DELETE', 'sessions?id=eq.' + sess.id);
  const check = await rest('GET', `sessions?code=eq.${code}&select=id`);
  log('\n  cleanup: session deleted →', check.length === 0 ? 'OK (0 rows)' : 'STILL PRESENT');
  log('\n✅ headless E2E complete');
})().catch(e => { console.error('E2E FAILED:', e.message); process.exit(1); });
