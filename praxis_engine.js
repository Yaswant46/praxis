/* =============================================================================
 * praxis_engine.js — Suryan Energy competitive resolution engine
 *
 * Pure, data-driven functions. Every number lives in SURYAN_CONFIG (below);
 * the functions read from the config object passed in — no hardcoded magic
 * numbers. Works in the browser (attaches window.PraxisEngine + window.SURYAN_CONFIG)
 * and in Node (module.exports) so tests/engine.test.js can import it.
 *
 * App-round mapping: app-round 1 = Round 0 (posture, no resolution);
 * app-rounds 2..5 = spec rounds R1..R4.
 * ---------------------------------------------------------------------------*/

(function (root) {
  'use strict';

  // ── CONFIG (single source of truth; also seeded into cases.config) ─────────
  var SURYAN_CONFIG = {
    start: {
      resi_ticket: 2.0, cni_rev_base: 28, cash_start: 18, wc_limit: 12, wc_rate: 0.14,
      crews_start: 22, crew_capacity: 21, crew_wage_base: 9.0, material_pct: 0.55,
      overhead_qtr: 2.2, reputation_start: 100, trust_start: 100, morale_start: 70,
    },
    subsidy: { ticket_subsidy: 0.8, customer_pct: 0.60 },
    // per app-round demand pool PER TEAM (× n_teams = shared pool)
    pool_per_team: { 2: 3000, 3: 3500, 4: 2500, 5: 1500 },
    demand: { price_elasticity: -1.5, rep_weight: 0.8, channel_weight: 0.3, channel_ref: 2.0 },
    auction: {
      new_crews: { 2: 8, 3: 6, 4: 4, 5: 0 }, floor_bid_r1: 9.5, wage_contagion: 0.5,
      subcontract_cost: 7.5, wage_macro_floor: { 3: 1.30 }, // R2 (app-round 3): index ≥ base×1.30
    },
    tier1: { base_cover: 0.5, bid_span: 8, tier2_defect: 0.02 },
    defects: {
      base: 0.02, subcontract_coeff: 0.06, util_penalty: 0.03, util_penalty_at: 0.95,
      quality_credit_per_halfcr: 0.015, credit_cap: 0.045, floor: 0.005, rework_cost_per: 0.6,
    },
    attrition: {
      base: 0.05, posture: { command: 0.04, coach: -0.01, steward: -0.03 },
      stressed_util: 0.90, stressed_morale: 60, defer_penalty: 0.15, retention_credit: 0.02,
      retention_min_cr: 0.5,
    },
    reputation: {
      min: 0, max: 150, defect_pp_over3: -2, salary_defer: -15, vendor_delay: -8,
      recall_now: -3, recall_next: 5, deny_leak_delta: -12, safety_mishandle: -10,
      paid_through_crunch: 8, keep_supervisor_exposed: -10,
    },
    trust: { min: 0, max: 150, aligned: 10, partial: 0, contradicted: -15,
      switch_morale: -10, switch_attrition: 0.05, prod_lo: 0.85, prod_hi: 1.15, coach_bonus: 1.05 },
    morale: { min: 0, max: 100, retention: 5, salary_defer: -25, layoff: -20, recall_open: 5 },
    leak_probabilities: { quiet_fix: 0.5, deny: 0.7, keep_supervisor: 0.7 },
    crunch: {
      wc_tighten_to: 8, cash_gap_scaler: 1.0, distress_release_frac: 0.30, poach_min_mult: 1.3,
      acquire_book_min_cash: 6, acquire_book_frac: 0.70,
    },
    r4: {
      audit_penalty_base: 0.05, audit_penalty_per_pp: 0.02, audit_cap: 0.15, sunset_pool_pct: 0.30,
      acq_multiple: 1.2, om_rev_per_install_cr: 0.0006, conversion_floor: 0.05, conversion_cap: 0.60,
      conversion_rep_base: 60, cni_rep_gate: 90, cni_crews_gate: 15, cni_multiplier: 1.5,
      capability_value_per_crew: 0.25,
    },
    scoring: { financial: 0.40, survivability: 0.25, trust: 0.20, reputation: 0.15, dilution_haircut: 0.20 },
    // incident alignment vs declared posture → 'aligned' | 'partial' | 'contradicted'
    incidents: {
      li1: {
        back_ops:   { command: 'contradicted', coach: 'partial',      steward: 'aligned' },
        overrule:   { command: 'aligned',      coach: 'partial',      steward: 'contradicted' },
        ownership:  { command: 'partial',      coach: 'aligned',      steward: 'partial' },
        split:      { command: 'contradicted', coach: 'contradicted', steward: 'contradicted' },
      },
      li2: {
        fire_public:{ command: 'partial',      coach: 'partial',      steward: 'aligned' },
        quiet:      { command: 'contradicted', coach: 'contradicted', steward: 'contradicted' },
        rebuild:    { command: 'partial',      coach: 'aligned',      steward: 'partial' },
        keep:       { command: 'partial',      coach: 'contradicted', steward: 'contradicted' },
      },
      li3: {
        crews:      { command: 'partial',      coach: 'partial',      steward: 'aligned' },
        bank:       { command: 'partial',      coach: 'contradicted', steward: 'contradicted' },
        vendor:     { command: 'contradicted', coach: 'partial',      steward: 'partial' },
        defer:      { command: 'contradicted', coach: 'contradicted', steward: 'contradicted' },
      },
    },
  };

  // ── small helpers ──────────────────────────────────────────────────────────
  function clamp(x, lo, hi) { return Math.max(lo, Math.min(hi, x)); }
  function num(v, d) { var n = parseFloat(v); return isNaN(n) ? (d || 0) : n; }
  function round2(x) { return Math.round((x + Number.EPSILON) * 100) / 100; }

  // deterministic seeded RNG (mulberry32) so leak rolls are reproducible in tests
  function makeRng(seed) {
    var a = seed >>> 0;
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function hashStr(s) { var h = 2166136261; for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }

  // ── decision parsing: stored TEXT/number → mechanical value ─────────────────
  function parsePosture(v) {
    var s = (v || '').toLowerCase();
    if (s.indexOf('command') === 0 || s.indexOf('command') > -1) return 'command';
    if (s.indexOf('coach') > -1) return 'coach';
    if (s.indexOf('steward') > -1) return 'steward';
    return null;
  }
  function parseDecisions(raw) {
    raw = raw || {};
    var s = function (k) { return (raw[k] || '').toString().toLowerCase(); };
    var li1 = s('li1'), li2 = s('li2'), pay = s('payment_priority'), qr = s('quality_response');
    var cap = s('emergency_capital'), pace = s('install_pace'), hc = s('headcount_action'), acq = s('acquisition');
    return {
      posture: parsePosture(raw.posture),
      hire_count: num(raw.hire_crews_bid_count), hire_wage: num(raw.hire_crews_bid_wage),
      subcontract: num(raw.subcontract_crews), tier1_premium: num(raw.tier1_premium_bid),
      ration: s('ration_demand').indexOf('ration') > -1,
      price_index: num(raw.price_index, 1.0), channel_spend: num(raw.channel_spend),
      quality_invest: num(raw.quality_invest), retention_spend: num(raw.retention_spend),
      training_invest: num(raw.training_invest),
      li1_key: li1.indexOf('back the ops') > -1 ? 'back_ops' : li1.indexOf('overrule') > -1 ? 'overrule'
        : li1.indexOf('ownership') > -1 ? 'ownership' : li1.indexOf('split') > -1 ? 'split' : null,
      li2_key: li2.indexOf('fire') > -1 ? 'fire_public' : li2.indexOf('quiet') > -1 ? 'quiet'
        : li2.indexOf('demote') > -1 || li2.indexOf('rebuild') > -1 ? 'rebuild' : li2.indexOf('keep') > -1 ? 'keep' : null,
      quality_response: qr.indexOf('recall') > -1 ? 'recall_rework' : qr.indexOf('quiet') > -1 ? 'quiet_fix'
        : qr.indexOf('deny') > -1 ? 'deny' : null,
      payment_priority: pay.indexOf('crews first') > -1 ? 'crews' : pay.indexOf('bank first') > -1 ? 'bank'
        : pay.indexOf('vendors first') > -1 ? 'vendor' : pay.indexOf('defer') > -1 ? 'defer' : null,
      emergency_capital: cap.indexOf('dilution') > -1 || cap.indexOf('equity') > -1 ? 'dilution'
        : cap.indexOf('bridge') > -1 ? 'bridge' : 'none',
      install_pace: pace.indexOf('slow') > -1 ? 'slow_50' : 'full',
      headcount_action: hc.indexOf('furlough') > -1 ? 'furlough' : hc.indexOf('pay cut') > -1 ? 'paycut_20'
        : hc.indexOf('layoff') > -1 ? 'layoff_20pct' : 'hold',
      poach_bid: num(raw.poach_bid),
      acquire_book: s('acquire_book').indexOf('yes') > -1,
      pivot_cni: num(raw.pivot_cni), pivot_om: num(raw.pivot_om), pivot_harvest: num(raw.pivot_harvest),
      crews_retained: num(raw.crews_retained), acquisition: acq.indexOf('sell') > -1 ? 'sell'
        : acq.indexOf('negotiate') > -1 ? 'negotiate' : 'decline',
    };
  }

  // ── initial per-team state ──────────────────────────────────────────────────
  function initState(config) {
    var st = config.start;
    return {
      cash: st.cash_start, crews: st.crews_start, reputation: st.reputation_start,
      trust: st.trust_start, morale: st.morale_start, wage_index: st.crew_wage_base,
      receivables: 0, installed_base: 0, cumulative_fcf: 0, last_ebitda: 0,
      defect_pending: null, lifetime_defect_installs: 0, lifetime_installs: 0,
      distressed: false, coach_rounds: 0, took_dilution: false, last_utilization: 0,
      last_captured: 0, survivability: 0,
    };
  }

  // ── §4 crew auction (cross-team, sealed high-bid) ──────────────────────────
  function resolveAuction(config, round, bids) {
    var avail = (config.auction.new_crews[round] || 0);
    var slots = [];
    bids.forEach(function (b) { for (var i = 0; i < b.count; i++) slots.push({ id: b.id, wage: b.wage }); });
    slots.sort(function (x, y) { return y.wage - x.wage || (x.id < y.id ? -1 : 1); });
    var won = {}, winWages = [];
    for (var i = 0; i < slots.length && i < avail; i++) {
      won[slots[i].id] = (won[slots[i].id] || 0) + 1;
      winWages.push(slots[i].wage);
    }
    var avg = winWages.length ? winWages.reduce(function (a, b) { return a + b; }, 0) / winWages.length : null;
    return { crewsWon: won, avgWinningBid: avg };
  }

  // ── §4 wage inflation contagion (session-level, monotonic non-decreasing) ──
  function computeWageIndex(config, prevIndex, avgWinningBid, round) {
    var idx = prevIndex;
    if (avgWinningBid != null) {
      var moved = prevIndex * (1 + config.auction.wage_contagion * (avgWinningBid / prevIndex - 1));
      idx = Math.max(prevIndex, moved);
    }
    var macro = config.auction.wage_macro_floor[round];
    if (macro) idx = Math.max(idx, config.start.crew_wage_base * macro);
    return round2(idx);
  }

  // ── §5 productivity multiplier ─────────────────────────────────────────────
  function productivityMult(config, trust, coachRounds) {
    var t = config.trust;
    return clamp(trust / 100, t.prod_lo, t.prod_hi) * Math.pow(t.coach_bonus, coachRounds || 0);
  }

  // ── §3 capacity ────────────────────────────────────────────────────────────
  function computeCapacity(config, ownCrews, subCrews, prodMult) {
    return (ownCrews + subCrews) * config.start.crew_capacity * prodMult;
  }

  // ── §3 demand allocation (cross-team, one redistribution pass) ─────────────
  function allocateDemand(config, round, teams) {
    // teams: [{id, price_index, reputation, channel_spend, capacity}]
    var d = config.demand;
    var pool = (config.pool_per_team[round] || 0) * teams.length;
    var attrs = teams.map(function (t) {
      var a = Math.pow(t.price_index, d.price_elasticity) *
        Math.pow(Math.max(0.01, t.reputation) / 100, d.rep_weight) *
        Math.pow(1 + t.channel_spend / d.channel_ref, d.channel_weight);
      return { id: t.id, attr: a, cap: t.capacity, captured: 0 };
    });
    var sum = attrs.reduce(function (a, x) { return a + x.attr; }, 0) || 1;
    attrs.forEach(function (x) { x.captured = Math.min(x.cap, (x.attr / sum) * pool); });
    // redistribute unserved to teams with spare capacity, pro-rata by spare, one pass
    var served = attrs.reduce(function (a, x) { return a + x.captured; }, 0);
    var unserved = Math.max(0, pool - served);
    if (unserved > 0.01) {
      var spareTotal = attrs.reduce(function (a, x) { return a + Math.max(0, x.cap - x.captured); }, 0);
      if (spareTotal > 0.01) {
        attrs.forEach(function (x) {
          var spare = Math.max(0, x.cap - x.captured);
          x.captured += Math.min(spare, unserved * (spare / spareTotal));
        });
      }
    }
    var out = {};
    attrs.forEach(function (x) { out[x.id] = Math.floor(x.captured); });
    return out;
  }

  // ── §5 defect rate for THIS round (surfaces next round) ────────────────────
  function computeDefects(config, subShare, utilization, tier2, qualityInvestCr) {
    var c = config.defects;
    var r = c.base + c.subcontract_coeff * subShare;
    if (utilization > c.util_penalty_at) r += c.util_penalty;
    if (tier2) r += config.tier1.tier2_defect;
    var credit = Math.min(c.credit_cap, (qualityInvestCr / 0.5) * c.quality_credit_per_halfcr);
    r -= credit;
    return Math.max(c.floor, r);
  }

  // ── §5 attrition rate ──────────────────────────────────────────────────────
  function computeAttrition(config, posture, stressed, deferred, retentionCr, switched) {
    var a = config.attrition;
    var r = a.base + (a.posture[posture] || 0) * (stressed ? 1 : 1); // posture modifier
    if (deferred) r += a.defer_penalty;
    if (retentionCr >= a.retention_min_cr) r -= a.retention_credit;
    if (switched) r += config.trust.switch_attrition;
    return Math.max(0, r);
  }

  // ── §6 cash walk for one team/round ────────────────────────────────────────
  function cashWalk(config, state, d, ctx) {
    // ctx: { round, captured, crews, subCrews, reworkCr, wageIndex, subsidyFrozen, wcLimit, tier1Premium }
    var st = config.start, sub = config.subsidy;
    var installs = ctx.captured;
    var ticket = st.resi_ticket;
    var revenue = installs * ticket + st.cni_rev_base; // ₹Cr (installs are in ₹Cr-scaled? see note)
    // NOTE: installs × ticket is in ₹L·count → convert: ticket is ₹L, so revenue_resi(₹Cr)=installs*ticket/100
    var revenue_resi_cr = installs * ticket / 100;
    revenue = revenue_resi_cr + st.cni_rev_base;

    var customerCashIn = installs * (sub.customer_pct * ticket) / 100; // 60% collected now
    var subsidyAccrued = installs * sub.ticket_subsidy / 100;          // 40% → receivable (T+60)

    // costs (₹Cr)
    var materials = installs * (st.material_pct * ticket) / 100 * (1 + (ctx.tier1Premium || 0) / 100);
    var crewWages = ctx.crews * ctx.wageIndex / 100;
    var subCost = ctx.subCrews * config.auction.subcontract_cost / 100;
    var overhead = st.overhead_qtr;
    var discretionary = d.channel_spend + d.quality_invest + d.retention_spend + d.training_invest;
    var rework = ctx.reworkCr || 0;

    var costs = materials + crewWages + subCost + overhead + discretionary + rework;
    var ebitda = revenue - costs;

    // collect prior receivable unless frozen
    var collected = ctx.subsidyFrozen ? 0 : state.receivables;
    var receivables_end = ctx.subsidyFrozen ? state.receivables + subsidyAccrued : subsidyAccrued;

    // emergency capital
    var capIn = 0;
    if (d.emergency_capital === 'dilution') capIn = 15;
    else if (d.emergency_capital === 'bridge') capIn = 0; // debt drawn as needed via WC-like; interest below

    var cashIn = customerCashIn + collected + capIn;
    var cashOut = costs; // materials/wages/etc paid this round (simplified vendor terms)
    var cashBefore = state.cash + cashIn - cashOut;

    // working-capital line covers a shortfall up to wcLimit; interest on drawn
    var wcDrawn = cashBefore < 0 ? Math.min(ctx.wcLimit, -cashBefore) : 0;
    var bridgeRate = d.emergency_capital === 'bridge' ? 0.24 : st.wc_rate;
    var interest = wcDrawn * bridgeRate / 4; // quarterly
    var cash_end = cashBefore + wcDrawn - interest;

    var fcf = ebitda - interest;
    return {
      revenue: round2(revenue), ebitda: round2(ebitda), fcf: round2(fcf),
      cash_end: round2(cash_end), receivables_end: round2(receivables_end),
      collected: round2(collected), wcDrawn: round2(wcDrawn), interest: round2(interest),
      cash_gap: round2(Math.max(0, -cashBefore)),
    };
  }

  // ── §6 R4 survivability ────────────────────────────────────────────────────
  function computeSurvivability(config, state, d) {
    var r = config.r4;
    var conversion = clamp((state.reputation - r.conversion_rep_base) / 100, r.conversion_floor, r.conversion_cap);
    var om = state.installed_base * r.om_rev_per_install_cr * conversion;
    var gate = state.reputation >= r.cni_rep_gate && d.crews_retained >= r.cni_crews_gate;
    var cni = gate ? config.start.cni_rev_base * r.cni_multiplier : 0;
    var capability = d.crews_retained * r.capability_value_per_crew;
    // weight by pivot allocation toward om + cni (harvest sacrifices survivability)
    var total = pivotNorm(d);
    var omW = total.om, cniW = total.cni;
    var surv = om * (0.5 + omW / 2) + cni * (0.5 + cniW / 2) + capability;
    return { survivability: round2(surv), conversion: round2(conversion), om_annuity: round2(om), cni_value: round2(cni), cni_gate: gate, capability: round2(capability) };
  }
  function pivotNorm(d) {
    var a = Math.max(0, d.pivot_cni), b = Math.max(0, d.pivot_om), c = Math.max(0, d.pivot_harvest);
    var s = a + b + c || 1;
    return { cni: a / s, om: b / s, harvest: c / s };
  }

  // ── §7 final weighted scores (End Session) ─────────────────────────────────
  function computeFinalScores(config, teams) {
    var sc = config.scoring;
    var finRaw = teams.map(function (t) { return (t.state.cumulative_fcf || 0) + (t.state.last_ebitda || 0); });
    var maxFin = Math.max.apply(null, finRaw.concat([0.0001]));
    var maxSurv = Math.max.apply(null, teams.map(function (t) { return t.state.survivability || 0; }).concat([0.0001]));
    return teams.map(function (t, i) {
      var fin = clamp(finRaw[i] / maxFin, 0, 1);
      if (t.state.took_dilution) fin *= (1 - sc.dilution_haircut);
      var surv = clamp((t.state.survivability || 0) / maxSurv, 0, 1);
      var trust = clamp((t.state.trust || 0) / 150, 0, 1);
      var rep = clamp((t.state.reputation || 0) / 150, 0, 1);
      var total = fin * sc.financial + surv * sc.survivability + trust * sc.trust + rep * sc.reputation;
      return { id: t.id, financial: round2(fin), survivability: round2(surv), trust: round2(trust),
        reputation: round2(rep), total: round2(total * 100) };
    }).sort(function (a, b) { return b.total - a.total; });
  }

  // ── incident alignment → trust tag ─────────────────────────────────────────
  function incidentTag(config, round, posture, d) {
    if (!posture) return null;
    if (round === 2 && d.li1_key) return config.incidents.li1[d.li1_key][posture];
    if (round === 3 && d.li2_key) return config.incidents.li2[d.li2_key][posture];
    if (round === 4 && d.payment_priority) return config.incidents.li3[d.payment_priority][posture];
    if (round === 5) {
      // LI-4: coherence of pivot + crews retained vs posture
      var p = pivotNorm(d);
      if (posture === 'steward') return (d.crews_retained >= config.r4.cni_crews_gate && p.harvest < 0.5) ? 'aligned' : 'partial';
      if (posture === 'coach') return (p.om >= 0.33 && d.crews_retained >= config.r4.cni_crews_gate) ? 'aligned' : 'partial';
      if (posture === 'command') return (p.harvest >= 0.4 || d.acquisition === 'sell') ? 'aligned' : 'partial';
    }
    return null;
  }

  // ── ORCHESTRATOR ────────────────────────────────────────────────────────────
  // resolveRound: pure. Returns { teams:[{id,name,posture,state,outcome,detail}], news:[...] }
  function resolveRound(args) {
    var config = args.config || SURYAN_CONFIG;
    var round = args.round;             // app-round 2..5
    var rngRoot = args.rng || null;
    var teams = args.teams.map(function (t) {
      return { id: t.id, name: t.name, posture: t.posture || (t.state && t.state.posture) || null,
        posture_switched: !!t.posture_switched, state: Object.assign(initState(config), t.state || {}) };
    });
    var decisions = {};
    teams.forEach(function (t) { decisions[t.id] = parseDecisions((args.decisions || {})[t.id] || {}); });

    var news = [];
    var addNews = function (teamId, headline, detail, repDelta) {
      news.push({ team_id: teamId, headline: headline, detail: detail || '', reputation_delta: repDelta || 0 });
    };

    // Phase A — auction
    var bids = teams.map(function (t) { return { id: t.id, count: Math.round(decisions[t.id].hire_count), wage: decisions[t.id].hire_wage }; });
    var auction = resolveAuction(config, round, bids);

    // Phase B — session wage index
    var prevIndex = teams[0].state.wage_index;
    var wageIndex = computeWageIndex(config, prevIndex, auction.avgWinningBid, round);
    if (wageIndex > prevIndex) addNews(null, 'Wage index rises to ₹' + wageIndex + 'L/qtr', 'Auction bidding pushed the market crew wage up — every team’s payroll drifts to the new index.', 0);

    // Phase C — apply auction wins, persist session wage index, compute capacity
    teams.forEach(function (t) {
      var d = decisions[t.id];
      t.state.wage_index = wageIndex; // contagion: all teams drift to new index
      t.state.crews += (auction.crewsWon[t.id] || 0);
      t._prod = productivityMult(config, t.state.trust, t.state.coach_rounds);
      t._subCrews = Math.round(d.subcontract);
      t._capacity = computeCapacity(config, t.state.crews, t._subCrews, t._prod);
    });

    // Phase D — demand allocation (cross-team)
    var demandTeams = teams.map(function (t) {
      var d = decisions[t.id];
      var capForShare = decisions[t.id].ration ? t._capacity * 0.8 : t._capacity;
      return { id: t.id, price_index: d.price_index, reputation: t.state.reputation, channel_spend: d.channel_spend, capacity: capForShare };
    });
    var captured = allocateDemand(config, round, demandTeams);

    // Phase E/F/G — per team
    teams.forEach(function (t) {
      var d = decisions[t.id], st = t.state;
      var rng = makeRng(hashStr((t.id || 'x') + ':' + round) ^ (rngRoot ? 0 : 0));
      var cap = captured[t.id];
      var util = t._capacity > 0 ? cap / t._capacity : 0;
      var subShare = (t.state.crews + t._subCrews) > 0 ? t._subCrews / (t.state.crews + t._subCrews) : 0;
      var repDelta = 0, moraleDelta = 0, trustDelta = 0, events = [];

      // reveal PRIOR round's pending defects (1-round lag)
      var reworkCr = 0;
      if (st.defect_pending) {
        var pr = st.defect_pending;
        var defectInstalls = pr.rate * pr.installs;
        reworkCr = defectInstalls * config.defects.rework_cost_per / 100;
        var ppOver = Math.max(0, pr.rate * 100 - 3);
        if (ppOver > 0) {
          var rd = config.reputation.defect_pp_over3 * ppOver;
          repDelta += rd;
          addNews(t.id, t.name + ' defect rate ' + (pr.rate * 100).toFixed(1) + '%', 'Round ' + (round - 2) + ' installs showed quality issues — ' + Math.round(defectInstalls) + ' reworks. Reputation ' + Math.round(rd) + '.', Math.round(rd));
        }
      }

      // tier2 usage → this round's defect pending
      var tier1Cover = config.tier1.base_cover + (1 - config.tier1.base_cover) * (d.tier1_premium / config.tier1.bid_span);
      var tier2 = cap > t._capacity * tier1Cover;
      var newDefectRate = computeDefects(config, subShare, util, tier2, d.quality_invest);
      st.defect_pending = { rate: newDefectRate, installs: cap };
      st.lifetime_defect_installs += newDefectRate * cap;
      st.lifetime_installs += cap;

      // cash walk
      var frozen = (round === 4); // spec R3 subsidy freeze
      var wcLimit = round >= 4 ? config.crunch.wc_tighten_to : config.start.wc_limit;
      var walk = cashWalk(config, st, d, { round: round, captured: cap, crews: st.crews, subCrews: t._subCrews,
        reworkCr: reworkCr, wageIndex: wageIndex, subsidyFrozen: frozen, wcLimit: wcLimit, tier1Premium: d.tier1_premium });

      // R4: release frozen receivables minus audit penalty
      var auditNote = null;
      if (round === 5 && st.receivables > 0) {
        var lifeRate = st.lifetime_installs > 0 ? st.lifetime_defect_installs / st.lifetime_installs : 0;
        var ppOverLife = Math.max(0, lifeRate * 100 - 3);
        var pen = Math.min(config.r4.audit_cap, config.r4.audit_penalty_base + config.r4.audit_penalty_per_pp * ppOverLife);
        var released = st.receivables * (1 - pen);
        walk.cash_end = round2(walk.cash_end + released);
        walk.receivables_end = 0;
        auditNote = { penalty: pen, released: round2(released) };
      }

      // ── reputation/trust/morale events ──
      // payment behavior (R3 crunch)
      var deferred = false;
      if (round === 4) {
        if (d.payment_priority === 'defer') { deferred = true; repDelta += config.reputation.salary_defer; moraleDelta += config.morale.salary_defer; addNews(t.id, t.name + ' defers payroll', 'Chose to defer payments in the crunch — flagged distressed.', config.reputation.salary_defer); }
        else if (d.payment_priority === 'vendor' || d.payment_priority === 'bank') { /* crews paid */ }
        if (d.headcount_action === 'layoff_20pct') { moraleDelta += config.morale.layoff; addNews(t.id, t.name + ' cuts 20% of crews', 'Layoffs during the crunch.', 0); }
        else if (d.headcount_action === 'paycut_20') { deferred = true; moraleDelta += config.morale.salary_defer / 2; }
        if (d.payment_priority === 'crews' && d.emergency_capital !== 'none') { repDelta += config.reputation.paid_through_crunch; addNews(t.id, t.name + ' paid everyone on time', 'Honored payroll through the crunch (+reputation).', config.reputation.paid_through_crunch); }
      }
      // quality response (R2)
      if (round === 3 && d.quality_response) {
        if (d.quality_response === 'recall_rework') { repDelta += config.reputation.recall_now; moraleDelta += config.morale.recall_open; st._recallNext = true; }
        else if (d.quality_response === 'deny') { if (rng() < config.leak_probabilities.deny) { repDelta += config.reputation.deny_leak_delta; addNews(t.id, t.name + ' quality cover-up exposed', 'A denied defect issue leaked to the press.', config.reputation.deny_leak_delta); } }
      }
      if (st._recallNextPrev) { repDelta += config.reputation.recall_next; }
      // retention morale
      if (d.retention_spend >= config.attrition.retention_min_cr) moraleDelta += config.morale.retention;

      // incident trust tag
      var tag = incidentTag(config, round, t.posture, d);
      if (tag) {
        trustDelta += config.trust[tag];
        if (tag === 'contradicted') addNews(t.id, t.name + ' acts against its posture', 'Leadership response contradicted the declared ' + t.posture + ' posture (trust −' + Math.abs(config.trust.contradicted) + ').', 0);
      }
      // posture switch penalty
      if (t.posture_switched) { moraleDelta += config.trust.switch_morale; }

      // apply deltas
      st.reputation = clamp(st.reputation + repDelta, config.reputation.min, config.reputation.max);
      st.trust = clamp(st.trust + trustDelta, config.trust.min, config.trust.max);
      st.morale = clamp(st.morale + moraleDelta, config.morale.min, config.morale.max);
      st.coach_rounds = (t.posture === 'coach') ? st.coach_rounds + 1 : 0;

      // attrition
      var stressed = util > config.attrition.stressed_util || st.morale < config.attrition.stressed_morale;
      var attr = computeAttrition(config, t.posture, stressed, deferred, d.retention_spend, t.posture_switched);
      var lost = Math.round(st.crews * attr);
      st.crews = Math.max(0, st.crews - lost);
      st.distressed = deferred;

      // finalize financials into state
      st.cash = walk.cash_end;
      st.receivables = walk.receivables_end;
      st.installed_base += cap;
      st.cumulative_fcf = round2(st.cumulative_fcf + walk.fcf);
      st.last_ebitda = walk.ebitda;
      st.last_utilization = round2(util);
      st.last_captured = cap;
      if (d.emergency_capital === 'dilution') st.took_dilution = true;
      st._recallNextPrev = st._recallNext || false; delete st._recallNext;

      // R4 survivability
      var survDetail = null;
      if (round === 5) { survDetail = computeSurvivability(config, st, d); st.survivability = survDetail.survivability; }

      t.outcome = {
        // maps onto existing outcomes table typed columns
        revenue: walk.revenue, gross_margin: round2(st.last_ebitda && walk.revenue ? (walk.ebitda / walk.revenue) * 100 : 0),
        cash_runway: st.cash, market_share: cap, product_health: Math.round(st.reputation), team_capability: st.crews,
        score: null,
      };
      t.detail = {
        captured: cap, utilization: round2(util), crews: st.crews, sub_crews: t._subCrews,
        wage_index: wageIndex, defect_rate_next: round2(newDefectRate * 100), rework_cr: round2(reworkCr),
        cash_walk: walk, reputation: Math.round(st.reputation), trust: Math.round(st.trust), morale: Math.round(st.morale),
        incident_tag: tag, attrition_lost: lost, distressed: deferred, audit: auditNote, survivability: survDetail,
      };
    });

    // Phase G2 — poaching (R3 crunch, cross-team)
    if (round === 4) {
      var pool = 0, distressedTeams = teams.filter(function (t) { return t.state.distressed; });
      distressedTeams.forEach(function (t) { var rel = Math.round(t.state.crews * config.crunch.distress_release_frac); t._release = rel; pool += rel; });
      var poachers = teams.filter(function (t) { return decisions[t.id].poach_bid >= config.crunch.poach_min_mult * t.state.wage_index && decisions[t.id].poach_bid > 0; })
        .sort(function (a, b) { return decisions[b.id].poach_bid - decisions[a.id].poach_bid; });
      poachers.forEach(function (p) {
        if (pool <= 0) return;
        var take = Math.min(pool, Math.max(1, Math.round(decisions[p.id].poach_bid / 5)));
        take = Math.min(take, pool);
        p.state.crews += take; pool -= take;
        addNews(p.id, p.name + ' poaches ' + take + ' crews', 'Hired ' + take + ' crews from distressed rivals at ₹' + decisions[p.id].poach_bid + 'L/qtr.', 0);
      });
      // remove taken crews from distressed teams proportionally
      var totalRelease = distressedTeams.reduce(function (a, t) { return a + (t._release || 0); }, 0);
      var totalTaken = distressedTeams.reduce(function (a, t) { return a + (t._release || 0); }, 0) - pool;
      distressedTeams.forEach(function (t) {
        if (!totalRelease) return;
        var taken = Math.round(totalTaken * ((t._release || 0) / totalRelease));
        t.state.crews = Math.max(0, t.state.crews - taken);
      });
    }

    // clean transient fields
    teams.forEach(function (t) { delete t._prod; delete t._subCrews; delete t._capacity; });
    return { round: round, teams: teams, news: news };
  }

  // ── Workstream B: two-axis (Task/People) scoring + quadrant ─────────────────
  // Applies to ALL cases (not Suryan-specific). task_weight is GM-only and comes
  // from session_secrets — NEVER from participant-readable data. People weight is
  // always (100 − task_weight), computed. Composite is GM-view only; Task and
  // People are shown separately to participants.
  /**
   * Combine a Task score and People score into the GM composite using the
   * GM-only task weight. Returns task/people (participant-safe) plus the
   * composite + weights (GM-only).
   */
  function computeTwoAxisScore(taskScore, peopleScore, taskWeight) {
    var tw = clamp(Math.round(taskWeight), 0, 100);
    var pw = 100 - tw;
    var task = clamp(taskScore, 0, 100);
    var people = clamp(peopleScore, 0, 100);
    return {
      task: round2(task), people: round2(people),
      task_weight: tw, people_weight: pw,
      composite: round2(task * tw / 100 + people * pw / 100),
    };
  }

  // Backward-compatible label-only wrapper over the canonical getQuadrantLabel
  // (hi 65 / lo 45). GM-dashboard / scorecard only.
  function classifyQuadrant(task, people) {
    return getQuadrantLabel(task, people).label;
  }

  // ── Workstream B: individual leadership questionnaire (DARE) ────────────────
  // Real facilitator-provided scoring key (v1.0). Per-option, per-domain points;
  // answer-pattern contradiction pairs; insight lines + 90-day experiments.
  // Internal D/A/R/E letters + consistency/contradiction data are GM-only.
  // Participant-facing question + option copy (no domain letters shown).
  var QUESTIONNAIRE_CONTENT = {
    Q1: { type: 'Dispositional', text: 'In high-stakes situations, how do you typically arrive at a decision?', options: {
      A: 'I form a view quickly and refine it as information comes in.',
      B: 'I wait until I have enough information before committing.',
      C: 'I surface the key trade-off and decide based on which risk I\'m more willing to carry.',
    } },
    Q2: { type: 'Dispositional', text: 'When your team is moving toward a decision you\'re unsure about, you:', options: {
      A: 'Voice your doubt clearly, even if it slows things down.',
      B: 'Go along and course-correct later if needed.',
      C: 'Ask one sharp question that forces the team to examine the assumption.',
    } },
    Q3: { type: 'Simulation', text: 'During the simulation, when a teammate was quiet or disengaged, you:', options: {
      A: 'Noticed but stayed focused on the decision at hand.',
      B: 'Paused to check in with them, even if it cost time.',
      C: 'Brought them in by asking for their view directly.',
    } },
    Q4: { type: 'Dispositional', text: 'What drives you most when executing on a plan?', options: {
      A: 'Hitting the outcome — the method is secondary.',
      B: 'Making sure the team is aligned and moving together.',
      C: 'Keeping the plan honest — adjusting when the data says to.',
    } },
    Q5: { type: 'Simulation', text: 'In the rounds where your team had limited time, how did you make the call?', options: {
      A: 'I drove toward the most defensible option, even without consensus.',
      B: 'I deferred to the person who seemed most confident.',
      C: 'I tried to find the option that the team could collectively stand behind.',
    } },
    Q6: { type: 'Dispositional', text: 'When making decisions that affect others, you tend to:', options: {
      A: 'Factor in people impact as a key variable alongside the outcome.',
      B: 'Optimise for the outcome first, then manage the people side after.',
      C: 'Look for solutions where the outcome and people impact are both acceptable.',
    } },
    Q7: { type: 'Simulation', text: 'In rounds where the ethical path and the winning path were in tension, you:', options: {
      A: 'Chose what was right, even at the cost of the score.',
      B: 'Found a way to justify the winning move as acceptable.',
      C: 'Named the tension out loud but deferred to the team\'s call.',
    } },
    Q8: { type: 'Dispositional', text: 'After a poor outcome, your first instinct is to:', options: {
      A: 'Identify what went wrong and fix the input for next time.',
      B: 'Understand how the team is feeling before moving to solutions.',
      C: 'Accept it and focus entirely on the next opportunity.',
    } },
    Q9: { type: 'Dispositional', text: 'In group settings, when you disagree with the direction, you:', options: {
      A: 'State your position clearly, even knowing you might be outvoted.',
      B: 'Look for a middle position that keeps the group together.',
      C: 'Try to understand why others hold their view before advocating for yours.',
    } },
    Q10: { type: 'Simulation', text: 'Looking back at the simulation, the moments you felt most uncomfortable happened when:', options: {
      A: 'The team moved too fast without thinking through consequences.',
      B: 'We spent too long deliberating and lost clarity.',
      C: 'The right answer and the winning answer weren\'t the same thing.',
    } },
    Q11: { type: 'Dispositional', text: 'You are most uncomfortable when a leader:', options: {
      A: 'Moves too fast without hearing dissent.',
      B: 'Prolongs debate when the direction is already clear.',
      C: 'Bends their stated values when the stakes are high enough.',
    } },
    Q12: { type: 'Simulation', text: 'In rounds where your team disagreed, how did you handle it?', options: {
      A: 'I pushed for the view I believed was right.',
      B: 'I looked for the position that brought the team together.',
      C: 'I tried to understand why people held the views they did before advocating for mine.',
    } },
    Q13: { type: 'Simulation', text: 'Looking back at your team\'s decisions across all rounds — the ones you\'re least comfortable with happened because:', options: {
      A: 'We optimised too hard for the outcome and cut corners we shouldn\'t have.',
      B: 'We spent too long aligning and ran out of time to think clearly.',
      C: 'We didn\'t have enough information and made calls we couldn\'t fully stand behind.',
    } },
    Q14: { type: 'Dispositional', text: 'When you have more context than your team on something important, you:', options: {
      A: 'Share it fully and let the team decide with complete information.',
      B: 'Use it to steer the team toward what you believe is right.',
      C: 'Check whether the context genuinely changes the answer before raising it.',
    } },
    Q15: { type: 'Simulation', text: 'There was at least one moment in the simulation where you privately disagreed with your team\'s direction. What did you do?', options: {
      A: 'Said it clearly — my job is to put the right view on the table, not just to align.',
      B: 'Let it go — the team\'s call matters more than being right.',
      C: 'Raised it once, didn\'t push when it wasn\'t taken up, and committed to the direction.',
    } },
  };

  var DARE_SCORING_KEY = {
    version: '1.0',
    totalQuestions: 15,
    domains: ['D', 'A', 'R', 'E'],
    domainLabels: {
      D: 'Strategic Judgment', A: 'Execution Drive', R: 'People Leadership', E: 'Adaptive Integrity',
    },
    proficiencyLevels: {
      L1: { label: 'Reactive',    min: 0,  max: 45,  descriptor: 'Responds to the situation as it arrives. No deliberate pattern.' },
      L2: { label: 'Aware',       min: 46, max: 70,  descriptor: 'Recognises their default. Can name what\'s happening in the moment.' },
      L3: { label: 'Intentional', min: 71, max: 100, descriptor: 'Chooses their response. Can flex across styles with purpose.' },
    },
    contradictionPairs: [
      { id: 'CP1', q_a: 'Q2',  q_b: 'Q11', label: 'Dissent vs. Comfort with dissent',        contradicts: { A: ['B'], B: ['A'], C: [] } },
      { id: 'CP2', q_a: 'Q4',  q_b: 'Q13', label: 'Execution driver vs. Discomfort source',  contradicts: { A: ['B'], B: ['A'], C: [] } },
      { id: 'CP3', q_a: 'Q6',  q_b: 'Q14', label: 'People in decisions vs. Information power', contradicts: { A: ['B'], B: ['A'], C: [] } },
      { id: 'CP4', q_a: 'Q2',  q_b: 'Q15', label: 'Dissent in the moment vs. in hindsight',  contradicts: { A: ['B'], B: ['A'], C: ['B'] } },
    ],
    consistencyIndex: {
      High:     { maxFlags: 1, label: 'High',     descriptor: 'Responses are internally consistent. Profile is reliable.' },
      Moderate: { maxFlags: 2, label: 'Moderate', descriptor: 'Some tension in responses. Worth probing in debrief.' },
      Low:      { maxFlags: 4, label: 'Low',      descriptor: 'Significant internal contradiction. Self-perception gaps are large.' },
    },
    questions: {
      Q1:  { primaryDomain: 'D', secondaryDomain: null, type: 'dispositional', contradictionRole: [],                    optionScores: { A: { D: 2, A: 3, R: 1, E: 1 }, B: { D: 1, A: 1, R: 2, E: 2 }, C: { D: 3, A: 2, R: 1, E: 2 } } },
      Q2:  { primaryDomain: 'E', secondaryDomain: 'D',  type: 'dispositional', contradictionRole: ['CP1-q_a', 'CP4-q_a'], optionScores: { A: { D: 2, A: 1, R: 2, E: 3 }, B: { D: 1, A: 2, R: 1, E: 1 }, C: { D: 3, A: 2, R: 2, E: 2 } } },
      Q3:  { primaryDomain: 'R', secondaryDomain: null, type: 'simulation',    contradictionRole: [],                    optionScores: { A: { D: 1, A: 2, R: 1, E: 1 }, B: { D: 1, A: 1, R: 2, E: 2 }, C: { D: 2, A: 2, R: 3, E: 1 } } },
      Q4:  { primaryDomain: 'A', secondaryDomain: null, type: 'dispositional', contradictionRole: ['CP2-q_a'],           optionScores: { A: { D: 2, A: 3, R: 1, E: 1 }, B: { D: 1, A: 1, R: 3, E: 2 }, C: { D: 3, A: 2, R: 1, E: 3 } } },
      Q5:  { primaryDomain: 'D', secondaryDomain: null, type: 'simulation',    contradictionRole: [],                    optionScores: { A: { D: 3, A: 3, R: 1, E: 2 }, B: { D: 1, A: 1, R: 2, E: 1 }, C: { D: 2, A: 1, R: 3, E: 2 } } },
      Q6:  { primaryDomain: 'R', secondaryDomain: null, type: 'dispositional', contradictionRole: ['CP3-q_a'],           optionScores: { A: { D: 2, A: 2, R: 3, E: 3 }, B: { D: 2, A: 3, R: 1, E: 1 }, C: { D: 3, A: 2, R: 2, E: 2 } } },
      Q7:  { primaryDomain: 'E', secondaryDomain: null, type: 'simulation',    contradictionRole: [],                    optionScores: { A: { D: 2, A: 2, R: 2, E: 3 }, B: { D: 2, A: 3, R: 1, E: 1 }, C: { D: 1, A: 1, R: 2, E: 2 } } },
      Q8:  { primaryDomain: 'A', secondaryDomain: null, type: 'dispositional', contradictionRole: [],                    optionScores: { A: { D: 3, A: 3, R: 1, E: 2 }, B: { D: 1, A: 1, R: 3, E: 2 }, C: { D: 1, A: 2, R: 1, E: 1 } } },
      Q9:  { primaryDomain: 'R', secondaryDomain: null, type: 'dispositional', contradictionRole: [],                    optionScores: { A: { D: 3, A: 2, R: 1, E: 3 }, B: { D: 1, A: 1, R: 2, E: 1 }, C: { D: 2, A: 1, R: 3, E: 2 } } },
      Q10: { primaryDomain: 'E', secondaryDomain: null, type: 'simulation',    contradictionRole: [],                    optionScores: { A: { D: 2, A: 1, R: 2, E: 2 }, B: { D: 3, A: 3, R: 1, E: 1 }, C: { D: 2, A: 1, R: 2, E: 3 } } },
      Q11: { primaryDomain: 'D', secondaryDomain: null, type: 'dispositional', contradictionRole: ['CP1-q_b'],           optionScores: { A: { D: 2, A: 1, R: 2, E: 3 }, B: { D: 3, A: 3, R: 1, E: 1 }, C: { D: 2, A: 1, R: 2, E: 3 } } },
      Q12: { primaryDomain: 'R', secondaryDomain: null, type: 'simulation',    contradictionRole: [],                    optionScores: { A: { D: 3, A: 2, R: 1, E: 3 }, B: { D: 1, A: 1, R: 2, E: 1 }, C: { D: 2, A: 1, R: 3, E: 2 } } },
      Q13: { primaryDomain: 'A', secondaryDomain: 'E',  type: 'simulation',    contradictionRole: ['CP2-q_b'],           optionScores: { A: { D: 2, A: 1, R: 2, E: 3 }, B: { D: 3, A: 3, R: 1, E: 1 }, C: { D: 1, A: 2, R: 1, E: 2 } } },
      Q14: { primaryDomain: 'D', secondaryDomain: 'R',  type: 'dispositional', contradictionRole: ['CP3-q_b'],           optionScores: { A: { D: 2, A: 1, R: 3, E: 2 }, B: { D: 3, A: 3, R: 1, E: 1 }, C: { D: 3, A: 2, R: 2, E: 3 } } },
      Q15: { primaryDomain: 'R', secondaryDomain: 'E',  type: 'simulation',    contradictionRole: ['CP4-q_b'],           optionScores: { A: { D: 3, A: 2, R: 2, E: 3 }, B: { D: 1, A: 1, R: 3, E: 1 }, C: { D: 2, A: 2, R: 2, E: 3 } } },
    },
  };

  // Scores the 15-question questionnaire (see DARE_SCORING_KEY). Pure.
  function scoreQuestionnaire(responses) {
    responses = responses || {};
    var raw = { D: 0, A: 0, R: 0, E: 0 };
    var maxRaw = { D: 0, A: 0, R: 0, E: 0 };
    Object.keys(DARE_SCORING_KEY.questions).forEach(function (qId) {
      var qDef = DARE_SCORING_KEY.questions[qId];
      var answer = responses[qId];
      Object.keys(maxRaw).forEach(function (domain) {
        maxRaw[domain] += Math.max.apply(null, Object.keys(qDef.optionScores).map(function (o) { return qDef.optionScores[o][domain] || 0; }));
      });
      if (!answer || !qDef.optionScores[answer]) return;
      var scores = qDef.optionScores[answer];
      Object.keys(raw).forEach(function (domain) { raw[domain] += scores[domain] || 0; });
    });
    var domainScores = {};
    Object.keys(raw).forEach(function (d) { domainScores[d] = maxRaw[d] > 0 ? Math.round((raw[d] / maxRaw[d]) * 100) : 0; });
    var proficiency = {};
    Object.keys(domainScores).forEach(function (d) {
      var s = domainScores[d];
      proficiency[d] = s <= 45 ? 'L1' : s <= 70 ? 'L2' : 'L3';
    });
    var contradictionFlags = DARE_SCORING_KEY.contradictionPairs.map(function (pair) {
      var aA = responses[pair.q_a], aB = responses[pair.q_b];
      var fired = !!(aA && aB && pair.contradicts[aA] && pair.contradicts[aA].indexOf(aB) !== -1);
      return { id: pair.id, q_a: pair.q_a, q_b: pair.q_b, label: pair.label, fired: fired };
    });
    var flagCount = contradictionFlags.filter(function (f) { return f.fired; }).length;
    var consistencyIndex = flagCount <= 1 ? 'High' : flagCount <= 2 ? 'Moderate' : 'Low';
    var entries = Object.keys(domainScores).map(function (d) { return [d, domainScores[d]]; });
    var dominantDomain = entries.reduce(function (a, b) { return b[1] > a[1] ? b : a; })[0];
    var growthEdgeDomain = entries.reduce(function (a, b) { return b[1] < a[1] ? b : a; })[0];
    return { domainRaw: raw, domainScores: domainScores, proficiency: proficiency,
      contradictionFlags: contradictionFlags, flagCount: flagCount, consistencyIndex: consistencyIndex,
      dominantDomain: dominantDomain, growthEdgeDomain: growthEdgeDomain };
  }

  // Participant-facing insight for the lowest (growth-edge) domain. Scorecard only.
  function getInsightLine(growthEdgeDomain) {
    var lines = {
      D: 'Your instinct is to move with the group. Your edge will come from forming your own view first.',
      A: 'You think clearly but wait for permission to act. Start smaller and move sooner.',
      R: 'You optimise for the outcome. The next level requires seeing the person behind the decision.',
      E: 'You perform well under pressure. Watch what you\'re willing to flex when the stakes are highest.',
    };
    return lines[growthEdgeDomain] || '';
  }

  // Participant-facing 90-day experiment for the growth-edge domain. Scorecard only.
  function get90DayExperiment(growthEdgeDomain) {
    var experiments = {
      D: 'In your next cross-functional meeting, form a view before the discussion starts. State it early.',
      A: 'Pick one thing this week where you have enough information to move. Move without waiting for more.',
      R: 'In your next team interaction, name one stakeholder concern before making your recommendation.',
      E: 'Identify one value you hold as a leader. Write down what it would look like to compromise it. Use that as your line.',
    };
    return experiments[growthEdgeDomain] || '';
  }

  // Quadrant from Task/People scores (hi 65 / lo 45). GM dashboard + scorecard only.
  function getQuadrantLabel(taskScore, peopleScore) {
    var hi = 65, lo = 45;
    var taskHigh = taskScore >= hi, taskLow = taskScore <= lo;
    var pplHigh = peopleScore >= hi, pplLow = peopleScore <= lo;
    if (taskHigh && pplHigh) return { label: 'Catalyst',  description: 'High task focus, high people focus. The target.' };
    if (taskHigh && pplLow)  return { label: 'Executor',  description: 'Gets results. Risks burning people out.' };
    if (taskLow  && pplHigh) return { label: 'Connector', description: 'Strong on people. Delivery is the growth edge.' };
    if (taskLow  && pplLow)  return { label: 'Passenger', description: 'Disengaged on both axes.' };
    return { label: 'Balancer', description: 'Compromise-driven. Avoids extremes.' };
  }

  // GM-visible record for one participant. Strip GM-only fields before sending to
  // the participant scorecard view (contradictionFlags, consistencyIndex, etc.).
  function buildGMDashboardEntry(participantEmail, teamName, responses, taskScore, peopleScore) {
    var scored = scoreQuestionnaire(responses);
    var quadrant = getQuadrantLabel(taskScore, peopleScore);
    var lvl = DARE_SCORING_KEY.proficiencyLevels;
    var dom = function (letter) { return { score: scored.domainScores[letter], proficiency: scored.proficiency[letter], label: lvl[scored.proficiency[letter]].label }; };
    return {
      participant: participantEmail, team: teamName,
      domains: { strategicJudgment: dom('D'), executionDrive: dom('A'), peopleLeadership: dom('R'), adaptiveIntegrity: dom('E') },
      taskScore: taskScore, peopleScore: peopleScore, quadrant: quadrant.label, quadrantDescription: quadrant.description,
      consistencyIndex: scored.consistencyIndex, contradictionFlags: scored.contradictionFlags,
      dominantDomain: DARE_SCORING_KEY.domainLabels[scored.dominantDomain],
      growthEdgeDomain: DARE_SCORING_KEY.domainLabels[scored.growthEdgeDomain],
      insightLine: getInsightLine(scored.growthEdgeDomain),
      experiment90Day: get90DayExperiment(scored.growthEdgeDomain),
    };
  }

  var API = {
    SURYAN_CONFIG: SURYAN_CONFIG, parseDecisions: parseDecisions, parsePosture: parsePosture,
    initState: initState, resolveAuction: resolveAuction, computeWageIndex: computeWageIndex,
    productivityMult: productivityMult, computeCapacity: computeCapacity, allocateDemand: allocateDemand,
    computeDefects: computeDefects, computeAttrition: computeAttrition, cashWalk: cashWalk,
    computeSurvivability: computeSurvivability, computeFinalScores: computeFinalScores,
    incidentTag: incidentTag, resolveRound: resolveRound, clamp: clamp,
    computeTwoAxisScore: computeTwoAxisScore, classifyQuadrant: classifyQuadrant,
    // Workstream B — DARE questionnaire (real key v1.0)
    DARE_SCORING_KEY: DARE_SCORING_KEY, QUESTIONNAIRE_CONTENT: QUESTIONNAIRE_CONTENT,
    scoreQuestionnaire: scoreQuestionnaire,
    getInsightLine: getInsightLine, get90DayExperiment: get90DayExperiment,
    getQuadrantLabel: getQuadrantLabel, buildGMDashboardEntry: buildGMDashboardEntry,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = API;
  if (root) { root.PraxisEngine = API; root.SURYAN_CONFIG = SURYAN_CONFIG; }
})(typeof window !== 'undefined' ? window : null);
