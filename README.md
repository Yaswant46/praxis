# Praxis — Catalyst Leadership Simulation

Live business simulation platform for the Ather Catalyst Programme.

A Game Master logs in via OTP, runs the **Create Cohort** wizard (cohort name,
case, number of teams, number of rounds, one rep email per team), and the
system generates themed team names + memorable passwords and emails them to
each rep with a unique cohort URL. Each team logs in with their username +
password and runs the simulation in real time.

---

## Architecture

| Layer       | Tech                                       |
|-------------|--------------------------------------------|
| Frontend    | Static `app.html` on GitHub Pages          |
| Database    | Supabase Postgres (RLS + RPCs)             |
| Realtime    | Supabase Realtime (WebSockets)             |
| Auth (GM)   | Supabase OTP (email)                       |
| Auth (team) | `verify_team_login` RPC (session + creds)  |
| Email       | Supabase Edge Function → Brevo             |

---

## One-time setup

You only do this once per Supabase project.

### 1. Run the schema

Go to **Supabase → SQL Editor → New Query**, paste `supabase_schema.sql`, and
**Run**. Idempotent — safe to re-run if you change the file later.

Then, to enable the **Leadership-Comp** family (Case 03 · Borrowed People),
run `supabase/borrowed_schema.sql` the same way. It is fully namespaced with a
`bp_` prefix (its own tables + RPCs) so it never touches the round-based cases,
and is idempotent. Confirm the scoring engine with `SELECT * FROM bp_selftest();`
(all three rows should read `pass = t`).

### 2. Set up Brevo

