# Praxis — Catalyst Leadership Simulation

Live business simulation platform for the Ather Catalyst Programme.

## Setup

### 1. Supabase — Run Schema
Go to Supabase → SQL Editor → New Query → paste `supabase_schema.sql` → Run.

### 2. Upload Case PDFs
Add to `assets/cases/`: `volta_case.pdf`, `arc_case.pdf`, `demo_case.pdf`

### 3. GitHub Pages
Repo Settings → Pages → Source: main branch / (root) → Save
Live at: `https://yaswant46.github.io/praxis`

## Default Team Codes
| Team | Code |
|------|------|
| Alpha | alpha01 |
| Beta | beta02 |
| Gamma | gamma03 |
| Delta | delta04 |
| Epsilon | epsilon05 |
| Zeta | zeta06 |

Admin access code = the email you enter when creating the session.

---

## Competitive mode (Case C — Suryan Energy)

Existing cases (VOLTA/ARC/ShopPulse) are **parallel-world**: each team runs its own
company and outcomes are independent (GM types the outcomes). **Suryan Energy** is
**competitive** — all teams share one demand pool, one crew-wage market, and one public
reputation feed, so a round resolves **once for the whole session** by a coded engine.

### Architecture
- **`praxis_engine.js`** — the pure, data-driven resolution engine (single source of
  truth for `SURYAN_CONFIG`). Loaded by `app.html` (`window.PraxisEngine`) and by the
  Node test. No hardcoded numbers in functions — everything reads from the config.
  Key functions: `resolveAuction`, `computeWageIndex`, `computeCapacity`,
  `allocateDemand`, `computeDefects`, `cashWalk`, `computeSurvivability`,
  `computeFinalScores`, orchestrated by `resolveRound()`.
- **`migrations/002_suryan_competitive.sql`** — additive schema: `cases.mode`/`config`,
  `teams.posture`/`posture_switched`/`state` (live JSONB), `outcomes.detail` (JSONB),
  and the `market_news` table. Applied to the live Praxis project.
- **`tests/engine.test.js`** — `node tests/engine.test.js` (12 assertions across the
  5 spec conditions: demand redistribution, wage contagion, subcontract defects,
  distress/poaching, hollow-team survivability).

### Round mapping
App-round **1 = Round 0** (posture declaration, no financials); app-rounds **2–5 =
spec R1–R4** (Surge / Strain / Crunch / Reckoning).

### GM flow (competitive only — gated by `mode='competitive'`)
Open window → teams submit → **close window** → **⚙️ Resolve Round** (runs the engine
across all teams, writes outcomes + team state + Market News, idempotent per
session+round) → advance. Leaderboard shows the **financial component only** during
play; the full weighted score (Financial 40 / Survivability 25 / Trust 20 /
Reputation 15) is revealed at **End Session** — the gap is the lesson.

### Adding future competitive cases
Reuse the engine with different numbers: add a `CASE_CONTENT`/`DECISION_DOMAINS`/
`QUARTERS_BY_CASE` entry keyed by a new letter, seed the case row with
`mode='competitive'` + a `config` JSONB, and (if mechanics differ) extend the engine.
Parallel-mode cases are untouched — every competitive path is gated by
`isCompetitiveSession()`.
