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
--  → RUNNER_WINDOW → OPEN_NEGOTIATION → SELECTION → RESULTS → DEBRIEF

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
                         'RUNNER_WINDOW','OPEN_NEGOTIATION','SELECTION','RESULTS','DEBRIEF')),
  headwind_revealed BOOLEAN NOT NULL DEFAULT FALSE,
  target_value      INT NOT NULL DEFAULT 14200,
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
    'bp_curveballs','bp_escalation_cards','bp_events'])
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

-- bp_sessions carries no secret (headwind is elsewhere) — needed for
-- the Realtime phase pointer.
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
    'bp_stakeholder_maps','bp_escalation_cards','bp_events'])
  LOOP
    EXECUTE format('REVOKE ALL ON %I FROM anon, authenticated', t);
  END LOOP;
END $$;

-- Safe tables: explicit SELECT for the API roles (subject to the
-- permissive policies above).
GRANT SELECT ON bp_sessions, bp_objectives, bp_teams, bp_quarter_results, bp_commitments
  TO anon, authenticated;

-- NOTE: bp_teams.access_code is a column on a publicly-readable table.
-- Anon can therefore read team codes. That is acceptable for a live
-- in-room game (codes are handed out anyway) and the console spoiler
-- surfaces (demand_map, selections, requests, style_calls, characters,
-- ratings, headwind) are all on deny-all tables. If you want to hide
-- team codes too, drop the column from this policy via a view. Every
-- other sensitive table has NO anon policy → deny-all.

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
    'RUNNER_WINDOW','OPEN_NEGOTIATION','SELECTION','RESULTS','DEBRIEF'], p);
$$;

CREATE OR REPLACE FUNCTION bp_phase_at(i INT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT (ARRAY[
    'BRIEF','TEAM_DISCUSSION','REQUESTS_OPEN','REQUESTS_LOCKED',
    'RUNNER_WINDOW','OPEN_NEGOTIATION','SELECTION','RESULTS','DEBRIEF'])[i];
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

-- =====================================================================
--  SESSION PROVISIONING  (seeds a full playable case, §11)
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_create_session(p_name TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sid UUID;
  v_fac TEXT;
  r RECORD;
  v_team_codes JSONB := '{}'::jsonb;
  v_char_codes JSONB := '{}'::jsonb;
  -- objective → team code, name
  objs TEXT[][] := ARRAY[
    ARRAY['battery','A','Battery','Cell cost, energy density, and thermal safety.'],
    ARRAY['suppliers','B','Suppliers','Second-source the critical bill of materials.'],
    ARRAY['spec','C','Spec','Lock the product specification without gold-plating.'],
    ARRAY['warranty','D','Warranty','Contain field-failure exposure and warranty reserve.'],
    ARRAY['pricing','E','Pricing','Hold margin against a price-led market.']];
  chars TEXT[][] := ARRAY[
    ARRAY['arjun','Arjun','Design lead'],
    ARRAY['neha','Neha','Supply chain — 14 months in'],
    ARRAY['raghav','Raghav','Manufacturing — 19 years'],
    ARRAY['farida','Farida','Quality'],
    ARRAY['devika','Devika','Regional Sales Head'],
    ARRAY['sponsor','Sponsor','COO — facilitator plays this']];
  -- demand map: objective, q1p,q1s, q2p,q2s, q3p,q3s, q4p,q4s
  dmap TEXT[][] := ARRAY[
    ARRAY['battery',  'arjun','neha',  'neha','farida', 'farida','raghav', 'arjun','neha'],
    ARRAY['suppliers','neha','raghav', 'neha','raghav', 'raghav','neha',   'sponsor','neha'],
    ARRAY['spec',     'arjun','devika','farida','devika','arjun','devika', 'sponsor','farida'],
    ARRAY['warranty', 'farida','raghav','raghav','farida','neha','raghav', 'farida','neha'],
    ARRAY['pricing',  'devika','farida','devika','arjun', 'devika','farida','sponsor','devika']];
  team_names TEXT[] := ARRAY['Ampere','Bastion','Crucible','Dynamo','Envoy'];
  i INT; q INT;
  v_char_id UUID;
BEGIN
  v_fac := bp_gencode('FAC');
  INSERT INTO bp_sessions(name, facilitator_code) VALUES (p_name, v_fac) RETURNING id INTO v_sid;
  INSERT INTO bp_headwind(session_id, value) VALUES (v_sid, 6000);

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
    -- capacity: working chars 2 slots Q1/Q2/Q4, 1 in Q3; sponsor 1 always
    FOR q IN 1..4 LOOP
      INSERT INTO bp_character_capacity(session_id, character_id, quarter, slots)
        VALUES (v_sid, v_char_id, q,
          CASE WHEN chars[i][1]='sponsor' THEN 1
               WHEN q=3 THEN 1 ELSE 2 END);
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

  PERFORM bp_log(v_sid,'facilitator','create_session', jsonb_build_object('name',p_name));

  RETURN jsonb_build_object(
    'session_id', v_sid,
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

-- Compute quarter_results for one quarter (runs on entry to RESULTS).
CREATE OR REPLACE FUNCTION bp_run_scoring(p_sid UUID, p_quarter INT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t RECORD; mapP TEXT; mapS TEXT;
  got_p BOOLEAN; got_s BOOLEAN; avg_r NUMERIC; v_band TEXT; v_points INT;
BEGIN
  FOR t IN SELECT id, objective_key FROM bp_teams WHERE session_id=p_sid LOOP
    SELECT primary_character_key, secondary_character_key INTO mapP, mapS
      FROM bp_demand_map WHERE session_id=p_sid AND objective_key=t.objective_key AND quarter=p_quarter;

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
  END LOOP;

  PERFORM bp_log(p_sid,'engine','run_scoring', jsonb_build_object('quarter',p_quarter));
END $$;

-- Self-test: the three §6 sanity checks. Returns pass/fail rows.
CREATE OR REPLACE FUNCTION bp_selftest()
RETURNS TABLE (test TEXT, expected TEXT, actual TEXT, pass BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE r JSONB;
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
                       FROM bp_characters WHERE session_id=a.session_id));

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
      'drift', bp_drift(a.session_id, s.current_quarter));
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
    'has_observer',  EXISTS(SELECT 1 FROM bp_observer_logs o WHERE o.session_id=p_sid AND o.team_id=t.id AND o.quarter=p_quarter)
  ) ORDER BY t.code)
  FROM bp_teams t WHERE t.session_id=p_sid;
