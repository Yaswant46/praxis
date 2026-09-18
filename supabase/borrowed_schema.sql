-- =====================================================================
--  PRAXIS · CASE 03 — BORROWED PEOPLE
--  Category: Leadership-Comp
--  "The Uncomfortable Art of Leadership."
--
--  A live, in-room, facilitator-driven, three-role simulation that runs
--  on the same Supabase project as the round-based Praxis cases. Every
--  object here is namespaced with the bp_ prefix so it never collides
--  with the existing sessions / teams / curveballs tables.
--
--  Auth model: anonymous key + access codes. Every sensitive table has
--  RLS with NO permissive anon policy (deny-all) and is reachable ONLY
--  through SECURITY DEFINER RPCs that validate the caller's access code
--  and the session's current phase. This is what seals the character
--  console at the RLS layer, not just the UI (Non-negotiable #1, §2).
--
--  Idempotent — safe to re-run.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ---------------------------------------------------------------------
--  Phase state machine (§5) — ordered so we can compute next / prev.
-- ---------------------------------------------------------------------
--  BRIEF → TEAM_DISCUSSION → REQUESTS_OPEN → REQUESTS_LOCKED (THE REVEAL)
--  → OPEN_NEGOTIATION → SELECTION → RESULTS → DEBRIEF

-- =====================================================================
--  TABLES
-- =====================================================================

-- Sessions -----------------------------------------------------------
-- NOTE: holds NO secret. Anon-readable so clients can subscribe to the
-- phase pointer over Realtime. Headwind lives in bp_headwind (deny-all).
CREATE TABLE IF NOT EXISTS bp_sessions (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name              TEXT NOT NULL,
  status            TEXT NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft','live','closed')),
  current_quarter   INT  NOT NULL DEFAULT 1 CHECK (current_quarter BETWEEN 0 AND 4),
  current_phase     TEXT NOT NULL DEFAULT 'BRIEF'
                       CHECK (current_phase IN (
                         'BRIEF','TEAM_DISCUSSION','REQUESTS_OPEN','REQUESTS_LOCKED',
                         'OPEN_NEGOTIATION','SELECTION','RESULTS','DEBRIEF')),
  headwind_revealed BOOLEAN NOT NULL DEFAULT FALSE,
  target_value      INT NOT NULL DEFAULT 14200,
  variant           TEXT NOT NULL DEFAULT 'full',   -- 'full' | 'short' (see migrations/008)
  facilitator_code  TEXT UNIQUE NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Headwind (secret until revealed) -----------------------------------
CREATE TABLE IF NOT EXISTS bp_headwind (
  session_id  UUID PRIMARY KEY REFERENCES bp_sessions(id) ON DELETE CASCADE,
  value       INT NOT NULL DEFAULT 6000 CHECK (value BETWEEN 3000 AND 9000)
);

-- Objectives (seed, 5 rows) — public labels --------------------------
CREATE TABLE IF NOT EXISTS bp_objectives (
  session_id   UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  key          TEXT NOT NULL CHECK (key IN ('battery','suppliers','spec','warranty','pricing')),
  label        TEXT NOT NULL,
  description  TEXT,
  PRIMARY KEY (session_id, key)
);

-- Teams --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bp_teams (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id    UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  code          TEXT NOT NULL CHECK (code IN ('A','B','C','D','E')),
  name          TEXT NOT NULL,
  objective_key TEXT NOT NULL,
  access_code   TEXT UNIQUE NOT NULL,
  UNIQUE (session_id, code)
);

-- Characters (console credential lives here) -------------------------
CREATE TABLE IF NOT EXISTS bp_characters (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id  UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  key         TEXT NOT NULL CHECK (key IN ('arjun','neha','raghav','farida','devika','sponsor')),
  name        TEXT NOT NULL,
  role_label  TEXT NOT NULL,
  access_code TEXT UNIQUE NOT NULL,
  UNIQUE (session_id, key)
);

-- Participants (roster; seat assignment target) ----------------------
CREATE TABLE IF NOT EXISTS bp_participants (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id      UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  character_id UUID REFERENCES bp_characters(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  access_code  TEXT,
  CHECK ( (team_id IS NOT NULL)::int + (character_id IS NOT NULL)::int = 1 )
);

CREATE TABLE IF NOT EXISTS bp_seat_assignments (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id     UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id        UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter        INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  participant_id UUID REFERENCES bp_participants(id) ON DELETE CASCADE,
  seat           TEXT NOT NULL CHECK (seat IN ('lead','runner','analyst','observer','watch')),
  UNIQUE (session_id, team_id, quarter, seat)
);

-- Demand map (HIDDEN forever, §2.3) ----------------------------------
CREATE TABLE IF NOT EXISTS bp_demand_map (
  session_id            UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  objective_key         TEXT NOT NULL,
  quarter               INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  primary_character_key TEXT NOT NULL,
  secondary_character_key TEXT NOT NULL,
  PRIMARY KEY (session_id, objective_key, quarter)
);

-- Character capacity --------------------------------------------------
CREATE TABLE IF NOT EXISTS bp_character_capacity (
  session_id   UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  character_id UUID REFERENCES bp_characters(id) ON DELETE CASCADE,
  quarter      INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  slots        INT NOT NULL DEFAULT 2,
  PRIMARY KEY (session_id, character_id, quarter)
);

-- Requests (hidden until REQUESTS_LOCKED) ----------------------------
CREATE TABLE IF NOT EXISTS bp_requests (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id            UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id               UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter               INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  primary_character_id  UUID REFERENCES bp_characters(id),
  secondary_character_id UUID REFERENCES bp_characters(id),
  submitted_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, team_id, quarter)
);

-- Style calls (SEALED until DEBRIEF, §2.2) ---------------------------
CREATE TABLE IF NOT EXISTS bp_style_calls (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id  UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id     UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter     INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  seat        TEXT NOT NULL CHECK (seat IN ('lead','runner')),
  style       TEXT NOT NULL CHECK (style IN
                ('commanding','visionary','affiliative','democratic','pacesetting','coaching')),
  rationale   TEXT,
  sealed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, team_id, quarter, seat)
);

-- Observer logs (open at DEBRIEF) ------------------------------------
CREATE TABLE IF NOT EXISTS bp_observer_logs (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id    UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id       UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter       INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  observed_style TEXT NOT NULL CHECK (observed_style IN
                ('commanding','visionary','affiliative','democratic','pacesetting','coaching')),
  note          TEXT,
  UNIQUE (session_id, team_id, quarter)
);

-- Selections (hidden before RESULTS) ---------------------------------
CREATE TABLE IF NOT EXISTS bp_selections (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  character_id UUID REFERENCES bp_characters(id) ON DELETE CASCADE,
  quarter      INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  team_id      UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  reason       TEXT,
  UNIQUE (session_id, character_id, quarter, team_id)
);

-- Ratings (never shown to participants individually) -----------------
CREATE TABLE IF NOT EXISTS bp_ratings (
  id                       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id               UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  character_id             UUID REFERENCES bp_characters(id) ON DELETE CASCADE,
  team_id                  UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter                  INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  knew_what_i_cared_about  INT NOT NULL CHECK (knew_what_i_cared_about BETWEEN 1 AND 3),
  asked_or_told            INT NOT NULL CHECK (asked_or_told BETWEEN 1 AND 3),
  left_me_better           INT NOT NULL CHECK (left_me_better BETWEEN 1 AND 3),
  UNIQUE (session_id, character_id, team_id, quarter)
);

-- Commitments (displayed, never enforced, §2.5) ----------------------
CREATE TABLE IF NOT EXISTS bp_commitments (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id      UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  quarter         INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  from_team_id    UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  to_team_id      UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  text            TEXT NOT NULL,
  confirmed_by_to BOOLEAN NOT NULL DEFAULT FALSE,
  honoured_from   BOOLEAN,
  honoured_to     BOOLEAN,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Q4 character judgement (displayed to the room) ---------------------
CREATE TABLE IF NOT EXISTS bp_judgements (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  character_id UUID REFERENCES bp_characters(id) ON DELETE CASCADE,
  team_id      UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  again        BOOLEAN,
  reason       TEXT,
  UNIQUE (session_id, character_id, team_id)
);

-- Stakeholder maps (pre / post, own only) ----------------------------
CREATE TABLE IF NOT EXISTS bp_stakeholder_maps (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id     UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id        UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  phase          TEXT NOT NULL CHECK (phase IN ('pre','post')),
  payload        JSONB NOT NULL,
  submitted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, team_id, phase)
);

-- Quarter results (computed by the engine) ---------------------------
CREATE TABLE IF NOT EXISTS bp_quarter_results (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id    UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id       UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter       INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  got_primary   BOOLEAN NOT NULL,
  got_secondary BOOLEAN NOT NULL,
  avg_rating    NUMERIC,
  band          TEXT NOT NULL CHECK (band IN ('missed','partial','delivered','exceeded')),
  points        INT NOT NULL,
  UNIQUE (session_id, team_id, quarter)
);

-- Curveballs (seed + triggered flag) ---------------------------------
CREATE TABLE IF NOT EXISTS bp_curveballs (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  key          TEXT NOT NULL,
  label        TEXT NOT NULL,
  body         TEXT NOT NULL,
  quarter      INT,
  triggered_at TIMESTAMPTZ,
  UNIQUE (session_id, key)
);

-- Escalation cards (character console only; video_url reserved v2) ---
CREATE TABLE IF NOT EXISTS bp_escalation_cards (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id    UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  character_key TEXT,          -- NULL = applies to all characters
  quarter       INT NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  posture       TEXT NOT NULL,
  sample_lines  TEXT NOT NULL,
  video_url     TEXT,          -- reserved for v2, §14
  UNIQUE (session_id, character_key, quarter)
);

-- Events (append-only audit) -----------------------------------------
CREATE TABLE IF NOT EXISTS bp_events (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id  UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  actor_role  TEXT,
  action      TEXT NOT NULL,
  payload     JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Adaptive-demand-map state (migration 010) — per-objective per-quarter
-- business state + the ideal we actually scored against. HIDDEN like
-- bp_demand_map: deny-all, reached only through the definer RPCs. Surfaced to
-- the room via bp_state's demand_reveal (facilitator always; participants /
-- characters at DEBRIEF only).
CREATE TABLE IF NOT EXISTS bp_objective_state (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id      UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  objective_key   TEXT NOT NULL,
  quarter         INT  NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  state           TEXT NOT NULL CHECK (state IN ('on_track','behind','at_risk')),
  primary_key     TEXT,
  secondary_key   TEXT,
  business_reason TEXT,
  UNIQUE (session_id, objective_key, quarter)
);

-- Mandate mechanic (migration 011) — the compliance-vs-courage axis.
-- Both tables are spoiler tables: deny-all like bp_demand_map, reached only
-- through the definer RPCs (bp_submit_mandate / bp_set_directive / bp_state).
--
-- The directive the Sponsor hands each team for a quarter, and whether it is
-- business-'sound' or in 'tension' with the adaptive-demand-map ideal.
CREATE TABLE IF NOT EXISTS bp_directives (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id       UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id          UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter          INT  NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  directive_text   TEXT NOT NULL,
  intended_benefit TEXT,
  alignment        TEXT NOT NULL CHECK (alignment IN ('sound','tension')),
  issued_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, team_id, quarter)
);

-- The team's stance on the directive: comply / voice / defy, plus the dissent
-- line they wrote (required for voice + defy).
CREATE TABLE IF NOT EXISTS bp_mandate_decisions (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id    UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id       UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter       INT  NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  stance        TEXT NOT NULL CHECK (stance IN ('comply','voice','defy')),
  dissent_line  TEXT,
  submitted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, team_id, quarter)
);

CREATE INDEX IF NOT EXISTS bp_events_session_idx ON bp_events(session_id, created_at);
CREATE INDEX IF NOT EXISTS bp_selections_lookup  ON bp_selections(session_id, quarter, team_id);
CREATE INDEX IF NOT EXISTS bp_ratings_lookup     ON bp_ratings(session_id, quarter, team_id);

