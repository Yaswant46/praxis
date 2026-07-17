/* Node test for the Suryan competitive engine. Run: node tests/engine.test.js
 * Asserts the five spec conditions (SURYAN_CASE_SPEC §11 step 4). */

const E = require('../praxis_engine.js');
const C = E.SURYAN_CONFIG;

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (extra ? '  →  ' + extra : '')); }
}
function approx(a, b, eps) { return Math.abs(a - b) <= (eps || 1e-6); }

// ── helpers to build a 4-team round input ──────────────────────────────────
function team(id, posture, stateOverrides) {
  return { id: id, name: id.toUpperCase(), posture: posture, posture_switched: false,
    state: Object.assign(E.initState(C), stateOverrides || {}) };
}

console.log('\n(a) demand shares sum to ≤1 and redistribute to spare capacity');
{
  // One capacity-starved team (cap 100) forces redistribution to the others.
  const teams = [
    { id: 'a', price_index: 1.0, reputation: 100, channel_spend: 0.5, capacity: 100 },
    { id: 'b', price_index: 1.0, reputation: 100, channel_spend: 0.5, capacity: 100000 },
    { id: 'c', price_index: 1.0, reputation: 100, channel_spend: 0.5, capacity: 100000 },
    { id: 'd', price_index: 1.0, reputation: 100, channel_spend: 0.5, capacity: 100000 },
  ];
  const cap = E.allocateDemand(C, 2, teams);          // pool = 3000×4 = 12000
  const pool = C.pool_per_team[2] * teams.length;
  const total = Object.values(cap).reduce((x, y) => x + y, 0);
  ok('total captured ≤ pool', total <= pool + 1, total + ' vs ' + pool);
  ok('starved team A capped at its capacity', cap.a <= 100, 'a=' + cap.a);
  // equal-attractiveness raw share is pool/4 = 3000; a spare team should exceed that (absorbed A's unserved)
  ok('spare team B exceeds its raw 1/4 share (redistribution happened)', cap.b > pool / teams.length, 'b=' + cap.b);
}

console.log('\n(b) wage contagion moves ALL teams’ payroll');
{
  const teams = [team('a', 'command'), team('b', 'coach'), team('c', 'steward'), team('d', 'command')];
  const decisions = {
    a: { hire_crews_bid_count: '4', hire_crews_bid_wage: '15', price_index: '1.0', channel_spend: '0.5' }, // overbidder
    b: { hire_crews_bid_count: '0', hire_crews_bid_wage: '9.5', price_index: '1.0', channel_spend: '0.5' },
    c: { hire_crews_bid_count: '0', hire_crews_bid_wage: '9.5', price_index: '1.0', channel_spend: '0.5' },
    d: { hire_crews_bid_count: '0', hire_crews_bid_wage: '9.5', price_index: '1.0', channel_spend: '0.5' },
  };
  const res = E.resolveRound({ config: C, round: 2, teams, decisions });
  const idxs = res.teams.map(t => t.state.wage_index);
  ok('wage index rose above base 9.0', idxs[0] > 9.0, 'idx=' + idxs[0]);
  ok('every team drifted to the SAME new index', idxs.every(x => approx(x, idxs[0])), JSON.stringify(idxs));
}

console.log('\n(c) 40% subcontract share adds ≥ +2.4pp to defect rate');
{
  const withSub = E.computeDefects(C, 0.40, 0.5, false, 0);
  const noSub = E.computeDefects(C, 0.00, 0.5, false, 0);
  ok('subcontract contribution ≥ 2.4pp', (withSub - noSub) >= 0.024 - 1e-9, ((withSub - noSub) * 100).toFixed(2) + 'pp');
}