1. Sign up at [brevo.com](https://www.brevo.com) (free plan: 300 emails/day, no card).
2. **Senders & IP → Senders → Add a sender** → enter an email you control
   (e.g. `you@your-email.com`) → click the verification link Brevo emails
   to that address. From now on this address is your `From:`.
3. **SMTP & API → API Keys → Generate a new API key** → copy it.

### 3. Configure Supabase secrets

In the Supabase dashboard: **Project Settings → Edge Functions → Secrets**, add:

| Key                   | Value                                                          |
|-----------------------|----------------------------------------------------------------|
| `BREVO_API_KEY`       | The API key from step 2                                        |
| `PRAXIS_FROM_EMAIL`   | The sender email you verified in Brevo                         |
| `PRAXIS_FROM_NAME`    | Display name on outgoing emails (optional, defaults to `Praxis`) |
| `PRAXIS_APP_BASE_URL` | `https://yaswant46.github.io/praxis`                            |

Or via the CLI:

```bash
supabase secrets set \
  BREVO_API_KEY=xkeysib-...your_key... \
  PRAXIS_FROM_EMAIL=you@your-email.com \
  PRAXIS_FROM_NAME="Praxis" \
  PRAXIS_APP_BASE_URL=https://yaswant46.github.io/praxis
```

### 3a. Configure Supabase Auth SMTP (so OTP login emails also use Brevo)

In the Supabase dashboard: **Project Settings → Authentication → SMTP Settings → Enable custom SMTP**.

| Field        | Value                                                           |
|--------------|-----------------------------------------------------------------|
| Sender email | Same as `PRAXIS_FROM_EMAIL`                                     |
| Sender name  | `Praxis`                                                        |
| Host         | `smtp-relay.brevo.com`                                          |
| Port         | `587`                                                           |
| Username     | Your Brevo SMTP login (find in Brevo → **SMTP & API → SMTP**)   |
| Password     | Your Brevo SMTP key (same screen)                               |

### 4. Deploy the Edge Function

```bash
supabase functions deploy send-cohort-emails
```

### 5. Upload case PDFs

Add to `assets/cases/`:

- `volta_case.pdf`
- `arc_case.pdf`
- `demo_case.pdf`

### 6. Publish to GitHub Pages

**Repo Settings → Pages → Source: main / (root) → Save.**
Live at `https://yaswant46.github.io/praxis`.

---

## Running a cohort

1. **GM logs in** at the live URL → "Game Master" → enters email → 6-digit OTP.
2. Lands on **GM Console** (or **Master Admin** for `ross.harvey92@gmail.com`).
3. Click **+ Create New Cohort** → fills cohort name, case, team count
   (2–6), rounds (1..max for the chosen case), GM email.
4. **Step 2 — Team representatives**: enter one rep email per team. Themed
   names + passwords are pre-generated; click ↻ to regenerate, or just edit.
5. Click **Create cohort & send emails**. The Edge Function fires one Brevo
   email per team rep with username, password, and a unique URL.
6. Each rep forwards the email to teammates. Anyone on the team can then
   open the URL, enter the username + password, and play.
7. The GM enters the cohort from the console (**Enter as GM**) to run the
   simulation: open/close rounds, inject curveballs, publish outcomes.

The GM can **resend** an email to a single team or rotate a team's password
from the Manage panel at any time.

---

## Files

| File                                          | What it is                                  |
|-----------------------------------------------|---------------------------------------------|
| `index.html`                                  | Landing page (redirects to `app.html`)      |
| `enter.html`                                  | Unified entry — cohort code + email → routed access |
| `netlify.toml` / `NETLIFY.md`                 | Netlify hosting config + one-time setup steps |
| `supabase/enrollments_schema.sql`             | Roster: `enrollments` table + `enroll_login` / `enroll_bulk` RPCs |
| `app.html`                                    | The whole app — UI, JS, Supabase client     |
| `supabase_schema.sql`                         | Tables, RLS policies, RPCs, realtime config |
| `borrowed.html`                               | Case 03 · Borrowed People — 3-role app + projection |
| `supabase/borrowed_schema.sql`                | Case 03 backend — `bp_*` tables, RLS, RPCs, scoring engine |
| `supabase/functions/send-cohort-emails/`      | Deno Edge Function (Brevo transport)        |
| `supabase/functions/bp-assist/`               | Deno Edge Function — on-demand AI facilitator assistant (Anthropic key server-side) |
| `supabase/functions/bp-narrative/`            | Deno Edge Function — org storyline narrator (deterministic spine + Claude prose) |
| `migrations/007_org_story.sql`                | Org story table + `bp_org_spine` / `bp_publish_story` / `bp_set_observer` |
| `404.html`                                    | GitHub Pages SPA fallback                   |

---

## Security model

- **Game Master writes** (creating cohorts, opening rounds, injecting
  curveballs, publishing outcomes) require an authenticated Supabase
  session whose email matches the cohort's `admin_email` — enforced by
  RLS, not just client-side checks.
- **Team credentials** (`username`, `password`) are never readable by the
  anon role. The participant login goes through the `verify_team_login`
  RPC which returns the team identity only on a credential match.
- **Outcomes** are visible to participants only after the GM publishes
  them (`published_at IS NOT NULL`).
- **Decisions** remain readable across teams in this version. The next
  iteration will gate them with per-team JWTs issued by `verify_team_login`.

The hardcoded master-admin email is `ross.harvey92@gmail.com`. To change
it, edit both `app.html` (`SUPERUSER_EMAIL`) and
`supabase_schema.sql` (the `praxis_is_master_admin` helper).

---

## Competitive mode (Case C — Suryan Energy)

Existing cases (VOLTA/ARC/ShopPulse) are **parallel-world**: each team runs its
own company and outcomes are independent (GM types the outcomes). **Suryan
Energy** is **competitive** — all teams share one demand pool, one crew-wage
market, and one public reputation feed, so a round resolves **once for the whole
session** via a coded engine.

### Architecture
- **`praxis_engine.js`** — the pure, data-driven resolution engine (single source
  of truth for `SURYAN_CONFIG`). Loaded by `app.html` (`window.PraxisEngine`) and
  by the Node test. No hardcoded numbers — everything reads from the config.
  Key functions: `resolveAuction`, `computeWageIndex`, `computeCapacity`,
  `allocateDemand`, `computeDefects`, `cashWalk`, `computeSurvivability`,
  `computeFinalScores`, orchestrated by `resolveRound()`.
- **`migrations/002_suryan_competitive.sql`** — additive schema: `cases.mode`/
  `config`, `teams.posture`/`posture_switched`/`state` (JSONB), `outcomes.detail`
  (JSONB), and the `market_news` table. Applied to the live project.
- **`tests/engine.test.js`** — `node tests/engine.test.js` (12 assertions across
  the 5 spec conditions). `tests/e2e_live.mjs` — headless end-to-end.

### Round mapping
App-round **1 = Round 0** (posture declaration, no financials); app-rounds
**2–5 = spec R1–R4** (Surge / Strain / Crunch / Reckoning).

### GM flow (competitive only — gated by `mode='competitive'`)
Open window → teams submit → **close window** → **⚙️ Resolve Round** (runs the
engine across all teams, writes outcomes + team state + Market News, idempotent
per session+round) → advance. The leaderboard shows the **financial component
only** during play; the full weighted score (Financial 40 / Survivability 25 /
Trust 20 / Reputation 15) is revealed at **End Session** — the gap is the lesson.

### Adding future competitive cases
Reuse the engine with different numbers: add a `CASE_CONTENT`/`DECISION_DOMAINS`/
`QUARTERS_BY_CASE` entry keyed by a new letter, seed the case row with
`mode='competitive'` + a `config` JSONB, and (if mechanics differ) extend the
engine. Parallel-mode cases are untouched — every competitive path is gated by
`isCompetitiveSession()`.

---

## Leadership-Comp · Case 03 — Borrowed People

*"The Uncomfortable Art of Leadership."* A live, in-room, facilitator-driven
simulation — 30 people, one room, four hours. Unlike the round-based cases it
runs on its **own engine** (`borrowed.html` + `supabase/borrowed_schema.sql`),
registered in the catalog under the **Leadership-Comp** category. Scoring intent
is 80% emotional intelligence / 20% business outcome.

### Three roles, one page, gated by access code
- **Participant** (team code) — dashboard, stakeholder map (pre/post), request +
  Style Calls, the reveal, boards, the **org story so far**, debrief.
- **Character** (character code) — the **sealed console**: incoming requests,
  escalation brief, capacity-capped selection, the fixed 3×(1–3) rating rubric,
  the **org story so far**, Q4 judgement.
- **Facilitator** (facilitator code) — manual phase control, session monitor,
  the **drift check** (rating-compression flag), curveballs, hidden headwind +
  reveal, capacity override, **Play as** (admin override), the on-demand
  **AI assist**, the **Org story** generator/publisher, the **Observer log**
  (keyed in from the offline observer), code handout, JSON export, and the
  wall **projection** (`borrowed.html?projection=<session_id>`).

### The observer sits out
The team's observer watches without playing, so the observed style is **keyed in
by the facilitator** on the **Observer log** tab (from what the observer reports
offline) — not entered in a team login. The debrief is unchanged: declared Style
Calls still meet the observed style, and the gap is still the lesson.

### Org storyline — "the Meridian" (real-time, on-demand)
After running a quarter's results, the facilitator opens **Org story**, picks the
quarter, and presses **Generate**. The `bp-narrative` edge function pulls the
**deterministic spine** (`bp_org_spine` — each programme's band, momentum, the
org meter, and, at year-end, the couplings + achievement scorecard) through the
facilitator-gated RPC, then asks Claude to write **one chapter of prose around
those fixed facts** (the facts are computed in SQL, never invented by the model).
The facilitator reviews/regenerates, then **Publish** pushes the chapter to
**every team and character login** (and the projection wall) live over Realtime.
The Anthropic key stays in the edge function. Setup mirrors the assistant: deploy
`supabase/functions/bp-narrative/`, set `ANTHROPIC_API_KEY` (optional
`BP_NARRATIVE_MODEL`, default `claude-opus-5`).

### AI facilitator assistant (on-demand)
The **AI assist** tab never runs on its own. When the facilitator presses
**Analyze now**, the `bp-assist` edge function reads the current sealed session
state (through the facilitator-gated `bp_export` RPC — so a non-facilitator code
gets a 403) and asks Claude for three things: the **key moves** just made,
**contradictions & risks** (wrong-character requests vs. the demand map, Style
Calls that clash with the observer log, characters "going soft" via rating
compression), and pointed **debrief questions**. The Anthropic key lives only in
the edge function, never in the page.

Setup: deploy `supabase/functions/bp-assist/`, then set the `ANTHROPIC_API_KEY`
secret (Supabase → **Edge Functions → Secrets**, or
`supabase secrets set ANTHROPIC_API_KEY=...`). Optional `BP_ASSIST_MODEL`
overrides the model (default `claude-opus-5`).

### How it stays honest
Every spoiler — the demand map, selections before results, Style Calls before
debrief, requests before the reveal, the headwind — lives on a **deny-all**
table. All reads/writes go through `bp_*` `SECURITY DEFINER` RPCs that check the
caller's access code and the session's phase, so the character console is sealed
at the RLS layer, not just the UI. Realtime publishes only the phase pointer and
published results.

### Phase machine (facilitator advances each step, per quarter Q1–Q4)
`BRIEF → TEAM_DISCUSSION → REQUESTS_OPEN → REQUESTS_LOCKED (the reveal) →
RUNNER_WINDOW → OPEN_NEGOTIATION → SELECTION → RESULTS (engine runs) → DEBRIEF`.
Step-back is logged to `bp_events` and never deletes data.

### Setup
1. Run `supabase/borrowed_schema.sql` in the SQL Editor.
2. `SELECT * FROM bp_selftest();` → all three §6 sanity checks pass.
3. From `borrowed.html`, open *Facilitator — set up a new session* to provision a
   playable session and generate the team / character / facilitator codes, or run
   `SELECT bp_create_session('Cohort name');`.
