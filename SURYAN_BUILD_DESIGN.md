# Praxis — Suryan + Intelligence Engine + Auth: Intended Design

> Design output for the three-workstream build. **Nothing here is coded yet
> beyond Workstream A** (the competitive engine, already merged via PR #19).
> This is the map to review and sequence before building B and C.

---

## 0. Current state (ground truth, from the live files)

| Thing | Reality today |
|---|---|
| App shell | Single-file `app.html` (~6,057 lines) + `index.html` + `supabase_schema.sql`. Client-only; **Supabase anon key embedded in the client**; "access control in application logic" per the schema comment. |
| Tables | `cases, sessions, teams, decisions, outcomes, curveballs` + (added by 002) `market_news`; `teams.posture/posture_switched/state`, `outcomes.detail`, `cases.mode/config`. |
| Auth today | GM = Supabase OTP (email). Teams = username+password via `verify_team_login` RPC (recently built on main). No Supabase Auth *user* per participant. |
| Rounds | No `rounds` table exists. Rounds are hardcoded per case in JS (`QUARTERS_BY_CASE`) + `sessions.current_round`. Decisions are one-row-per-field in `decisions`. |
| Engine | `praxis_engine.js` (Workstream A) — pure competitive resolution, 12/12 tests, live E2E verified. |

**Two architecture facts that shape everything below:**
1. **There is no server/API tier.** The client talks to Supabase directly with the **anon key**. Any secret the client can *query* is a secret the participant can read in DevTools. So "GM-only" data can't be protected by "don't send it to the UI" alone — it needs **RLS that distinguishes roles**, which in turn needs **authenticated Supabase users** (participants are currently anon).
2. **The spec's `rounds` table doesn't exist.** Round content is in JS. The intelligence-engine features (per-round qualitative prompt, scenario bet, domain tag) assume a `rounds` table — that's a **new table + a shift** of round content from JS into the DB, or a hybrid.

---

## 1. Gap analysis — REUSE / EXTEND / BUILD

### Workstream A — Suryan competitive (DONE, merged in PR #19)
| Requirement | Status |
|---|---|
| cases.mode/config, teams.posture/state, outcomes.detail, market_news | ✅ BUILT (migration 002, applied live) |
| Engine: auction, wage index, capacity, demand, defects, cash walk, rep/trust/morale, market news, survivability, final scores | ✅ BUILT (`praxis_engine.js`, 12/12) |
| Round 0 posture, R1–R4 forms, Resolve Round, Market News, financial-only leaderboard + End Session reveal | ✅ BUILT (gated by `isCompetitiveSession()`) |
| Curveballs CB-1…CB-4C + incidents LI-1…LI-4 seeded as **DB rows** | ⚠️ PARTIAL — modelled in-engine + as GM curveball *idea bank*; spec wants them seeded as `curveballs`/incident rows. **EXTEND.** |

### Workstream B — Intelligence engine (NET NEW)
| Requirement | Verdict | Notes |
|---|---|---|
| Variable round count (3–10) | EXTEND | `sessions.round_count` new column; UI + gating currently keys off per-case `QUARTERS_BY_CASE`. Needs a round-count source of truth. |
| `task_weight` / `people_weight` (GM-only, never to participants) | BUILD | **Secrecy is the hard part — see §3.** |
| `rounds` table (domain_tag, qualitative_prompt, scenario_bet_*) | BUILD | New table; shifts round content from JS→DB (or hybrid). |
| Qualitative free-text per round + AI scoring (Clarity/Stakeholder/Ethics) | BUILD | Claude call — **must be server-side (Edge Function)**; client can't hold the Anthropic key. |
| Scenario bet (3-option, hidden weights) | BUILD | Weights GM-only (same secrecy problem as task_weight). |
| Individual questionnaire (15 Q, DARE mapping, contradiction pairs, consistency index, proficiency levels) | BUILD | Self-contained scoring; `individual_questionnaire_responses` table. Mapping/flags GM-only. |
| Two-axis score (Task/People), quadrant classification | BUILD | Pure functions; quadrant labels hidden during play. |
| Individual scorecard (printable) | BUILD | Static render from stored scores. |

### Workstream C — Auth + access (NET NEW, HIGHEST RISK)
| Requirement | Verdict | Notes |
|---|---|---|
| Master Admin / GM / SPOC / Team Member role hierarchy | BUILD | Roles today are: superuser email + GM OTP + team creds. SPOC/token model is new. |
| SPOC self-serve signup (Supabase Auth user, is_spoc, team_token) | BUILD | New signup route `?page=join`; `team_members` table. |
| Team-link access via `?team=<token>` (token = credential, no login) | BUILD | Replaces the emailed username/password entry for members. |
| RLS overhaul (role-aware SELECT/UPDATE across teams/sessions/rounds/market_news/questionnaire) | BUILD | **Replaces "all anon" policies. Biggest live-product risk — see §4.** |
| task_weight/domain_tag/weights stripped for participants at DB layer | BUILD | Requires authenticated roles + column/row RLS (or a server function). |

---

## 2. Reconciled schema (delta vs. what's live)

**Already live (002):** `cases.mode/config`, `teams.posture/posture_switched/state`, `outcomes.detail`, `market_news`.

**New migration `003_intelligence_and_auth.sql` would add:**
- `sessions`: `round_count INT DEFAULT 5`, `task_weight INT DEFAULT 50` (people = 100−task, computed).
- `teams`: `spoc_email TEXT`, `team_token TEXT UNIQUE`.
- `decisions`: `qualitative_response`, `qualitative_ai_score`, `qualitative_gm_override`, `qualitative_gm_note`, `scenario_bet_choice`.
- **`rounds`** (new): `session_id`/`case`, `round`, `domain_tag`, `qualitative_prompt`, `scenario_bet_question`, `scenario_bet_option_a/b/c`, `scenario_bet_weights JSONB`.
- **`team_members`** (new): `team_id`, `email`, `is_spoc`, `joined_at`.
- **`individual_questionnaire_responses`** (new): responses, domain_scores, consistency_index, contradiction_flags.

⚠️ The spec's migration references `ALTER TABLE rounds …` as if it exists — **it does not**; it must be `CREATE TABLE`. (Confirmed against live schema.)

---

## 3. The secrecy problem (task_weight, domain_tag, weights) — decision needed

The spec wants these **GM/Master-Admin-only, never reachable by participants**, enforced at DB + API + UI. But **the app is client-only with a shared anon key** — there is no API tier to strip fields, and participants are **anon** (not authenticated), so RLS can't tell a participant from a GM today.

Three ways to actually enforce it (pick one):
- **(a) Authenticate everyone.** Participants become Supabase Auth users (via the SPOC/token flow of Workstream C). Then RLS can gate `task_weight`/`domain_tag`/`scenario_bet_weights` to GM/admin roles. **Cleanest, but couples secrecy to the full auth overhaul (C).**
- **(b) Split tables.** Keep sensitive config in a separate table (`session_secrets`, `round_secrets`) with **no anon policy at all** — anon simply can't read it; GM reads it via an authenticated session. Participant-facing tables carry only non-sensitive columns. **Less risky than a full RLS overhaul; works with today's anon model.**
- **(c) Edge Function tier.** A `get_gm_dashboard` function (service role) that checks the caller's GM identity and returns sensitive data; participants never call it. Needed anyway for the **Claude AI scoring** (the Anthropic key must live server-side).

**Recommendation:** (b) for config secrecy now + (c) for AI scoring, and only adopt (a) if/when Workstream C's auth overhaul lands. This decouples the intelligence engine from the risky auth rewrite.

---

## 4. Workstream C risk (the auth overhaul) — decision needed

Workstream C **replaces the current, recently-shipped team login** (`verify_team_login`, username/password) with a **new model** (SPOC signup + team tokens + role-aware RLS across most tables). On a **live product with running cohorts**, that's the highest-blast-radius change here:
- Rewriting RLS from "anon can do everything, app enforces" to "role-aware policies" can silently break existing GM/team flows if any policy is off.
- The token-as-credential model changes how members get in.

**Recommendation:** treat C as its own project phase with a **staged rollout** (shadow the new policies, test against a throwaway cohort, keep a rollback), **not** bundled with A/B. B's secrecy needs can be met by §3(b)/(c) without C.

---

## 5. Engine module surface (`praxis_engine.js`)

**A (built):** `resolveAuction, computeWageIndex, computeCapacity, allocateDemand, computeDefects, cashWalk, updateReputationTrustMorale (inline), emitMarketNews (inline), computeSurvivability, computeFinalScores, resolveRound`.

**B (to build, all pure, config-driven):**
- `scoreIndividualQuestionnaire(responses)` → domain scores (DARE), contradiction flags (Q2↔Q11, Q4↔Q13, Q6↔Q14, Q2↔Q15), consistency index (High/Mod/Low), proficiency (L1/L2/L3). **Pure — no API.**
- `computeTwoAxisScore(decisions, behaviouralScores, cfg)` → Task 0–100, People 0–100; composite = weighted (GM-only).
- `classifyQuadrant(task, people)` → Catalyst / Executor / Connector / Passenger / Balancer.
- `scoreBehaviouralResponse(text, ctx)` → **NOT pure / not in the browser** — lives in an **Edge Function** calling `claude-sonnet-4-6` (Anthropic key server-side). Client calls the function; gets back {clarity, stakeholder_awareness, ethical_alignment}.

**Tests (extend `tests/engine.test.js`):** spec conditions (a)–(e) for A (done) + (f)–(j) for B (questionnaire sum, contradiction firing, consistency mapping, weights sum to 100, quadrant boundary values 64/65/44/45) + (k)–(n) for C (token lookup, duplicate SPOC, invalid token, task_weight absent from participant payloads).

---

## 6. Role-visibility matrix (what each role sees)

| Data | Master Admin | GM | SPOC | Member |
|---|:--:|:--:|:--:|:--:|
| All sessions | ✅ | ✅ (own) | ❌ | ❌ |
| Team decisions / outcomes (own team) | ✅ | ✅ | ✅ | ✅ |
| Other teams' data | ✅ | ✅ | ❌ | ❌ |
| Public Market News (competitive) | ✅ | ✅ | ✅ | ✅ |
| task_weight / people_weight | ✅ | ✅ | ❌ | ❌ |
| domain_tag (D/A/R/E) | ✅ | ✅ | ❌ | ❌ |
| scenario_bet_weights | ✅ | ✅ | ❌ | ❌ |
| Qualitative AI score (during play) | ✅ | ✅ | ❌ (sees "Submitted") | ❌ |
| Quadrant label (during play) | ✅ | ✅ | ❌ | ❌ |
| Consistency index / contradiction flags | ✅ | ✅ | ❌ | ❌ |
| Full weighted score | ✅ | ✅ | ❌ (financial-only in-game; reveal at End Session) | same |
| Individual scorecard (own) | ✅ | ✅ | ✅ (own) | ✅ (own) |

---

## 7. Recommended delivery order (dependencies first)

1. **A — Suryan competitive** ✅ done (PR #19). *Optionally EXTEND:* seed CB/LI as DB rows.
2. **Migration 003** (round_count, rounds table, decisions qualitative cols, questionnaire table) — **excluding** the auth/token columns until C is scoped.
3. **B intelligence engine (pure parts):** questionnaire scoring, two-axis, quadrant + tests — no secrecy dependency.
4. **Secrecy via §3(b) split-tables + §3(c) Edge Function** for AI scoring — unblocks GM-only config + Claude scoring without the auth rewrite.
5. **B UI:** variable rounds, qualitative/scenario-bet inputs, two-axis leaderboard, GM dashboard additions, questionnaire flow + scorecard.
6. **C auth overhaul** — separate, staged phase with rollback (SPOC signup, team tokens, RLS rewrite). Highest risk; do last, on its own.

**Parallelizable once 003 lands:** B-pure (step 3), the Edge Function (step 4), and C's design/prototype can proceed in parallel — they touch different files. The RLS *rewrite* (C step 6) should not run in parallel with B's UI on the same policies.

---

## 8. Open decisions for you
1. **Secrecy model:** §3 — go with split-tables + Edge Function (recommended), or commit to full participant auth now?
2. **Auth overhaul (C):** separate staged phase (recommended) or bundle with B?
3. **Round content:** move to the `rounds` table (DB-driven, per spec) or keep JS-hardcoded + only store per-session overrides?
4. **Merge PR #19 now** (interim competitive-only) or hold until more of B lands? (It's gated + revertable; existing cohorts unaffected.)
5. **Visual UI pass:** still pending the Chrome extension — needed before a real cohort runs Suryan.