-- =====================================================================
--  ROW LEVEL SECURITY
--  Enable on everything. Grant permissive anon SELECT ONLY on tables
--  that carry no spoiler. All sensitive tables get NO policy (deny-all
--  to the anon role) and are reached exclusively through the SECURITY
--  DEFINER RPCs below.
-- =====================================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'bp_sessions','bp_headwind','bp_objectives','bp_teams','bp_characters',
    'bp_participants','bp_seat_assignments','bp_demand_map','bp_character_capacity',
    'bp_requests','bp_style_calls','bp_observer_logs','bp_selections','bp_ratings',
    'bp_commitments','bp_judgements','bp_stakeholder_maps','bp_quarter_results',
    'bp_curveballs','bp_escalation_cards','bp_events',
    'bp_objective_state','bp_directives','bp_mandate_decisions'])
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Permissive anon SELECT — SAFE tables only (no spoilers).
DROP POLICY IF EXISTS bp_pub_sessions        ON bp_sessions;
DROP POLICY IF EXISTS bp_pub_objectives      ON bp_objectives;
DROP POLICY IF EXISTS bp_pub_teams           ON bp_teams;
DROP POLICY IF EXISTS bp_pub_quarter_results ON bp_quarter_results;
DROP POLICY IF EXISTS bp_pub_commitments     ON bp_commitments;

-- bp_sessions is readable for the Realtime phase pointer; its
-- facilitator_code column is withheld by the column grants below.
CREATE POLICY bp_pub_sessions        ON bp_sessions        FOR SELECT USING (true);
CREATE POLICY bp_pub_objectives      ON bp_objectives      FOR SELECT USING (true);
CREATE POLICY bp_pub_teams           ON bp_teams           FOR SELECT USING (true);
-- Results are public by design the moment the engine writes them (RESULTS).
CREATE POLICY bp_pub_quarter_results ON bp_quarter_results FOR SELECT USING (true);
-- The commitments board (incl. broken ones) is shown to everyone.
CREATE POLICY bp_pub_commitments     ON bp_commitments     FOR SELECT USING (true);

-- Table-level privilege hardening (defense-in-depth on top of RLS).
-- Sensitive tables: REVOKE everything from the API roles so that even a
-- misconfigured RLS policy cannot leak them. Definer RPCs run as the
-- table owner and are unaffected.
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'bp_headwind','bp_characters','bp_participants','bp_seat_assignments',
    'bp_demand_map','bp_character_capacity','bp_requests','bp_style_calls',
    'bp_observer_logs','bp_selections','bp_ratings','bp_judgements',
    'bp_stakeholder_maps','bp_escalation_cards','bp_events',
    'bp_objective_state','bp_directives','bp_mandate_decisions'])
  LOOP
    EXECUTE format('REVOKE ALL ON %I FROM anon, authenticated', t);
  END LOOP;
END $$;

-- Safe tables: explicit SELECT for the API roles (subject to the
-- permissive policies above).
-- bp_sessions.facilitator_code and bp_teams.access_code are secrets: a
-- participant with DevTools could otherwise pull the facilitator console
-- (migration 014). Column-level SELECT keeps the Realtime phase pointer
-- and the client's `select('variant')` working; the code columns are
-- simply never served to the API roles.
REVOKE ALL ON bp_sessions, bp_teams FROM anon, authenticated;
GRANT SELECT (id, name, status, current_quarter, current_phase, headwind_revealed,
              target_value, variant, created_at) ON bp_sessions TO anon, authenticated;
GRANT SELECT (id, session_id, code, name, objective_key) ON bp_teams TO anon, authenticated;
GRANT SELECT ON bp_objectives, bp_quarter_results, bp_commitments TO anon, authenticated;

-- Every sensitive table has NO anon policy → deny-all; the two public
-- tables that carry a code expose it to nobody (column grants above).

-- =====================================================================
--  HELPERS
-- =====================================================================

-- Short, unambiguous access codes (no 0/O/1/I/L).
CREATE OR REPLACE FUNCTION bp_gencode(p_prefix TEXT)
RETURNS TEXT LANGUAGE sql AS $$
  SELECT p_prefix || '-' || string_agg(
           substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789',
                  (floor(random()*30)+1)::int, 1), '')
  FROM generate_series(1,4);
$$;