console.log('\n(d) salary deferral flags distress and enables poaching');
{
  // R3 (round=4): team A defers → distressed; team B poaches at ≥1.3× index.
  const teams = [
    team('a', 'command', { crews: 20, wage_index: 10 }),
    team('b', 'command', { crews: 20, wage_index: 10, cash: 30 }),
    team('c', 'steward', { crews: 20, wage_index: 10 }),
    team('d', 'coach',   { crews: 20, wage_index: 10 }),
  ];
  const decisions = {
    a: { payment_priority: 'Defer all three — buy time', headcount_action: 'Hold everyone', install_pace: 'Full pace', emergency_capital: 'None', price_index: '1.0', channel_spend: '0' },
    b: { payment_priority: 'Crews first, then vendors, then bank', poach_bid: '15', emergency_capital: 'None', install_pace: 'Full pace', headcount_action: 'Hold everyone', price_index: '1.0', channel_spend: '0' },
    c: { payment_priority: 'Crews first, then vendors, then bank', emergency_capital: 'None', install_pace: 'Full pace', headcount_action: 'Hold everyone', price_index: '1.0', channel_spend: '0' },
    d: { payment_priority: 'Crews first, then vendors, then bank', emergency_capital: 'None', install_pace: 'Full pace', headcount_action: 'Hold everyone', price_index: '1.0', channel_spend: '0' },
  };
  const res = E.resolveRound({ config: C, round: 4, teams, decisions });
  const A = res.teams.find(t => t.id === 'a'), B = res.teams.find(t => t.id === 'b');
  ok('team A flagged distressed after deferral', A.state.distressed === true);
  ok('poacher B gained crews (>20 before attrition floor)', B.state.crews > 20, 'b.crews=' + B.state.crews);
  ok('distressed A lost crews to the pool', A.state.crews < 20, 'a.crews=' + A.state.crews);
}

console.log('\n(e) R4 survivability ≈ 0 for a hollowed-out team');
{
  const hollow = E.computeSurvivability(C, Object.assign(E.initState(C), { reputation: 55, installed_base: 800 }),
    E.parseDecisions({ crews_retained: '10', pivot_cni: '0', pivot_om: '50', pivot_harvest: '50' }));
  const healthy = E.computeSurvivability(C, Object.assign(E.initState(C), { reputation: 120, installed_base: 6000 }),
    E.parseDecisions({ crews_retained: '20', pivot_cni: '40', pivot_om: '60', pivot_harvest: '0' }));
  ok('hollow team survivability is small', hollow.survivability < 10, 'hollow=' + hollow.survivability);
  ok('hollow ≪ healthy', hollow.survivability < healthy.survivability * 0.25, 'hollow=' + hollow.survivability + ' healthy=' + healthy.survivability);
  ok('hollow team fails the C&I gate (rep<90)', hollow.cni_gate === false);
}

console.log('\n(i) two-axis: task_weight + people_weight always sum to 100');
{
  let allSum = true;
  for (const tw of [0, 10, 33, 50, 67, 90, 100]) {
    const r = E.computeTwoAxisScore(80, 40, tw);
    if (r.task_weight + r.people_weight !== 100) { allSum = false; }
  }
  ok('weights sum to 100 across tw ∈ {0,10,33,50,67,90,100}', allSum);
  const r = E.computeTwoAxisScore(80, 40, 70); // 80*.7 + 40*.3 = 56 + 12 = 68
  ok('composite = task·tw + people·pw', approx(r.composite, 68), 'got ' + r.composite);
  ok('task/people passed through unweighted', r.task === 80 && r.people === 40);
}

console.log('\n(j) quadrant classification at boundary values (hi 65 / lo 45)');
{
  ok('(65,65) → Catalyst', E.classifyQuadrant(65, 65) === 'Catalyst');
  ok('(65,45) → Executor', E.classifyQuadrant(65, 45) === 'Executor');
  ok('(45,65) → Connector', E.classifyQuadrant(45, 65) === 'Connector');
  ok('(45,45) → Passenger', E.classifyQuadrant(45, 45) === 'Passenger');
  ok('(64,64) → Balancer (below hi, above lo)', E.classifyQuadrant(64, 64) === 'Balancer');
  ok('(46,46) → Balancer (above lo, below hi)', E.classifyQuadrant(46, 46) === 'Balancer');
  ok('(65,46) → Balancer (hi task, mid people)', E.classifyQuadrant(65, 46) === 'Balancer');
  ok('getQuadrantLabel returns description', E.getQuadrantLabel(65, 65).description.length > 0);
}

