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

console.log('\n──────────────────────────────');
console.log('  PASS ' + pass + '   FAIL ' + fail);
process.exit(fail ? 1 : 0);