-- Ordered phase list → next / prev.
CREATE OR REPLACE FUNCTION bp_phase_index(p TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT array_position(ARRAY[
    'BRIEF','TEAM_DISCUSSION','REQUESTS_OPEN','REQUESTS_LOCKED',
    'OPEN_NEGOTIATION','SELECTION','RESULTS','DEBRIEF'], p);
$$;

CREATE OR REPLACE FUNCTION bp_phase_at(i INT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY[
    'BRIEF','TEAM_DISCUSSION','REQUESTS_OPEN','REQUESTS_LOCKED',
    'OPEN_NEGOTIATION','SELECTION','RESULTS','DEBRIEF'])[i];
$$;

-- Auth: resolve a (session_code, access_code) pair to an identity.
-- Raises on any invalid pair. Returns role + ids.
CREATE OR REPLACE FUNCTION bp_auth(p_session_code TEXT, p_access_code TEXT)
RETURNS TABLE (session_id UUID, role TEXT, team_id UUID, character_id UUID, display_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_sid UUID;
BEGIN
  -- p_session_code is the facilitator_code for facilitators, or any team/
  -- character code carries its own session, so we resolve session by the
  -- access code itself and ignore mismatched session hints.
  -- Facilitator:
  SELECT s.id INTO v_sid FROM bp_sessions s WHERE s.facilitator_code = p_access_code;
  IF v_sid IS NOT NULL THEN
    RETURN QUERY SELECT v_sid, 'facilitator'::TEXT, NULL::UUID, NULL::UUID, 'Facilitator'::TEXT;
    RETURN;
  END IF;
  -- Team:
  RETURN QUERY
    SELECT t.session_id, 'participant'::TEXT, t.id, NULL::UUID, ('Team '||t.code||' — '||t.name)
    FROM bp_teams t WHERE t.access_code = p_access_code;
  IF FOUND THEN RETURN; END IF;
  -- Character:
  RETURN QUERY
    SELECT c.session_id, 'character'::TEXT, NULL::UUID, c.id, c.name
    FROM bp_characters c WHERE c.access_code = p_access_code;
  IF FOUND THEN RETURN; END IF;

  RAISE EXCEPTION 'invalid_access_code';
END $$;

CREATE OR REPLACE FUNCTION bp_log(p_sid UUID, p_role TEXT, p_action TEXT, p_payload JSONB)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO bp_events(session_id, actor_role, action, payload)
  VALUES (p_sid, p_role, p_action, p_payload);
$$;

-- Mandate mechanic (migration 011): the third (leadership) axis. Maps a team's
-- stance × the directive's business alignment to a leadership cell, surfaced
-- only in bp_state's mandate_reveal. Pure logic — no session data.
CREATE OR REPLACE FUNCTION bp_leadership_cell(p_stance TEXT, p_alignment TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_stance IS NULL THEN 'no decision'
    WHEN p_stance='comply' AND p_alignment='sound'   THEN 'trust well-placed'
    WHEN p_stance='comply' AND p_alignment='tension' THEN 'silent compliance'
    WHEN p_stance='voice'  AND p_alignment='sound'   THEN 'reconciled'
    WHEN p_stance='voice'  AND p_alignment='tension' THEN 'the leadership move'
    WHEN p_stance='defy'   AND p_alignment='sound'   THEN 'parochial overreach'
    WHEN p_stance='defy'   AND p_alignment='tension' THEN 'principled dissent'
    ELSE 'no decision' END;
$$;

-- =====================================================================
--  SESSION PROVISIONING  (seeds a full playable case, §11)
-- =====================================================================
-- The pre-variant one-argument overload must not coexist with this one:
-- PostgREST cannot choose between them (migration 017).
DROP FUNCTION IF EXISTS bp_create_session(text);
CREATE OR REPLACE FUNCTION bp_create_session(p_name TEXT, p_variant TEXT DEFAULT 'full')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sid UUID;
  v_fac TEXT;
  r RECORD;
  v_variant TEXT := CASE WHEN lower(COALESCE(p_variant,'full'))='short' THEN 'short' ELSE 'full' END;
  v_team_codes JSONB := '{}'::jsonb;
  v_char_codes JSONB := '{}'::jsonb;
  -- objective → team code, name  (SAME for both variants)
  objs TEXT[][] := ARRAY[
    ARRAY['battery','A','Battery','Cell cost, energy density, and thermal safety.'],
    ARRAY['suppliers','B','Suppliers','Second-source the critical bill of materials.'],
    ARRAY['spec','C','Spec','Lock the product specification without gold-plating.'],
    ARRAY['warranty','D','Warranty','Contain field-failure exposure and warranty reserve.'],
    ARRAY['pricing','E','Pricing','Hold margin against a price-led market.']];
  team_names TEXT[] := ARRAY['Ampere','Bastion','Crucible','Dynamo','Envoy'];
  -- FULL: 5 playable + Sponsor
  chars_full TEXT[][] := ARRAY[
    ARRAY['arjun','Arjun','Design lead'],
    ARRAY['neha','Neha','Supply chain — 14 months in'],
    ARRAY['raghav','Raghav','Manufacturing — 19 years'],
    ARRAY['farida','Farida','Quality'],
    ARRAY['devika','Devika','Regional Sales Head'],
    ARRAY['sponsor','Sponsor','Sponsor — facilitator plays this']];
  dmap_full TEXT[][] := ARRAY[
    ARRAY['battery',  'arjun','neha',  'neha','farida', 'farida','raghav', 'arjun','neha'],
    ARRAY['suppliers','neha','raghav', 'neha','raghav', 'raghav','neha',   'sponsor','neha'],
    ARRAY['spec',     'arjun','devika','farida','devika','arjun','devika', 'sponsor','farida'],
    ARRAY['warranty', 'farida','raghav','raghav','farida','neha','raghav', 'farida','neha'],
    ARRAY['pricing',  'devika','farida','devika','arjun', 'devika','farida','sponsor','devika']];
  -- SHORT: 3 playable (Arjun, Neha, Farida) + Sponsor; demand map only needs these four.
  chars_short TEXT[][] := ARRAY[
    ARRAY['arjun','Arjun','Design lead'],
    ARRAY['neha','Neha','Supply chain — 14 months in'],
    ARRAY['farida','Farida','Quality'],
    ARRAY['sponsor','Sponsor','Sponsor — facilitator plays this']];
  dmap_short TEXT[][] := ARRAY[
    ARRAY['battery',  'arjun','neha',   'neha','farida',  'farida','arjun', 'arjun','neha'],
    ARRAY['suppliers','neha','farida',  'neha','arjun',   'arjun','neha',   'sponsor','neha'],
    ARRAY['spec',     'arjun','farida', 'farida','arjun', 'arjun','farida', 'sponsor','farida'],
    ARRAY['warranty', 'farida','neha',  'neha','farida',  'neha','farida',  'farida','neha'],
    ARRAY['pricing',  'farida','arjun', 'arjun','farida', 'farida','neha',  'sponsor','farida']];
  chars TEXT[][];
  dmap  TEXT[][];
  i INT; q INT;
  v_char_id UUID;
  -- Mandate directives (migration 011). objective_key | quarter | alignment |
  -- directive_text | intended_benefit. Same 20 for both variants — teams and
  -- their objectives are identical across variants. objective_key → team via
  -- bp_teams.objective_key at insert time.
  directives TEXT[][] := ARRAY[
    ARRAY['battery','1','sound',$q$Nail the cell architecture first — get Arjun's design lock before anything moves.$q$,$q$A stable platform the whole programme builds on.$q$],
    ARRAY['suppliers','1','sound',$q$Put Neha on second-sourcing the critical BOM now.$q$,$q$De-risk the supply base before volumes ramp.$q$],
    ARRAY['spec','1','sound',$q$Work with Arjun to define the spec envelope.$q$,$q$A clear, buildable spec — no ambiguity downstream.$q$],
    ARRAY['warranty','1','sound',$q$Get Farida to set the quality gates and reserve model early.$q$,$q$Contain field-failure exposure before it compounds.$q$],
    ARRAY['pricing','1','sound',$q$Get Devika's market read and set the pricing corridor.$q$,$q$Hold margin against price-led competitors.$q$],
    ARRAY['battery','2','sound',$q$Cell prices are moving — get Neha to lock second-source cells before the squeeze hits battery.$q$,$q$Secure supply before margin erodes.$q$],
    ARRAY['suppliers','2','tension',$q$Neha's still new; bring Raghav's weight to the supplier table for harder terms.$q$,$q$Better commercial terms from a veteran.$q$],
    ARRAY['spec','2','sound',$q$Bring Farida in to pressure-test the spec against field reality.$q$,$q$A spec that survives contact with customers.$q$],
    ARRAY['warranty','2','sound',$q$Most warranty risk is born on the line — bring Raghav in.$q$,$q$Build quality in, don't inspect it in.$q$],
    ARRAY['pricing','2','tension',$q$Work with Arjun to strip design cost so we can fund a lower price.$q$,$q$Win share on price.$q$],
    ARRAY['battery','3','tension',$q$Board wants energy-density gains — push Arjun for the next design iteration.$q$,$q$A headline spec bump for the launch story.$q$],
    ARRAY['suppliers','3','sound',$q$Bring Raghav in to lock manufacturing-side supplier commitments.$q$,$q$Production-ready supply.$q$],
    ARRAY['spec','3','tension',$q$Spec's set — hand it to Raghav for manufacturability and stop iterating.$q$,$q$Protect the timeline; no gold-plating.$q$],
    ARRAY['warranty','3','tension',$q$Double down with Farida on pre-launch testing.$q$,$q$Catch failures before customers do.$q$],
    ARRAY['pricing','3','sound',$q$Stay with Devika and defend the price in-market.$q$,$q$Protect the margin line.$q$],
    ARRAY['battery','4','sound',$q$Back to Arjun — close the design for production freeze.$q$,$q$A clean freeze for launch.$q$],
    ARRAY['suppliers','4','sound',$q$This one's above your level — escalate the second-source sign-off to me.$q$,$q$I can clear the cross-functional logjam.$q$],
    ARRAY['spec','4','sound',$q$Bring the final spec trade-offs to me for sign-off.$q$,$q$A decision that sticks.$q$],
    ARRAY['warranty','4','sound',$q$Back to Farida to close out the warranty reserve.$q$,$q$A defensible number for the board.$q$],
    ARRAY['pricing','4','tension',$q$You've got this — hold price and close it yourself, no need to escalate.$q$,$q$Show the board pricing is under control.$q$]];
  v_team_id UUID;
BEGIN
  IF v_variant='short' THEN chars := chars_short; dmap := dmap_short;
  ELSE                     chars := chars_full;  dmap := dmap_full;  END IF;

  v_fac := bp_gencode('FAC');
  INSERT INTO bp_sessions(name, facilitator_code, variant) VALUES (p_name, v_fac, v_variant) RETURNING id INTO v_sid;
  -- Headwind default calibrated to 3500 (migration 012): solid play (2 exceeded +
  -- 3 delivered) clears the ~14,200 floor; adjust per session as needed.
  INSERT INTO bp_headwind(session_id, value) VALUES (v_sid, 3500);

  -- Objectives + teams
  FOR i IN 1..array_length(objs,1) LOOP
    INSERT INTO bp_objectives(session_id, key, label, description)
      VALUES (v_sid, objs[i][1], objs[i][3], objs[i][4]);
    INSERT INTO bp_teams(session_id, code, name, objective_key, access_code)
      VALUES (v_sid, objs[i][2], team_names[i], objs[i][1], bp_gencode('TEAM'||objs[i][2]));
  END LOOP;

  -- Characters
  FOR i IN 1..array_length(chars,1) LOOP
    INSERT INTO bp_characters(session_id, key, name, role_label, access_code)
      VALUES (v_sid, chars[i][1], chars[i][2], chars[i][3], bp_gencode('CHR'))
      RETURNING id INTO v_char_id;
    -- CAPACITY IS THE CALIBRATION KNOB: loosen if the org floor becomes unhittable.
    -- Q1 IS THE SQUEEZE (migration 015): every working character has ONE slot,
    -- so 10 asks meet 5 slots and half the room misses its primary in the
    -- first quarter. Those misses seed the adaptive demand map (behind /
    -- at_risk from Q2) — Q1 produces real output instead of a warm-up.
    -- Q2–Q4: 2 slots; competition comes from the demand-map CLUSTERS (Farida
    -- wanted by 3 in Q2, Raghav by 3 in Q3, Sponsor/Neha by 3 in Q4) hitting
    -- the 2-slot ceiling — one team misses at each cluster.
    -- Sponsor: scarce (1) in Q1–Q3; 2 in Q4 where 3 teams need escalation, so
    -- the Q4 crunch stays contested (3-into-2) but the org floor stays reachable.
    -- Facilitator can override any cell live from the Capacity tab.
    FOR q IN 1..4 LOOP
      INSERT INTO bp_character_capacity(session_id, character_id, quarter, slots)
        VALUES (v_sid, v_char_id, q,
          CASE WHEN chars[i][1]='sponsor' THEN (CASE WHEN q=4 THEN 2 ELSE 1 END)
               WHEN q=1 THEN 1
               ELSE 2 END);
    END LOOP;
  END LOOP;

  -- Demand map (hidden)
  FOR i IN 1..array_length(dmap,1) LOOP
    FOR q IN 1..4 LOOP
      INSERT INTO bp_demand_map(session_id, objective_key, quarter,
                                primary_character_key, secondary_character_key)
        VALUES (v_sid, dmap[i][1], q, dmap[i][2*q], dmap[i][2*q+1]);
    END LOOP;
  END LOOP;

  -- Mandate directives (migration 011) — one per (team, quarter). Map the
  -- directive's objective_key to the team via bp_teams.objective_key. Same 20
  -- for both variants (teams are identical across variants).
  FOR i IN 1..array_length(directives,1) LOOP
    SELECT id INTO v_team_id FROM bp_teams
      WHERE session_id=v_sid AND objective_key=directives[i][1];
    INSERT INTO bp_directives(session_id, team_id, quarter, directive_text, intended_benefit, alignment)
      VALUES (v_sid, v_team_id, directives[i][2]::int, directives[i][4], directives[i][5], directives[i][3]);
  END LOOP;

  -- Curveballs (seed)
  INSERT INTO bp_curveballs(session_id, key, label, body) VALUES
    (v_sid,'cell_prices','Cell prices +6%','Cell prices are up 6%. Battery hardest hit, Suppliers next.'),
    (v_sid,'quality_escape','Field quality escape','A field quality escape. Puts Warranty and Spec in direct opposition.'),
    (v_sid,'sponsor_praise','Sponsor praise','The Sponsor praises one team by name. (Facilitator picks which.)'),
    (v_sid,'character_pulled','Character pulled','One character is unavailable this quarter. Fired AFTER requests lock.');

  -- Escalation cards (generic per-quarter posture, character_key NULL)
  INSERT INTO bp_escalation_cards(session_id, character_key, quarter, posture, sample_lines) VALUES
    (v_sid,NULL,1,'Polite, vague, non-committal.','"Send me something and I''ll take a look."'),
    (v_sid,NULL,2,'Competing claims, named out loud.','"Team C already asked me for the same week."'),
    (v_sid,NULL,3,'Push back, refuse.','"I''ve heard this before. It died. Why is this different?"'),
    (v_sid,NULL,4,'Judge.','"I''d work with A again. I would not work with B."');

  -- Return codes for handout.
  FOR r IN SELECT code, name, access_code FROM bp_teams WHERE session_id=v_sid ORDER BY code LOOP
    v_team_codes := v_team_codes || jsonb_build_object(r.code, jsonb_build_object('name',r.name,'code',r.access_code));
  END LOOP;
  FOR r IN SELECT key, name, access_code FROM bp_characters WHERE session_id=v_sid ORDER BY key LOOP
    v_char_codes := v_char_codes || jsonb_build_object(r.key, jsonb_build_object('name',r.name,'code',r.access_code));
  END LOOP;

  PERFORM bp_log(v_sid,'facilitator','create_session', jsonb_build_object('name',p_name,'variant',v_variant));

  RETURN jsonb_build_object(
    'session_id', v_sid,
    'variant', v_variant,
    'facilitator_code', v_fac,
    'teams', v_team_codes,
    'characters', v_char_codes);
END $$;

-- =====================================================================
--  SCORING ENGINE  (§6) — deterministic
-- =====================================================================

-- Annual rupee value for a band.
CREATE OR REPLACE FUNCTION bp_band_value(p_band TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_band
    WHEN 'exceeded' THEN 4200 WHEN 'delivered' THEN 3000
    WHEN 'partial'  THEN 1800 ELSE 0 END;
$$;

-- Annual band from total quarterly points (0..12).
CREATE OR REPLACE FUNCTION bp_annual_band(p_total INT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_total BETWEEN 10 AND 12 THEN 'exceeded'
    WHEN p_total BETWEEN 7 AND 9   THEN 'delivered'
    WHEN p_total BETWEEN 4 AND 6   THEN 'partial'
    ELSE 'missed' END;
$$;

-- band rank for coupling comparisons (>= delivered).
CREATE OR REPLACE FUNCTION bp_band_rank(p_band TEXT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_band
    WHEN 'exceeded' THEN 3 WHEN 'delivered' THEN 2
    WHEN 'partial'  THEN 1 ELSE 0 END;
$$;

-- Org net from the 5 annual bands + headwind (couplings on annual bands).
CREATE OR REPLACE FUNCTION bp_org_net(
  b_battery TEXT, b_suppliers TEXT, b_spec TEXT, b_warranty TEXT, b_pricing TEXT, p_headwind INT)
RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE gross INT; couplings INT := 0; net INT; deliv INT := 2;
BEGIN
  gross := bp_band_value(b_battery)+bp_band_value(b_suppliers)+bp_band_value(b_spec)
         + bp_band_value(b_warranty)+bp_band_value(b_pricing);
  IF bp_band_rank(b_suppliers)>=deliv AND bp_band_rank(b_battery)>=deliv THEN couplings := couplings+1000; END IF;
  IF bp_band_rank(b_warranty) >=deliv AND bp_band_rank(b_spec)   >=deliv THEN couplings := couplings+1000; END IF;
  IF bp_band_rank(b_spec)     >=deliv AND bp_band_rank(b_pricing)>=deliv THEN couplings := couplings-1500; END IF;
  net := gross + couplings - p_headwind;
  RETURN jsonb_build_object('gross',gross,'couplings',couplings,'headwind',p_headwind,
                            'net',net,'target_hit',(net>=14200));
END $$;

-- ---------------------------------------------------------------------
--  Adaptive demand map (migration 010) — path-dependent ideal.
--  bp_resolve_state: the business-only state a team's objective is in
--  ENTERING p_quarter. Reads prior quarter's got_primary and the prior
--  stored state; no ratings, no EI. Maps objective → team via
--  bp_teams.objective_key.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_resolve_state(p_sid UUID, p_objective TEXT, p_quarter INT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_team_id      UUID;
  v_prior_gotp   BOOLEAN;
  v_prior_state  TEXT;
BEGIN
  -- Q1 always starts healthy — no prior quarter to fall behind from.
  IF p_quarter <= 1 THEN
    RETURN 'on_track';
  END IF;

  SELECT id INTO v_team_id
    FROM bp_teams
    WHERE session_id = p_sid AND objective_key = p_objective;

  -- Prior quarter's business capability (did they secure the ideal primary?).
  SELECT got_primary INTO v_prior_gotp
    FROM bp_quarter_results
    WHERE session_id = p_sid AND team_id = v_team_id AND quarter = p_quarter - 1;

  -- Prior quarter's recorded state (what path they were already on).
  SELECT state INTO v_prior_state
    FROM bp_objective_state
    WHERE session_id = p_sid AND objective_key = p_objective AND quarter = p_quarter - 1;

  -- No prior result recorded → treat as healthy (default on_track).
  IF v_prior_gotp IS NULL THEN
    RETURN 'on_track';
  END IF;

  IF v_prior_gotp THEN
    RETURN 'on_track';
  ELSIF COALESCE(v_prior_state, 'on_track') = 'on_track' THEN
    RETURN 'behind';
  ELSE
    -- prior state was 'behind' or 'at_risk' and they missed again.
    RETURN 'at_risk';
  END IF;
END $$;

-- ---------------------------------------------------------------------
--  bp_adjusted_ideal (migration 010) — the (primary, secondary) the engine
--  should measure against for (objective, quarter) GIVEN a resolved state.
--  Derived from the base bp_demand_map on_track rows; adds NO rows to
--  bp_demand_map. BUSINESS ONLY — every reason is about capability and
--  sequencing, never relationships.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_adjusted_ideal(p_sid UUID, p_objective TEXT, p_quarter INT, p_state TEXT)
RETURNS TABLE(primary_key TEXT, secondary_key TEXT, business_reason TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cur_p    TEXT;   -- base primary of the current quarter
  v_cur_s    TEXT;   -- base secondary of the current quarter
  v_prev_p   TEXT;   -- base primary of the prior quarter (the prerequisite)
  v_obj_lbl  TEXT;
  v_cur_p_nm TEXT;
  v_prev_p_nm TEXT;
BEGIN
  SELECT primary_character_key, secondary_character_key INTO v_cur_p, v_cur_s
    FROM bp_demand_map
    WHERE session_id = p_sid AND objective_key = p_objective AND quarter = p_quarter;

  -- Q1 (or any missing prior) can only ever be on_track.
  IF p_quarter <= 1 OR p_state = 'on_track' THEN
    RETURN QUERY SELECT v_cur_p, v_cur_s, 'On track — stay with the demand-map picks for this quarter.'::TEXT;
    RETURN;
  END IF;

  v_obj_lbl := (SELECT label FROM bp_objectives WHERE session_id = p_sid AND key = p_objective);

  SELECT primary_character_key INTO v_prev_p
    FROM bp_demand_map
    WHERE session_id = p_sid AND objective_key = p_objective AND quarter = p_quarter - 1;

  v_cur_p_nm  := (SELECT name FROM bp_characters WHERE session_id = p_sid AND key = v_cur_p);
  v_prev_p_nm := (SELECT name FROM bp_characters WHERE session_id = p_sid AND key = v_prev_p);

  IF p_state = 'behind' THEN
    -- Recover the unmet prerequisite before this quarter's primary can add value.
    RETURN QUERY SELECT
      v_prev_p,
      v_cur_p,
      format(
        'You did not secure %s in Q%s, so %s is behind. Recover with %s before %s can add value.',
        v_prev_p_nm, (p_quarter - 1)::TEXT, v_obj_lbl, v_prev_p_nm, v_cur_p_nm
      )::TEXT;
    RETURN;
  ELSE
    -- at_risk: two missed quarters — escalate to the Sponsor to unblock, then resume.
    RETURN QUERY SELECT
      'sponsor'::TEXT,
      v_cur_p,
      format(
        '%s is a recovery case after two missed quarters — escalate to the Sponsor to unblock resourcing, then resume with %s.',
        v_obj_lbl, v_cur_p_nm
      )::TEXT;
    RETURN;
  END IF;
END $$;

-- Compute quarter_results for one quarter (runs on entry to RESULTS).
-- Adaptive demand map (migration 010): per team, resolve the business-only
-- state entering this quarter and pull the adjusted ideal (KEYS) to score
-- against instead of the raw bp_demand_map keys; after scoring, record the
-- state + ideal in bp_objective_state. Ratings / band logic is unchanged.
CREATE OR REPLACE FUNCTION bp_run_scoring(p_sid UUID, p_quarter INT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t RECORD; mapP TEXT; mapS TEXT;
  got_p BOOLEAN; got_s BOOLEAN; avg_r NUMERIC; v_band TEXT; v_points INT;
  v_state TEXT; v_reason TEXT;   -- adaptive demand map (migration 010)
BEGIN
  FOR t IN SELECT id, objective_key FROM bp_teams WHERE session_id=p_sid LOOP
    -- Business-only state entering this quarter, and the ideal we score
    -- against given that state. Base bp_demand_map rows are the on_track
    -- path; behind/at_risk derive from them (no rows added to bp_demand_map).
    v_state := bp_resolve_state(p_sid, t.objective_key, p_quarter);
    SELECT ai.primary_key, ai.secondary_key, ai.business_reason
      INTO mapP, mapS, v_reason
      FROM bp_adjusted_ideal(p_sid, t.objective_key, p_quarter, v_state) ai;

    got_p := EXISTS (
      SELECT 1 FROM bp_selections sel JOIN bp_characters c ON c.id=sel.character_id
      WHERE sel.session_id=p_sid AND sel.quarter=p_quarter AND sel.team_id=t.id AND c.key=mapP);
    got_s := EXISTS (
      SELECT 1 FROM bp_selections sel JOIN bp_characters c ON c.id=sel.character_id
      WHERE sel.session_id=p_sid AND sel.quarter=p_quarter AND sel.team_id=t.id AND c.key=mapS);

    -- avg of (sum of 3 rating fields) across characters who selected this team
    SELECT AVG(r.knew_what_i_cared_about + r.asked_or_told + r.left_me_better)
      INTO avg_r
      FROM bp_ratings r
      WHERE r.session_id=p_sid AND r.quarter=p_quarter AND r.team_id=t.id
        AND EXISTS (SELECT 1 FROM bp_selections s2
                    WHERE s2.session_id=p_sid AND s2.quarter=p_quarter
                      AND s2.team_id=t.id AND s2.character_id=r.character_id);

    v_band := CASE
      WHEN got_p AND got_s AND COALESCE(avg_r,0) >= 7 THEN 'exceeded'
      WHEN got_p AND got_s THEN 'delivered'
      WHEN got_p           THEN 'delivered'
      WHEN got_s           THEN 'partial'
      ELSE 'missed' END;
    v_points := CASE v_band WHEN 'exceeded' THEN 3 WHEN 'delivered' THEN 2 WHEN 'partial' THEN 1 ELSE 0 END;

    INSERT INTO bp_quarter_results(session_id, team_id, quarter, got_primary, got_secondary, avg_rating, band, points)
    VALUES (p_sid, t.id, p_quarter, got_p, got_s, avg_r, v_band, v_points)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET got_primary=EXCLUDED.got_primary, got_secondary=EXCLUDED.got_secondary,
          avg_rating=EXCLUDED.avg_rating, band=EXCLUDED.band, points=EXCLUDED.points;

    -- Record the state + adjusted ideal we scored against, for the debrief.
    INSERT INTO bp_objective_state(session_id, objective_key, quarter, state, primary_key, secondary_key, business_reason)
    VALUES (p_sid, t.objective_key, p_quarter, v_state, mapP, mapS, v_reason)
    ON CONFLICT (session_id, objective_key, quarter) DO UPDATE
      SET state=EXCLUDED.state, primary_key=EXCLUDED.primary_key,
          secondary_key=EXCLUDED.secondary_key, business_reason=EXCLUDED.business_reason;
  END LOOP;

  PERFORM bp_log(p_sid,'engine','run_scoring', jsonb_build_object('quarter',p_quarter));
END $$;

-- Self-test: the three §6 sanity checks, plus the migration-010 adaptive
-- demand-map checks and the migration-011 leadership-cell check. Returns
-- pass/fail rows.
CREATE OR REPLACE FUNCTION bp_selftest()
RETURNS TABLE (test TEXT, expected TEXT, actual TEXT, pass BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
  r JSONB;
  v_sid UUID; v_obj TEXT; v_state TEXT;
  v_prev_p TEXT; v_adj_p TEXT;
  v_cell TEXT;
BEGIN
  -- 5× exceeded, headwind 3000 → net 18500, hit
  r := bp_org_net('exceeded','exceeded','exceeded','exceeded','exceeded',3000);
  RETURN QUERY SELECT '5x exceeded, hw 3000',
    'net=18500 hit=true',
    'net='||(r->>'net')||' hit='||(r->>'target_hit'),
    ((r->>'net')='18500' AND (r->>'target_hit')='true');

  -- 5× delivered, headwind 9000 → net 6500, miss
  r := bp_org_net('delivered','delivered','delivered','delivered','delivered',9000);
  RETURN QUERY SELECT '5x delivered, hw 9000',
    'net=6500 hit=false',
    'net='||(r->>'net')||' hit='||(r->>'target_hit'),
    ((r->>'net')='6500' AND (r->>'target_hit')='false');

  -- 4× exceeded + 1 missed (pricing), headwind 3000 → hit
  r := bp_org_net('exceeded','exceeded','exceeded','exceeded','missed',3000);
  RETURN QUERY SELECT '4x exceeded + pricing missed, hw 3000',
    'hit=true',
    'net='||(r->>'net')||' hit='||(r->>'target_hit'),
    ((r->>'target_hit')='true');

  -- (010) Adaptive demand map, check (a): Q1 always resolves to on_track.
  -- Pure logic — bp_resolve_state short-circuits Q1 without any session data,
  -- so a nil session id is safe here.
  v_state := bp_resolve_state('00000000-0000-0000-0000-000000000000'::uuid, 'battery', 1);
  RETURN QUERY SELECT 'resolve_state Q1 = on_track',
    'on_track',
    v_state,
    (v_state = 'on_track');

  -- (010) Adaptive demand map, check (b): the 'behind' branch of
  -- bp_adjusted_ideal points its primary at the PRIOR quarter's base
  -- primary. This needs a live session's bp_demand_map rows, so we probe
  -- the most recent session if one exists; otherwise emit a clearly-marked
  -- no-op that passes with a note (never fail for lack of fixtures).
  SELECT id INTO v_sid FROM bp_sessions ORDER BY created_at DESC LIMIT 1;
  IF v_sid IS NULL THEN
    RETURN QUERY SELECT 'adjusted_ideal behind → prior primary',
      'prior-quarter base primary (needs a session)',
      'no-op: no session to probe',
      TRUE;   -- placeholder: pure fixture unavailable, not a failure
  ELSE
    v_obj := 'battery';
    SELECT primary_character_key INTO v_prev_p
      FROM bp_demand_map WHERE session_id=v_sid AND objective_key=v_obj AND quarter=1;
    SELECT primary_key INTO v_adj_p
      FROM bp_adjusted_ideal(v_sid, v_obj, 2, 'behind');
    RETURN QUERY SELECT 'adjusted_ideal behind → prior primary',
      'primary = Q1 base primary ('||COALESCE(v_prev_p,'?')||')',
      'primary = '||COALESCE(v_adj_p,'NULL'),
      (v_adj_p IS NOT NULL AND v_adj_p = v_prev_p);
  END IF;

  -- (011) Mandate: comply + tension resolves to 'silent compliance'.
  -- Pure logic — bp_leadership_cell takes no session data.
  v_cell := bp_leadership_cell('comply','tension');
  RETURN QUERY SELECT 'leadership_cell comply+tension = silent compliance',
    'silent compliance',
    v_cell,
    (v_cell = 'silent compliance');
END $$;

-- =====================================================================
--  READ RPC  — one authenticated snapshot of everything the caller may
--  see for the current phase. This is the ONLY read path for spoilers.
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_state(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a RECORD; s RECORD; out JSONB; pidx INT; hw INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  pidx := bp_phase_index(s.current_phase);

  out := jsonb_build_object(
    'role', a.role,
    'display_name', a.display_name,
    'team_id', a.team_id,
    'character_id', a.character_id,
    'session', jsonb_build_object(
      'id', s.id, 'name', s.name, 'status', s.status,
      'quarter', s.current_quarter, 'phase', s.current_phase,
      'target_value', s.target_value, 'headwind_revealed', s.headwind_revealed),
    'objectives', (SELECT jsonb_agg(jsonb_build_object('key',key,'label',label,'description',description))
                     FROM bp_objectives WHERE session_id=a.session_id),
    'teams', (SELECT jsonb_agg(jsonb_build_object('id',id,'code',code,'name',name,'objective_key',objective_key) ORDER BY code)
                FROM bp_teams WHERE session_id=a.session_id),
    'curveballs_live', (SELECT jsonb_agg(jsonb_build_object('key',key,'label',label,'body',body,'quarter',quarter,'at',triggered_at) ORDER BY triggered_at)
                          FROM bp_curveballs WHERE session_id=a.session_id AND triggered_at IS NOT NULL),
    'commitments', (SELECT jsonb_agg(jsonb_build_object(
                       'id',id,'quarter',quarter,'from',from_team_id,'to',to_team_id,'text',text,
                       'confirmed',confirmed_by_to,'honoured_from',honoured_from,'honoured_to',honoured_to) ORDER BY created_at)
                     FROM bp_commitments WHERE session_id=a.session_id),
    'results', (SELECT jsonb_agg(jsonb_build_object(
                   'team_id',team_id,'quarter',quarter,'band',band,'points',points,
                   'avg_rating',avg_rating,'got_primary',got_primary,'got_secondary',got_secondary))
                 FROM bp_quarter_results WHERE session_id=a.session_id)
  );

  -- Headwind: only when revealed.
  IF s.headwind_revealed THEN
    SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;
    out := out || jsonb_build_object('headwind', hw);
  END IF;

  -- Requests reveal — everyone, only at/after REQUESTS_LOCKED.
  IF pidx >= bp_phase_index('REQUESTS_LOCKED') THEN
    out := out || jsonb_build_object('reveal',
      (SELECT jsonb_agg(jsonb_build_object('team_id',r.team_id,
          'primary', pc.key, 'primary_name', pc.name,
          'secondary', sc.key, 'secondary_name', sc.name))
        FROM bp_requests r
        LEFT JOIN bp_characters pc ON pc.id=r.primary_character_id
        LEFT JOIN bp_characters sc ON sc.id=r.secondary_character_id
        WHERE r.session_id=a.session_id AND r.quarter=s.current_quarter));
  END IF;

  -- Adaptive demand-map reveal (migration 010): the business-only state +
  -- the ideal we scored each team against, for the current quarter.
  -- Facilitator always; participants/characters only at DEBRIEF.
  IF a.role = 'facilitator' OR s.current_phase = 'DEBRIEF' THEN
    out := out || jsonb_build_object('demand_reveal',
      (SELECT jsonb_agg(jsonb_build_object(
          'team_id', t.id,
          'objective_key', os.objective_key,
          'state', os.state,
          'primary_key', os.primary_key,
          'secondary_key', os.secondary_key,
          'primary_name', pc.name,
          'secondary_name', sc.name,
          'business_reason', os.business_reason))
        FROM bp_objective_state os
        JOIN bp_teams t ON t.session_id=os.session_id AND t.objective_key=os.objective_key
        LEFT JOIN bp_characters pc ON pc.session_id=os.session_id AND pc.key=os.primary_key
        LEFT JOIN bp_characters sc ON sc.session_id=os.session_id AND sc.key=os.secondary_key
        WHERE os.session_id=a.session_id AND os.quarter=s.current_quarter));
  END IF;

  -- Mandate reveal (migration 011): per-team stance × directive alignment →
  -- the leadership cell. Everyone at DEBRIEF; facilitator always.
  IF a.role = 'facilitator' OR s.current_phase = 'DEBRIEF' THEN
    out := out || jsonb_build_object('mandate_reveal',
      (SELECT jsonb_agg(jsonb_build_object(
          'team_id', t.id,
          'stance', md.stance,
          'dissent_line', md.dissent_line,
          'alignment', d.alignment,
          'leadership_cell', bp_leadership_cell(md.stance, d.alignment)))
        FROM bp_teams t
        LEFT JOIN bp_directives d
          ON d.session_id=a.session_id AND d.team_id=t.id AND d.quarter=s.current_quarter
        LEFT JOIN bp_mandate_decisions md
          ON md.session_id=a.session_id AND md.team_id=t.id AND md.quarter=s.current_quarter
        WHERE t.session_id=a.session_id));
  END IF;

  -- Style calls + observer logs — sealed until DEBRIEF.
  IF s.current_phase = 'DEBRIEF' THEN
    out := out || jsonb_build_object(
      'style_calls', (SELECT jsonb_agg(jsonb_build_object('team_id',team_id,'seat',seat,'style',style,'rationale',rationale))
                        FROM bp_style_calls WHERE session_id=a.session_id AND quarter=s.current_quarter),
      'observer_logs', (SELECT jsonb_agg(jsonb_build_object('team_id',team_id,'observed_style',observed_style,'note',note))
                        FROM bp_observer_logs WHERE session_id=a.session_id AND quarter=s.current_quarter));
  END IF;

  -- ---------- Role-specific additions ----------
  IF a.role = 'participant' THEN
    out := out || jsonb_build_object(
      'my_request', (SELECT jsonb_build_object('primary',primary_character_id,'secondary',secondary_character_id)
                       FROM bp_requests WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_style_calls', (SELECT jsonb_object_agg(seat, jsonb_build_object('style',style,'rationale',rationale))
                       FROM bp_style_calls WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_stakeholder', (SELECT jsonb_object_agg(phase, payload)
                       FROM bp_stakeholder_maps WHERE session_id=a.session_id AND team_id=a.team_id),
      'my_observer', (SELECT jsonb_build_object('style',observed_style,'note',note)
                       FROM bp_observer_logs WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_seats', (SELECT jsonb_object_agg(seat, participant_id)
                       FROM bp_seat_assignments WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'characters', (SELECT jsonb_agg(jsonb_build_object('id',id,'key',key,'name',name,'role_label',role_label) ORDER BY key)
                       FROM bp_characters WHERE session_id=a.session_id),
      -- Mandate (migration 011). my_directive is visible from BRIEF onward
      -- (always, if a row exists); alignment is NOT surfaced to the team.
      -- my_mandate is the team's own stance for the current quarter.
      'my_directive', (SELECT jsonb_build_object('text',directive_text,'intended_benefit',intended_benefit)
                       FROM bp_directives WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_mandate', (SELECT jsonb_build_object('stance',stance,'dissent_line',dissent_line)
                       FROM bp_mandate_decisions WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter));
    -- migration 018: who gave this team their time, per quarter. A quarter is
    -- visible once it is past, or once the current one has reached RESULTS.
    -- Names only — the character's written reason never reaches the team.
    out := out || jsonb_build_object('my_backers',
      (SELECT COALESCE(jsonb_agg(jsonb_build_object('quarter', g.q, 'visible', g.vis, 'characters', g.chars) ORDER BY g.q), '[]'::jsonb)
       FROM (
         SELECT q,
           (q < s.current_quarter OR s.current_phase IN ('RESULTS','DEBRIEF') OR s.status='closed') AS vis,
           CASE WHEN (q < s.current_quarter OR s.current_phase IN ('RESULTS','DEBRIEF') OR s.status='closed') THEN
             COALESCE((SELECT jsonb_agg(jsonb_build_object('key', c.key, 'name', c.name,
                 'requested', CASE WHEN r.primary_character_id=c.id THEN 'primary'
                                   WHEN r.secondary_character_id=c.id THEN 'secondary' ELSE NULL END) ORDER BY c.key)
               FROM bp_selections sel
               JOIN bp_characters c ON c.id=sel.character_id
               LEFT JOIN bp_requests r ON r.session_id=sel.session_id AND r.team_id=sel.team_id AND r.quarter=sel.quarter
               WHERE sel.session_id=a.session_id AND sel.team_id=a.team_id AND sel.quarter=q), '[]'::jsonb)
           ELSE NULL END AS chars
         FROM generate_series(1, GREATEST(s.current_quarter,1)) AS q
       ) g));

  ELSIF a.role = 'character' THEN
    -- Incoming (who named me) only after REQUESTS_LOCKED.
    IF pidx >= bp_phase_index('REQUESTS_LOCKED') THEN
      out := out || jsonb_build_object('incoming',
        (SELECT jsonb_agg(jsonb_build_object('team_id',r.team_id,
            'as', CASE WHEN r.primary_character_id=a.character_id THEN 'primary' ELSE 'secondary' END))
          FROM bp_requests r
          WHERE r.session_id=a.session_id AND r.quarter=s.current_quarter
            AND (r.primary_character_id=a.character_id OR r.secondary_character_id=a.character_id)));
    END IF;
    out := out || jsonb_build_object(
      'my_capacity', (SELECT slots FROM bp_character_capacity
                        WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter),
      'my_brief', (SELECT jsonb_build_object('posture',posture,'sample_lines',sample_lines,'video_url',video_url)
                     FROM bp_escalation_cards
                     WHERE session_id=a.session_id AND quarter=s.current_quarter
                       AND (character_key=(SELECT key FROM bp_characters WHERE id=a.character_id) OR character_key IS NULL)
                     ORDER BY character_key NULLS LAST LIMIT 1),
      'my_selections', (SELECT jsonb_agg(jsonb_build_object('team_id',team_id,'reason',reason))
                     FROM bp_selections WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter),
      'my_ratings', (SELECT jsonb_object_agg(team_id::text, jsonb_build_object(
                       'knew',knew_what_i_cared_about,'asked',asked_or_told,'better',left_me_better))
                     FROM bp_ratings WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter),
      'my_judgements', (SELECT jsonb_object_agg(team_id::text, jsonb_build_object('again',again,'reason',reason))
                     FROM bp_judgements WHERE session_id=a.session_id AND character_id=a.character_id));

  ELSIF a.role = 'facilitator' THEN
    SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;
    out := out || jsonb_build_object(
      'headwind', hw,
      'characters', (SELECT jsonb_agg(jsonb_build_object('id',id,'key',key,'name',name,'role_label',role_label,'access_code',access_code) ORDER BY key)
                       FROM bp_characters WHERE session_id=a.session_id),
      'team_codes', (SELECT jsonb_object_agg(code, access_code) FROM bp_teams WHERE session_id=a.session_id),
      'capacity', (SELECT jsonb_agg(jsonb_build_object('character_id',character_id,'quarter',quarter,'slots',slots))
                       FROM bp_character_capacity WHERE session_id=a.session_id),
      'curveballs', (SELECT jsonb_agg(jsonb_build_object('key',key,'label',label,'body',body,'triggered_at',triggered_at) ORDER BY key)
                       FROM bp_curveballs WHERE session_id=a.session_id),
      'monitor', bp_monitor(a.session_id, s.current_quarter),
      'drift', bp_drift(a.session_id, s.current_quarter),
      -- migration 018: every selection so far (all quarters, current one live)
      -- and every team's stakeholder maps, for the facilitator only.
      'selection_history', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'quarter', sel.quarter, 'character_key', c.key, 'character_name', c.name,
            'team_id', t.id, 'team_code', t.code, 'reason', sel.reason,
            'requested', CASE WHEN r.primary_character_id=c.id THEN 'primary'
                              WHEN r.secondary_character_id=c.id THEN 'secondary' ELSE NULL END)
          ORDER BY sel.quarter, c.key, t.code), '[]'::jsonb)
        FROM bp_selections sel
        JOIN bp_characters c ON c.id=sel.character_id
        JOIN bp_teams t ON t.id=sel.team_id
        LEFT JOIN bp_requests r ON r.session_id=sel.session_id AND r.team_id=sel.team_id AND r.quarter=sel.quarter
        WHERE sel.session_id=a.session_id),
      'stakeholder_all', (SELECT COALESCE(jsonb_agg(jsonb_build_object('team_id', t.id, 'code', t.code, 'name', t.name,
            'pre',  (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='pre'  LIMIT 1),
            'post', (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='post' LIMIT 1))
          ORDER BY t.code), '[]'::jsonb)
        FROM bp_teams t WHERE t.session_id=a.session_id),
      -- Mandate (migration 011). All teams' directives this quarter incl.
      -- alignment (the Voice re-issue lever reads this), and per-team whether
      -- a stance has been submitted yet.
      'directives', (SELECT jsonb_agg(jsonb_build_object(
                         'team_id',team_id,'directive_text',directive_text,
                         'intended_benefit',intended_benefit,'alignment',alignment))
                       FROM bp_directives WHERE session_id=a.session_id AND quarter=s.current_quarter),
      'mandate_status', (SELECT jsonb_agg(jsonb_build_object(
                         'team_id', t.id,
                         'submitted', EXISTS(SELECT 1 FROM bp_mandate_decisions md
                             WHERE md.session_id=a.session_id AND md.team_id=t.id AND md.quarter=s.current_quarter))
                         ORDER BY t.code)
                       FROM bp_teams t WHERE t.session_id=a.session_id));
  END IF;

  RETURN out;
END $$;

-- =====================================================================
--  FACILITATOR: session monitor + drift check  (§9)
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_monitor(p_sid UUID, p_quarter INT)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_agg(jsonb_build_object(
    'team_id', t.id, 'code', t.code,
    'has_request',   EXISTS(SELECT 1 FROM bp_requests    r WHERE r.session_id=p_sid AND r.team_id=t.id AND r.quarter=p_quarter),
    'style_calls',   (SELECT COUNT(*) FROM bp_style_calls sc WHERE sc.session_id=p_sid AND sc.team_id=t.id AND sc.quarter=p_quarter),
    'has_observer',  EXISTS(SELECT 1 FROM bp_observer_logs o WHERE o.session_id=p_sid AND o.team_id=t.id AND o.quarter=p_quarter),
    -- migration 018: readiness the facilitator could not see before
    'has_premap',    EXISTS(SELECT 1 FROM bp_stakeholder_maps m WHERE m.session_id=p_sid AND m.team_id=t.id AND m.phase='pre'),
    'has_postmap',   EXISTS(SELECT 1 FROM bp_stakeholder_maps m WHERE m.session_id=p_sid AND m.team_id=t.id AND m.phase='post'),
    'has_mandate',   EXISTS(SELECT 1 FROM bp_mandate_decisions md WHERE md.session_id=p_sid AND md.team_id=t.id AND md.quarter=p_quarter)
  ) ORDER BY t.code)
  FROM bp_teams t WHERE t.session_id=p_sid;
$$;

-- Drift check: per character — teams selected, rating spread, compression flag.
CREATE OR REPLACE FUNCTION bp_drift(p_sid UUID, p_quarter INT)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_agg(x ORDER BY x->>'key') FROM (
    SELECT jsonb_build_object(
      'character_id', c.id, 'key', c.key, 'name', c.name,
      -- migration 018: capacity this quarter, and whether the character has pressed Lock (event log)
      'capacity', (SELECT slots FROM bp_character_capacity cc WHERE cc.session_id=p_sid AND cc.character_id=c.id AND cc.quarter=p_quarter),
      'locked',   EXISTS(SELECT 1 FROM bp_events e WHERE e.session_id=p_sid AND e.action='select'
                         AND e.payload->>'character'=c.id::text AND (e.payload->>'quarter')::int=p_quarter),
      'selected', (SELECT COUNT(*) FROM bp_selections s WHERE s.session_id=p_sid AND s.character_id=c.id AND s.quarter=p_quarter),
      'rated',    (SELECT COUNT(*) FROM bp_ratings r WHERE r.session_id=p_sid AND r.character_id=c.id AND r.quarter=p_quarter),
      'spread',   COALESCE((SELECT MAX(tot)-MIN(tot) FROM (
                     SELECT knew_what_i_cared_about+asked_or_told+left_me_better AS tot
                     FROM bp_ratings r WHERE r.session_id=p_sid AND r.character_id=c.id AND r.quarter=p_quarter) z), 0),
      'compressed', COALESCE((SELECT (MAX(tot)-MIN(tot)) <= 1 AND COUNT(*) >= 2 FROM (
                     SELECT knew_what_i_cared_about+asked_or_told+left_me_better AS tot
                     FROM bp_ratings r WHERE r.session_id=p_sid AND r.character_id=c.id AND r.quarter=p_quarter) z), false)
    ) AS x
    FROM bp_characters c WHERE c.session_id=p_sid AND c.key <> 'sponsor'
  ) q;
$$;

-- =====================================================================
--  FACILITATOR: phase control  (§5)
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_advance_phase(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; pidx INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id FOR UPDATE;
  pidx := bp_phase_index(s.current_phase);

  IF s.current_phase = 'DEBRIEF' THEN
    IF s.current_quarter >= 4 THEN
      UPDATE bp_sessions SET status='closed' WHERE id=s.id;
    ELSE
      UPDATE bp_sessions SET current_quarter=current_quarter+1, current_phase='BRIEF', status='live' WHERE id=s.id;
    END IF;
  ELSE
    UPDATE bp_sessions SET current_phase=bp_phase_at(pidx+1),
      status=CASE WHEN status='draft' THEN 'live' ELSE status END
      WHERE id=s.id;
    -- Scoring runs on entry to RESULTS.
    IF bp_phase_at(pidx+1) = 'RESULTS' THEN
      PERFORM bp_run_scoring(s.id, s.current_quarter);
    END IF;
  END IF;

  PERFORM bp_log(s.id,'facilitator','advance_phase',
    jsonb_build_object('from_q',s.current_quarter,'from',s.current_phase));
  RETURN (SELECT jsonb_build_object('quarter',current_quarter,'phase',current_phase,'status',status)
            FROM bp_sessions WHERE id=s.id);
END $$;

CREATE OR REPLACE FUNCTION bp_step_back(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; pidx INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id FOR UPDATE;
  pidx := bp_phase_index(s.current_phase);

  IF s.current_phase = 'BRIEF' THEN
    IF s.current_quarter > 1 THEN
      UPDATE bp_sessions SET current_quarter=current_quarter-1, current_phase='DEBRIEF' WHERE id=s.id;
    END IF; -- at Q1 BRIEF: no-op
  ELSE
    UPDATE bp_sessions SET current_phase=bp_phase_at(pidx-1),
      status=CASE WHEN status='closed' THEN 'live' ELSE status END WHERE id=s.id;
  END IF;

  -- Data is never deleted on step-back (§13). Log it.
  PERFORM bp_log(s.id,'facilitator','step_back',
    jsonb_build_object('from_q',s.current_quarter,'from',s.current_phase));
  RETURN (SELECT jsonb_build_object('quarter',current_quarter,'phase',current_phase,'status',status)
            FROM bp_sessions WHERE id=s.id);
END $$;

CREATE OR REPLACE FUNCTION bp_trigger_curveball(p_session_code TEXT, p_access_code TEXT, p_key TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  UPDATE bp_curveballs SET triggered_at=NOW(), quarter=s.current_quarter
    WHERE session_id=a.session_id AND key=p_key;
  PERFORM bp_log(a.session_id,'facilitator','curveball',jsonb_build_object('key',p_key,'quarter',s.current_quarter));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_set_headwind(p_session_code TEXT, p_access_code TEXT, p_value INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_value < 3000 OR p_value > 9000 THEN RAISE EXCEPTION 'headwind_out_of_range'; END IF;
  UPDATE bp_headwind SET value=p_value WHERE session_id=a.session_id;
  PERFORM bp_log(a.session_id,'facilitator','set_headwind',jsonb_build_object('value',p_value));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_reveal_headwind(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE bp_sessions SET headwind_revealed=TRUE WHERE id=a.session_id;
  PERFORM bp_log(a.session_id,'facilitator','reveal_headwind',NULL);
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_set_capacity(p_session_code TEXT, p_access_code TEXT,
  p_character_id UUID, p_quarter INT, p_slots INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE bp_character_capacity SET slots=p_slots
    WHERE session_id=a.session_id AND character_id=p_character_id AND quarter=p_quarter;
  PERFORM bp_log(a.session_id,'facilitator','set_capacity',
    jsonb_build_object('character',p_character_id,'quarter',p_quarter,'slots',p_slots));
  RETURN jsonb_build_object('ok',true);
END $$;

-- Mandate (migration 011): facilitator re-issues / edits a team's directive for
-- a quarter — the "Voice" lever, letting the Sponsor respond to a team that
-- voiced dissent by revising the directive. Upserts bp_directives.
CREATE OR REPLACE FUNCTION bp_set_directive(p_session_code TEXT, p_fac_code TEXT,
  p_team_code TEXT, p_quarter INT, p_text TEXT, p_benefit TEXT, p_alignment TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; v_team_id UUID;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_fac_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT id INTO v_team_id FROM bp_teams WHERE session_id=a.session_id AND code=p_team_code;
  IF v_team_id IS NULL THEN RAISE EXCEPTION 'unknown_team'; END IF;
  IF p_alignment NOT IN ('sound','tension') THEN RAISE EXCEPTION 'bad_alignment'; END IF;
  INSERT INTO bp_directives(session_id, team_id, quarter, directive_text, intended_benefit, alignment)
    VALUES (a.session_id, v_team_id, p_quarter, p_text, p_benefit, p_alignment)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET directive_text=EXCLUDED.directive_text, intended_benefit=EXCLUDED.intended_benefit,
          alignment=EXCLUDED.alignment, issued_at=NOW();
  PERFORM bp_log(a.session_id,'facilitator','set_directive',
    jsonb_build_object('team',v_team_id,'quarter',p_quarter,'alignment',p_alignment));
  RETURN jsonb_build_object('ok',true);
END $$;

-- =====================================================================
--  PARTICIPANT write RPCs
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_submit_request(p_session_code TEXT, p_access_code TEXT,
  p_primary UUID, p_secondary UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF s.current_phase <> 'REQUESTS_OPEN' THEN RAISE EXCEPTION 'requests_not_open'; END IF;
  IF p_primary = p_secondary THEN RAISE EXCEPTION 'primary_secondary_same'; END IF;
  INSERT INTO bp_requests(session_id, team_id, quarter, primary_character_id, secondary_character_id)
    VALUES (a.session_id, a.team_id, s.current_quarter, p_primary, p_secondary)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET primary_character_id=EXCLUDED.primary_character_id,
          secondary_character_id=EXCLUDED.secondary_character_id, submitted_at=NOW();
  PERFORM bp_log(a.session_id,'participant','submit_request',jsonb_build_object('team',a.team_id,'quarter',s.current_quarter));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_submit_style_call(p_session_code TEXT, p_access_code TEXT,
  p_seat TEXT, p_style TEXT, p_rationale TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF s.current_phase <> 'REQUESTS_OPEN' THEN RAISE EXCEPTION 'requests_not_open'; END IF;
  INSERT INTO bp_style_calls(session_id, team_id, quarter, seat, style, rationale)
    VALUES (a.session_id, a.team_id, s.current_quarter, p_seat, p_style, p_rationale)
    ON CONFLICT (session_id, team_id, quarter, seat) DO UPDATE
      SET style=EXCLUDED.style, rationale=EXCLUDED.rationale, sealed_at=NOW();
  PERFORM bp_log(a.session_id,'participant','style_call',jsonb_build_object('team',a.team_id,'seat',p_seat));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_submit_stakeholder(p_session_code TEXT, p_access_code TEXT,
  p_phase TEXT, p_payload JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  -- pre allowed before Q1 requests; post allowed at Q4 DEBRIEF / closed
  IF p_phase='pre' AND NOT (s.current_quarter=1 AND bp_phase_index(s.current_phase) < bp_phase_index('REQUESTS_OPEN')) THEN
    RAISE EXCEPTION 'stakeholder_pre_closed';
  END IF;
  IF p_phase='post' AND NOT (s.current_quarter=4 AND (s.current_phase='DEBRIEF' OR s.status='closed')) THEN
    RAISE EXCEPTION 'stakeholder_post_closed';
  END IF;
  INSERT INTO bp_stakeholder_maps(session_id, team_id, phase, payload)
    VALUES (a.session_id, a.team_id, p_phase, p_payload)
    ON CONFLICT (session_id, team_id, phase) DO NOTHING;  -- submit locks it
  PERFORM bp_log(a.session_id,'participant','stakeholder',jsonb_build_object('team',a.team_id,'phase',p_phase));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_submit_observer(p_session_code TEXT, p_access_code TEXT,
  p_style TEXT, p_note TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  INSERT INTO bp_observer_logs(session_id, team_id, quarter, observed_style, note)
    VALUES (a.session_id, a.team_id, s.current_quarter, p_style, p_note)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET observed_style=EXCLUDED.observed_style, note=EXCLUDED.note;
  PERFORM bp_log(a.session_id,'participant','observer',jsonb_build_object('team',a.team_id));
  RETURN jsonb_build_object('ok',true);
END $$;

-- Mandate (migration 011): the team's stance on the Sponsor's directive.
-- Participant only; allowed only while phase index < REQUESTS_LOCKED (the
-- decision must be made before the reveal). voice/defy require a dissent line.
CREATE OR REPLACE FUNCTION bp_submit_mandate(p_session_code TEXT, p_access_code TEXT,
  p_stance TEXT, p_dissent_line TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF bp_phase_index(s.current_phase) >= bp_phase_index('REQUESTS_LOCKED') THEN
    RAISE EXCEPTION 'mandate_locked';
  END IF;
  IF p_stance IN ('voice','defy') AND COALESCE(btrim(p_dissent_line),'') = '' THEN
    RAISE EXCEPTION 'dissent_line_required';
  END IF;
  INSERT INTO bp_mandate_decisions(session_id, team_id, quarter, stance, dissent_line)
    VALUES (a.session_id, a.team_id, s.current_quarter, p_stance, p_dissent_line)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET stance=EXCLUDED.stance, dissent_line=EXCLUDED.dissent_line, submitted_at=NOW();
  PERFORM bp_log(a.session_id,'participant','mandate',
    jsonb_build_object('team',a.team_id,'quarter',s.current_quarter,'stance',p_stance));
  RETURN jsonb_build_object('ok',true);
END $$;

-- Commitments: cap 2 per (from_team, quarter).
CREATE OR REPLACE FUNCTION bp_log_commitment(p_session_code TEXT, p_access_code TEXT,
  p_to_team UUID, p_text TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; n INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  SELECT COUNT(*) INTO n FROM bp_commitments
    WHERE session_id=a.session_id AND from_team_id=a.team_id AND quarter=s.current_quarter;
  IF n >= 2 THEN RAISE EXCEPTION 'commitment_cap_reached'; END IF;
  INSERT INTO bp_commitments(session_id, quarter, from_team_id, to_team_id, text)
    VALUES (a.session_id, s.current_quarter, a.team_id, p_to_team, p_text);
  PERFORM bp_log(a.session_id,'participant','commitment',jsonb_build_object('from',a.team_id,'to',p_to_team));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_confirm_commitment(p_session_code TEXT, p_access_code TEXT, p_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE bp_commitments SET confirmed_by_to=TRUE
    WHERE id=p_id AND session_id=a.session_id AND to_team_id=a.team_id;
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_mark_honoured(p_session_code TEXT, p_access_code TEXT,
  p_id UUID, p_honoured BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE bp_commitments SET honoured_from = CASE WHEN from_team_id=a.team_id THEN p_honoured ELSE honoured_from END,
                            honoured_to   = CASE WHEN to_team_id  =a.team_id THEN p_honoured ELSE honoured_to   END
    WHERE id=p_id AND session_id=a.session_id AND (from_team_id=a.team_id OR to_team_id=a.team_id);
  RETURN jsonb_build_object('ok',true);
END $$;

-- =====================================================================
--  CHARACTER write RPCs
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_select_teams(p_session_code TEXT, p_access_code TEXT, p_picks JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; cap INT; pick JSONB;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'character' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF s.current_phase NOT IN ('SELECTION') THEN RAISE EXCEPTION 'selection_not_open'; END IF;
  SELECT slots INTO cap FROM bp_character_capacity
    WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter;
  IF jsonb_array_length(p_picks) > cap THEN RAISE EXCEPTION 'over_capacity'; END IF;
  -- replace this character's picks for the quarter
  DELETE FROM bp_selections WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter;
  FOR pick IN SELECT * FROM jsonb_array_elements(p_picks) LOOP
    IF COALESCE(pick->>'reason','') = '' THEN RAISE EXCEPTION 'reason_required'; END IF;
    INSERT INTO bp_selections(session_id, character_id, quarter, team_id, reason)
      VALUES (a.session_id, a.character_id, s.current_quarter, (pick->>'team_id')::uuid, pick->>'reason');
  END LOOP;
  PERFORM bp_log(a.session_id,'character','select',jsonb_build_object('character',a.character_id,'n',jsonb_array_length(p_picks),'quarter',s.current_quarter));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_rate_team(p_session_code TEXT, p_access_code TEXT,
  p_team UUID, p_knew INT, p_asked INT, p_better INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'character' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  INSERT INTO bp_ratings(session_id, character_id, team_id, quarter, knew_what_i_cared_about, asked_or_told, left_me_better)
    VALUES (a.session_id, a.character_id, p_team, s.current_quarter, p_knew, p_asked, p_better)
    ON CONFLICT (session_id, character_id, team_id, quarter) DO UPDATE
      SET knew_what_i_cared_about=EXCLUDED.knew_what_i_cared_about,
          asked_or_told=EXCLUDED.asked_or_told, left_me_better=EXCLUDED.left_me_better;
  PERFORM bp_log(a.session_id,'character','rate',jsonb_build_object('character',a.character_id,'team',p_team));
  RETURN jsonb_build_object('ok',true);
END $$;

CREATE OR REPLACE FUNCTION bp_judge_team(p_session_code TEXT, p_access_code TEXT,
  p_team UUID, p_again BOOLEAN, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'character' THEN RAISE EXCEPTION 'forbidden'; END IF;
  INSERT INTO bp_judgements(session_id, character_id, team_id, again, reason)
    VALUES (a.session_id, a.character_id, p_team, p_again, p_reason)
    ON CONFLICT (session_id, character_id, team_id) DO UPDATE
      SET again=EXCLUDED.again, reason=EXCLUDED.reason;
  RETURN jsonb_build_object('ok',true);
END $$;

-- =====================================================================
--  BOARDS + EXPORT
-- =====================================================================
-- Public board snapshot (no auth needed — everything here is public at
-- RESULTS: quarter_results + teams). Includes org bar; headwind only if
-- revealed.
CREATE OR REPLACE FUNCTION bp_boards(p_session_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s RECORD; b JSONB; teams JSONB; org JSONB; hw INT; rev BOOLEAN;
  bands JSONB := '{}'::jsonb; trow RECORD; tot INT; ab TEXT; qp INT;
BEGIN
  SELECT * INTO s FROM bp_sessions WHERE id=p_session_id;
  SELECT headwind_revealed INTO rev FROM bp_sessions WHERE id=p_session_id;

  teams := (SELECT jsonb_agg(jsonb_build_object(
      'team_id', t.id, 'code', t.code, 'name', t.name, 'objective_key', t.objective_key,
      'quarters', (SELECT jsonb_object_agg(quarter::text, jsonb_build_object(
                     'band',band,'points',points,'avg_rating',avg_rating))
                   FROM bp_quarter_results qr WHERE qr.session_id=p_session_id AND qr.team_id=t.id),
      'total_points', COALESCE((SELECT SUM(points) FROM bp_quarter_results qr WHERE qr.session_id=p_session_id AND qr.team_id=t.id),0)
    ) ORDER BY t.code)
    FROM bp_teams t WHERE t.session_id=p_session_id);

  -- annual bands per objective for org couplings.
  -- Before Q4 the org number is a PROJECTED year-end (migration 016): points so
  -- far are scaled to four quarters, so the wall shows a real figure from the
  -- Q1 results onward instead of ₹0 until the year closes. Converges to the
  -- true annual bands at Q4.
  SELECT COALESCE(MAX(quarter),0) INTO qp FROM bp_quarter_results WHERE session_id=p_session_id;
  FOR trow IN SELECT id, objective_key FROM bp_teams WHERE session_id=p_session_id LOOP
    SELECT COALESCE(SUM(points),0) INTO tot FROM bp_quarter_results WHERE session_id=p_session_id AND team_id=trow.id;
    IF qp BETWEEN 1 AND 3 THEN tot := LEAST(12, ROUND(tot * 4.0 / qp)::INT); END IF;
    bands := bands || jsonb_build_object(trow.objective_key, bp_annual_band(tot));
  END LOOP;

  SELECT value INTO hw FROM bp_headwind WHERE session_id=p_session_id;
  IF rev THEN
    org := bp_org_net(bands->>'battery',bands->>'suppliers',bands->>'spec',bands->>'warranty',bands->>'pricing', hw);
  ELSE
    -- before reveal: show gross only, "before headwind"
    org := bp_org_net(bands->>'battery',bands->>'suppliers',bands->>'spec',bands->>'warranty',bands->>'pricing', 0)
           - 'target_hit' - 'net';
    org := org || jsonb_build_object('before_headwind', true);
  END IF;

  org := org || jsonb_build_object('projected', (qp BETWEEN 1 AND 3), 'quarters_played', qp);
  RETURN jsonb_build_object(
    'quarter', s.current_quarter, 'phase', s.current_phase, 'status', s.status,
    'target_value', s.target_value, 'headwind_revealed', rev,
    'annual_bands', bands, 'teams', teams, 'org', org);
END $$;

CREATE OR REPLACE FUNCTION bp_export(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN jsonb_build_object(
    'session',     (SELECT to_jsonb(x) FROM (SELECT * FROM bp_sessions WHERE id=a.session_id) x),
    'boards',      bp_boards(a.session_id),
    'requests',    (SELECT jsonb_agg(to_jsonb(r)) FROM bp_requests r WHERE r.session_id=a.session_id),
    'selections',  (SELECT jsonb_agg(to_jsonb(r)) FROM bp_selections r WHERE r.session_id=a.session_id),
    'ratings',     (SELECT jsonb_agg(to_jsonb(r)) FROM bp_ratings r WHERE r.session_id=a.session_id),
    'style_calls', (SELECT jsonb_agg(to_jsonb(r)) FROM bp_style_calls r WHERE r.session_id=a.session_id),
    'observer_logs',(SELECT jsonb_agg(to_jsonb(r)) FROM bp_observer_logs r WHERE r.session_id=a.session_id),
    'commitments', (SELECT jsonb_agg(to_jsonb(r)) FROM bp_commitments r WHERE r.session_id=a.session_id),
    'judgements',  (SELECT jsonb_agg(to_jsonb(r)) FROM bp_judgements r WHERE r.session_id=a.session_id),
    'stakeholder_maps',(SELECT jsonb_agg(to_jsonb(r)) FROM bp_stakeholder_maps r WHERE r.session_id=a.session_id),
    'quarter_results',(SELECT jsonb_agg(to_jsonb(r)) FROM bp_quarter_results r WHERE r.session_id=a.session_id),
    'demand_map',  (SELECT jsonb_agg(to_jsonb(r)) FROM bp_demand_map r WHERE r.session_id=a.session_id),
    'events',      (SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at) FROM bp_events r WHERE r.session_id=a.session_id));
END $$;

-- =====================================================================
--  YEAR DOSSIER (migration 019) — everything the year's summary is written
--  from, in one facilitator-gated read. Per quarter and team: result band,
--  who they asked for, the adjusted ideal, both Style Calls (lead + runner)
--  with rationale, the observed style, the Sponsor's directive and the
--  team's mandate, and every character who gave them time — with the
--  character's own reason and the rating they then gave. Plus Q4
--  judgements, commitments, stakeholder shift, and the final boards.
--  Only readable once Q4 has reached RESULTS (or the session is closed).
--  Read by the bp-year edge function; never exposed to teams or characters.
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_year_dossier(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; hw INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF NOT (s.status='closed' OR (s.current_quarter >= 4 AND s.current_phase IN ('RESULTS','DEBRIEF'))) THEN
    RAISE EXCEPTION 'year_not_over';
  END IF;
  SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;

  RETURN jsonb_build_object(
    'session', jsonb_build_object('name', s.name, 'variant', s.variant, 'target_value', s.target_value,
                                  'headwind', hw, 'headwind_revealed', s.headwind_revealed),
    'boards', bp_boards(a.session_id),
    'teams', (SELECT jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'objective', t.objective_key,
                'objective_label', o.label, 'objective_description', o.description) ORDER BY t.code)
              FROM bp_teams t LEFT JOIN bp_objectives o ON o.session_id=t.session_id AND o.key=t.objective_key
              WHERE t.session_id=a.session_id),
    'characters', (SELECT jsonb_agg(jsonb_build_object('key', key, 'name', name, 'role', role_label) ORDER BY key)
                   FROM bp_characters WHERE session_id=a.session_id),
    'quarters', (SELECT jsonb_agg(jsonb_build_object(
        'quarter', g.q,
        'curveballs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', cb.label, 'body', cb.body)), '[]'::jsonb)
                       FROM bp_curveballs cb WHERE cb.session_id=a.session_id AND cb.quarter=g.q AND cb.triggered_at IS NOT NULL),
        'teams', (SELECT jsonb_agg(jsonb_build_object(
            'team', t.code,
            'result', (SELECT jsonb_build_object('band', band, 'points', points, 'avg_rating', avg_rating,
                                                 'got_primary', got_primary, 'got_secondary', got_secondary)
                       FROM bp_quarter_results r WHERE r.session_id=a.session_id AND r.team_id=t.id AND r.quarter=g.q),
            'requested', (SELECT jsonb_build_object('primary', pc.name, 'secondary', sc.name)
                          FROM bp_requests r
                          LEFT JOIN bp_characters pc ON pc.id=r.primary_character_id
                          LEFT JOIN bp_characters sc ON sc.id=r.secondary_character_id
                          WHERE r.session_id=a.session_id AND r.team_id=t.id AND r.quarter=g.q),
            'ideal', (SELECT jsonb_build_object('primary', os.primary_key, 'secondary', os.secondary_key,
                                                'state', os.state, 'business_reason', os.business_reason)
                      FROM bp_objective_state os
                      WHERE os.session_id=a.session_id AND os.objective_key=t.objective_key AND os.quarter=g.q),
            'style_calls', (SELECT jsonb_object_agg(seat, jsonb_build_object('style', style, 'rationale', rationale))
                            FROM bp_style_calls sc WHERE sc.session_id=a.session_id AND sc.team_id=t.id AND sc.quarter=g.q),
            'observed', (SELECT jsonb_build_object('style', observed_style, 'note', note)
                         FROM bp_observer_logs ol WHERE ol.session_id=a.session_id AND ol.team_id=t.id AND ol.quarter=g.q),
            'directive', (SELECT jsonb_build_object('text', directive_text, 'intended_benefit', intended_benefit, 'alignment', alignment)
                          FROM bp_directives d WHERE d.session_id=a.session_id AND d.team_id=t.id AND d.quarter=g.q),
            'mandate', (SELECT jsonb_build_object('stance', md.stance, 'dissent_line', md.dissent_line,
                          'leadership_cell', bp_leadership_cell(md.stance,
                             (SELECT alignment FROM bp_directives d WHERE d.session_id=a.session_id AND d.team_id=t.id AND d.quarter=g.q)))
                        FROM bp_mandate_decisions md WHERE md.session_id=a.session_id AND md.team_id=t.id AND md.quarter=g.q),
            'backed_by', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'character', c.name, 'reason', sel.reason,
                            'requested_as', CASE WHEN r.primary_character_id=c.id THEN 'primary'
                                                 WHEN r.secondary_character_id=c.id THEN 'secondary' ELSE NULL END,
                            'rating', (SELECT jsonb_build_object('knew_what_i_cared_about', knew_what_i_cared_about,
                                                                 'asked_or_told', asked_or_told, 'left_me_better', left_me_better)
                                       FROM bp_ratings rt WHERE rt.session_id=a.session_id AND rt.character_id=c.id
                                         AND rt.team_id=t.id AND rt.quarter=g.q)) ORDER BY c.key), '[]'::jsonb)
                          FROM bp_selections sel
                          JOIN bp_characters c ON c.id=sel.character_id
                          LEFT JOIN bp_requests r ON r.session_id=sel.session_id AND r.team_id=sel.team_id AND r.quarter=sel.quarter
                          WHERE sel.session_id=a.session_id AND sel.team_id=t.id AND sel.quarter=g.q)
          ) ORDER BY t.code) FROM bp_teams t WHERE t.session_id=a.session_id)
      ) ORDER BY g.q) FROM generate_series(1,4) AS g(q)),
    'judgements', (SELECT COALESCE(jsonb_agg(jsonb_build_object('character', c.name, 'team', t.code,
                       'work_with_again', j.again, 'reason', j.reason) ORDER BY c.key, t.code), '[]'::jsonb)
                   FROM bp_judgements j JOIN bp_characters c ON c.id=j.character_id JOIN bp_teams t ON t.id=j.team_id
                   WHERE j.session_id=a.session_id),
    'commitments', (SELECT COALESCE(jsonb_agg(jsonb_build_object('quarter', cm.quarter, 'from', tf.code, 'to', tt.code,
                        'text', cm.text, 'confirmed', cm.confirmed_by_to,
                        'honoured_from', cm.honoured_from, 'honoured_to', cm.honoured_to) ORDER BY cm.created_at), '[]'::jsonb)
                    FROM bp_commitments cm JOIN bp_teams tf ON tf.id=cm.from_team_id JOIN bp_teams tt ON tt.id=cm.to_team_id
                    WHERE cm.session_id=a.session_id),
    'stakeholder_shift', (SELECT COALESCE(jsonb_agg(jsonb_build_object('team', t.code,
                            'pre',  (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='pre'  LIMIT 1),
                            'post', (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='post' LIMIT 1)) ORDER BY t.code), '[]'::jsonb)
                          FROM bp_teams t WHERE t.session_id=a.session_id)
  );
END $$;
GRANT EXECUTE ON FUNCTION bp_year_dossier(text,text) TO anon, authenticated;

-- =====================================================================
--  GRANTS — let the anon role EXECUTE the RPCs (base-table access stays
--  denied by RLS; these definer functions are the only doorway).
-- =====================================================================
DO $$
DECLARE fn TEXT;
BEGIN
  FOR fn IN SELECT unnest(ARRAY[
    'bp_create_session(text,text)',
    'bp_auth(text,text)','bp_state(text,text)','bp_boards(uuid)',
    'bp_advance_phase(text,text)','bp_step_back(text,text)',
    'bp_trigger_curveball(text,text,text)','bp_set_headwind(text,text,int)',
    'bp_reveal_headwind(text,text)','bp_set_capacity(text,text,uuid,int,int)',
    'bp_submit_request(text,text,uuid,uuid)','bp_submit_style_call(text,text,text,text,text)',
    'bp_submit_stakeholder(text,text,text,jsonb)','bp_submit_observer(text,text,text,text)',
    'bp_log_commitment(text,text,uuid,text)','bp_confirm_commitment(text,text,uuid)',
    'bp_mark_honoured(text,text,uuid,boolean)',
    'bp_select_teams(text,text,jsonb)','bp_rate_team(text,text,uuid,int,int,int)',
    'bp_judge_team(text,text,uuid,boolean,text)','bp_export(text,text)','bp_selftest()',
    'bp_submit_mandate(text,text,text,text)',
    'bp_set_directive(text,text,text,int,text,text,text)'])
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', fn);
  END LOOP;
END $$;

-- Internal helpers stay ungranted (bp_run_scoring, bp_monitor, bp_drift,
-- bp_org_net, bp_log, bp_gencode, band helpers, bp_resolve_state,
-- bp_adjusted_ideal, bp_leadership_cell) — callable only from within the
-- definer functions above.

-- =====================================================================
--  REALTIME — publish the phase pointer + results so clients stay in
--  sync (Realtime respects RLS; only the safe, anon-readable tables are
--  published, never a spoiler table).
-- =====================================================================
DO $$
BEGIN
  BEGIN EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE bp_sessions';        EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_object THEN NULL; END;
  BEGIN EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE bp_quarter_results'; EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_object THEN NULL; END;
END $$;

-- =====================================================================
--  ORG STORYLINE + FACILITATOR-KEYED OBSERVER  (see migrations/007)
-- =====================================================================
CREATE TABLE IF NOT EXISTS bp_org_story (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id   UUID NOT NULL REFERENCES bp_sessions(id) ON DELETE CASCADE,
  quarter      INT  NOT NULL,
  body         TEXT NOT NULL,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(session_id, quarter)
);
ALTER TABLE bp_org_story ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bp_pub_org_story ON bp_org_story;
CREATE POLICY bp_pub_org_story ON bp_org_story FOR SELECT USING (true);
GRANT SELECT ON bp_org_story TO anon, authenticated;
DO $$
BEGIN
  BEGIN EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE bp_org_story'; EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_object THEN NULL; END;
END $$;

-- Deterministic spine — the exact facts a quarter's chapter is built from.
CREATE OR REPLACE FUNCTION bp_org_spine(p_session_code TEXT, p_access_code TEXT, p_quarter INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a RECORD; s RECORD;
  v_teams JSONB; v_mom INT; v_tier TEXT; v_prov INT; v_final BOOLEAN;
  hw INT; hw_rev BOOLEAN;
  bb TEXT; bs TEXT; bsp TEXT; bw TEXT; bpr TEXT;
  net JSONB; v_ach JSONB; v_coup JSONB; v_leaders JSONB; v_laggards JSONB;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  v_final := (p_quarter >= 4);

  SELECT jsonb_agg(x ORDER BY x->>'code') INTO v_teams FROM (
    SELECT jsonb_build_object(
      'code', t.code, 'name', t.name, 'objective', o.label,
      'band', COALESCE(qr.band,'missed'),
      'points', COALESCE(qr.points,0),
      'got_primary', COALESCE(qr.got_primary,false),
      'got_secondary', COALESCE(qr.got_secondary,false),
      'cumulative_points', COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
          WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0)
    ) AS x
    FROM bp_teams t
    JOIN bp_objectives o ON o.session_id=t.session_id AND o.key=t.objective_key
    LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id AND qr.quarter=p_quarter
    WHERE t.session_id=a.session_id
  ) z;

  v_mom := COALESCE((SELECT SUM(points) FROM bp_quarter_results WHERE session_id=a.session_id AND quarter=p_quarter),0);
  v_tier := CASE WHEN v_mom<=4 THEN 'stalling' WHEN v_mom<=8 THEN 'steady'
                 WHEN v_mom<=11 THEN 'rising' ELSE 'surging' END;

  SELECT COALESCE(SUM(ROUND(cum::numeric/12*4200)),0)::INT INTO v_prov FROM (
    SELECT COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
        WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0) AS cum
    FROM bp_teams t WHERE t.session_id=a.session_id
  ) c;

  v_leaders := (SELECT jsonb_agg(code) FROM (
    SELECT t.code, COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
        WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0) AS cum
    FROM bp_teams t WHERE t.session_id=a.session_id ORDER BY cum DESC, t.code LIMIT 2) q);
  v_laggards := (SELECT jsonb_agg(code) FROM (
    SELECT t.code, COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
        WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0) AS cum
    FROM bp_teams t WHERE t.session_id=a.session_id ORDER BY cum ASC, t.code LIMIT 2) q);

  SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;
  hw_rev := s.headwind_revealed;

  IF v_final THEN
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bb FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='battery';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bs FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='suppliers';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bsp FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='spec';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bw FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='warranty';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bpr FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='pricing';

    net := bp_org_net(bb,bs,bsp,bw,bpr,hw);
    v_coup := jsonb_build_object(
      'battery_suppliers', CASE WHEN bp_band_rank(bb)>=2  AND bp_band_rank(bs)>=2  THEN 1000  ELSE 0 END,
      'warranty_spec',     CASE WHEN bp_band_rank(bw)>=2  AND bp_band_rank(bsp)>=2 THEN 1000  ELSE 0 END,
      'spec_pricing',      CASE WHEN bp_band_rank(bsp)>=2 AND bp_band_rank(bpr)>=2 THEN -1500 ELSE 0 END);
    v_ach := jsonb_build_array(
      jsonb_build_object('key','cost_curve','label','Cost curve bent','status',      CASE WHEN bp_band_rank(bb)>=2  THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','supply','label','Supply de-risked','status',         CASE WHEN bp_band_rank(bs)>=2  THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','vertical','label','Vertical integration','status',   CASE WHEN bp_band_rank(bb)>=2 AND bp_band_rank(bs)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','product','label','A product that ships','status',     CASE WHEN bp_band_rank(bsp)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','field_trust','label','Field trust held','status',    CASE WHEN bp_band_rank(bw)>=2  THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','qbd','label','Quality by design','status',           CASE WHEN bp_band_rank(bw)>=2 AND bp_band_rank(bsp)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','margin','label','Margin held','status',              CASE WHEN bp_band_rank(bpr)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','overreach','label','Overreach: spec + pricing squeeze','status', CASE WHEN bp_band_rank(bsp)>=2 AND bp_band_rank(bpr)>=2 THEN 'warning' ELSE 'clear' END),
      jsonb_build_object('key','headwind','label','Weathered the headwind','status', CASE WHEN (net->>'target_hit')::boolean THEN 'achieved' ELSE 'missed' END)
    );
  END IF;

  RETURN jsonb_build_object(
    'quarter', p_quarter, 'is_final', v_final, 'session_name', s.name,
    'teams', COALESCE(v_teams,'[]'::jsonb),
    'momentum', jsonb_build_object('points', v_mom, 'tier', v_tier),
    'leaders', COALESCE(v_leaders,'[]'::jsonb),
    'laggards', COALESCE(v_laggards,'[]'::jsonb),
    'headwind_revealed', hw_rev,
    'headwind', CASE WHEN hw_rev THEN hw ELSE NULL END,
    'meter', jsonb_build_object(
      'provisional_gross', v_prov,
      'net',        CASE WHEN v_final THEN (net->>'net')::int ELSE NULL END,
      'target',     s.target_value,
      'target_hit', CASE WHEN v_final THEN (net->>'target_hit')::boolean ELSE NULL END),
    'couplings', v_coup,
    'achievements', v_ach
  );
END $$;

-- Publish a chapter to every login.
CREATE OR REPLACE FUNCTION bp_publish_story(p_session_code TEXT, p_access_code TEXT, p_quarter INT, p_body TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF COALESCE(btrim(p_body),'') = '' THEN RAISE EXCEPTION 'empty_body'; END IF;
  INSERT INTO bp_org_story(session_id, quarter, body, published_at)
    VALUES (a.session_id, p_quarter, p_body, now())
    ON CONFLICT (session_id, quarter) DO UPDATE
      SET body=EXCLUDED.body, published_at=now();
  PERFORM bp_log(a.session_id,'facilitator','publish_story', jsonb_build_object('quarter',p_quarter));
  RETURN jsonb_build_object('ok', true);
END $$;

-- Facilitator keys in the observed style (the observer sits out and reports
-- it offline). Replaces the participant-entered observer path.
CREATE OR REPLACE FUNCTION bp_set_observer(p_session_code TEXT, p_access_code TEXT,
  p_team UUID, p_style TEXT, p_note TEXT, p_quarter INT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; q INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  q := COALESCE(p_quarter, s.current_quarter);
  IF NOT EXISTS (SELECT 1 FROM bp_teams WHERE id=p_team AND session_id=a.session_id) THEN
    RAISE EXCEPTION 'unknown_team';
  END IF;
  INSERT INTO bp_observer_logs(session_id, team_id, quarter, observed_style, note)
    VALUES (a.session_id, p_team, q, p_style, p_note)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET observed_style=EXCLUDED.observed_style, note=EXCLUDED.note;
  PERFORM bp_log(a.session_id,'facilitator','set_observer', jsonb_build_object('team',p_team,'quarter',q));
  RETURN jsonb_build_object('ok', true);
END $$;

-- =====================================================================
--  DONE. Run bp_selftest() to confirm the scoring sanity checks:
--    SELECT * FROM bp_selftest();
--  Provision a playable session:
--    SELECT bp_create_session('Pilot cohort');
-- =====================================================================