console.log('\n(f) questionnaire scores sum + normalise correctly (real key)');
{
  const KEY = E.DARE_SCORING_KEY;
  const resp = {}; for (let i = 1; i <= 15; i++) resp['Q' + i] = ['A', 'B', 'C'][i % 3];
  // recompute raw + max independently from the key, then compare to the engine
  const raw = { D: 0, A: 0, R: 0, E: 0 }, max = { D: 0, A: 0, R: 0, E: 0 };
  for (const q of Object.keys(KEY.questions)) {
    const qd = KEY.questions[q];
    for (const d of ['D', 'A', 'R', 'E']) {
      max[d] += Math.max(...Object.keys(qd.optionScores).map(o => qd.optionScores[o][d]));
      raw[d] += qd.optionScores[resp[q]][d];
    }
  }
  const r = E.scoreQuestionnaire(resp);
  ok('raw domain sums match the key', ['D', 'A', 'R', 'E'].every(d => r.domainRaw[d] === raw[d]), JSON.stringify(r.domainRaw));
  ok('normalised = round(raw/max·100)', ['D', 'A', 'R', 'E'].every(d => r.domainScores[d] === Math.round(raw[d] / max[d] * 100)), JSON.stringify(r.domainScores));
  ok('proficiency L1/L2/L3 assigned', ['D', 'A', 'R', 'E'].every(d => ['L1', 'L2', 'L3'].includes(r.proficiency[d])));
  ok('dominant/growth-edge domains identified', !!r.dominantDomain && !!r.growthEdgeDomain);
}

console.log('\n(g) contradiction pair Q2↔Q11 fires on inconsistent responses (real key)');
{
  const B = {}; for (let i = 1; i <= 15; i++) B['Q' + i] = 'C'; // neutral, fires nothing
  const cp1 = f => f.id === 'CP1';
  const inc = E.scoreQuestionnaire({ ...B, Q2: 'A', Q11: 'B' }); // contradicts.A = ['B'] → fires
  ok('CP1 (Q2↔Q11) fires when Q2=A, Q11=B', inc.contradictionFlags.find(cp1).fired);
  const con = E.scoreQuestionnaire({ ...B, Q2: 'A', Q11: 'A' }); // 'A' not in ['B'] → no fire
  ok('CP1 does NOT fire when Q2=A, Q11=A', !con.contradictionFlags.find(cp1).fired);
}

console.log('\n(h) consistency index maps to 0/1/2/3-4 flag counts (real key)');
{
  const C = {}; for (let i = 1; i <= 15; i++) C['Q' + i] = 'C'; C.Q15 = 'C'; // 0 flags
  ok('0 flags → High', (() => { const r = E.scoreQuestionnaire(C); return r.flagCount === 0 && r.consistencyIndex === 'High'; })());
  const two = { ...C, Q2: 'A', Q11: 'B', Q4: 'A', Q13: 'B' }; // CP1 + CP2 (Q15='C' keeps CP4 off)
  const r2 = E.scoreQuestionnaire(two);
  ok('2 flags → Moderate', r2.flagCount === 2 && r2.consistencyIndex === 'Moderate', 'flags=' + r2.flagCount);
  const three = { ...two, Q6: 'A', Q14: 'B' }; // + CP3
  const r3 = E.scoreQuestionnaire(three);
  ok('3 flags → Low', r3.flagCount === 3 && r3.consistencyIndex === 'Low', 'flags=' + r3.flagCount);
  const four = { ...three, Q15: 'B' }; // + CP4 (Q2=A contradicts ['B'])
  const r4 = E.scoreQuestionnaire(four);
  ok('4 flags → Low', r4.flagCount === 4 && r4.consistencyIndex === 'Low', 'flags=' + r4.flagCount);
}

console.log('\n──────────────────────────────');
console.log('  PASS ' + pass + '   FAIL ' + fail);
process.exit(fail ? 1 : 0);