$$;

-- Drift check: per character — teams selected, rating spread, compression flag.
CREATE OR REPLACE FUNCTION bp_drift(p_sid UUID, p_quarter INT)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_agg(x ORDER BY x->>'key') FROM (
    SELECT jsonb_build_object(
      'character_id', c.id, 'key', c.key, 'name', c.name,
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
  PERFORM bp_log(a.session_id,'character','select',jsonb_build_object('character',a.character_id,'n',jsonb_array_length(p_picks)));
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
  bands JSONB := '{}'::jsonb; trow RECORD; tot INT; ab TEXT;
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

  -- annual bands per objective for org couplings
  FOR trow IN SELECT id, objective_key FROM bp_teams WHERE session_id=p_session_id LOOP
    SELECT COALESCE(SUM(points),0) INTO tot FROM bp_quarter_results WHERE session_id=p_session_id AND team_id=trow.id;
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
--  GRANTS — let the anon role EXECUTE the RPCs (base-table access stays
--  denied by RLS; these definer functions are the only doorway).
-- =====================================================================
DO $$
DECLARE fn TEXT;
BEGIN
  FOR fn IN SELECT unnest(ARRAY[
    'bp_create_session(text)',
    'bp_auth(text,text)','bp_state(text,text)','bp_boards(uuid)',
    'bp_advance_phase(text,text)','bp_step_back(text,text)',
    'bp_trigger_curveball(text,text,text)','bp_set_headwind(text,text,int)',
    'bp_reveal_headwind(text,text)','bp_set_capacity(text,text,uuid,int,int)',
    'bp_submit_request(text,text,uuid,uuid)','bp_submit_style_call(text,text,text,text,text)',
    'bp_submit_stakeholder(text,text,text,jsonb)','bp_submit_observer(text,text,text,text)',
    'bp_log_commitment(text,text,uuid,text)','bp_confirm_commitment(text,text,uuid)',
    'bp_mark_honoured(text,text,uuid,boolean)',
    'bp_select_teams(text,text,jsonb)','bp_rate_team(text,text,uuid,int,int,int)',
    'bp_judge_team(text,text,uuid,boolean,text)','bp_export(text,text)','bp_selftest()'])
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', fn);
  END LOOP;
END $$;

-- Internal helpers stay ungranted (bp_run_scoring, bp_monitor, bp_drift,
-- bp_org_net, bp_log, bp_gencode, band helpers) — callable only from
-- within the definer functions above.

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
--  DONE. Run bp_selftest() to confirm the scoring sanity checks:
--    SELECT * FROM bp_selftest();
--  Provision a playable session:
--    SELECT bp_create_session('Pilot cohort');
-- =====================================================================
