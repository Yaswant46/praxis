-- =============================================================
--  PRAXIS — SUPABASE SCHEMA  (v2 — Cohort Wizard)
--  Run in: Supabase Dashboard → SQL Editor → New Query
--  Idempotent: safe to re-run on an existing project.
--
--  Migrating from v1 (the old schema.sql with slot+access_code login)?
--  This script ALTERs existing tables in place and backfills new
--  columns. No data is dropped. New constraints are only added once
--  data is consistent.
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- =============================================================
--  TABLE: cases
-- =============================================================
CREATE TABLE IF NOT EXISTS cases (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  slug        TEXT UNIQUE NOT NULL,
  name        TEXT NOT NULL,
  subtitle    TEXT,
  difficulty  TEXT DEFAULT 'intermediate'
);

INSERT INTO cases (slug, name, subtitle, difficulty)
VALUES
  ('volta', 'VOLTA Motors', 'Navigating the Inflection: Scale, Survival, and Unit Economics', 'complex'),
  ('arc',   'ARC Motors',   'The Velocity Trap: Product Development Under Market Shift',       'intermediate'),
  ('demo',  'ShopPulse',    'The Last Mile Problem: Growth vs. Margin in Quick Commerce',      'introductory')
ON CONFLICT (slug) DO NOTHING;


-- =============================================================
--  TABLE: sessions
-- =============================================================
CREATE TABLE IF NOT EXISTS sessions (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code           TEXT UNIQUE NOT NULL,
  case_id        UUID REFERENCES cases(id),
  cohort_name    TEXT,
  admin_email    TEXT NOT NULL,
  total_rounds   INTEGER NOT NULL DEFAULT 5,
  current_round  INTEGER DEFAULT 1,
  round_open     BOOLEAN DEFAULT TRUE,
  status         TEXT DEFAULT 'active',
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE sessions ADD COLUMN IF NOT EXISTS total_rounds INTEGER NOT NULL DEFAULT 5;


-- =============================================================
--  TABLE: teams
-- =============================================================
CREATE TABLE IF NOT EXISTS teams (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id            UUID REFERENCES sessions(id) ON DELETE CASCADE,
  team_number           INTEGER,
  slot                  TEXT NOT NULL,
  display_name          TEXT NOT NULL,
  username              TEXT,
  password              TEXT,
  representative_email  TEXT,
  participant_email     TEXT,
  credentials_sent_at   TIMESTAMPTZ,
  activated_at          TIMESTAMPTZ,
  access_code           TEXT,
  UNIQUE(session_id, slot)
);

ALTER TABLE teams ADD COLUMN IF NOT EXISTS team_number          INTEGER;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS username             TEXT;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS password             TEXT;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS representative_email TEXT;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS credentials_sent_at  TIMESTAMPTZ;
ALTER TABLE teams ALTER COLUMN access_code DROP NOT NULL;

-- Backfill team_number from slot (alpha=1..zeta=6) for old rows.
UPDATE teams SET team_number = CASE slot
  WHEN 'alpha'   THEN 1
  WHEN 'beta'    THEN 2
  WHEN 'gamma'   THEN 3
  WHEN 'delta'   THEN 4
  WHEN 'epsilon' THEN 5
  WHEN 'zeta'    THEN 6
END
WHERE team_number IS NULL;

-- For old rows that pre-date the wizard, re-use access_code as the password
-- and the display_name as the username so legacy logins keep working.
UPDATE teams SET username = lower(regexp_replace(display_name, '\s+', '-', 'g'))
WHERE username IS NULL AND display_name IS NOT NULL;
UPDATE teams SET password = access_code
WHERE password IS NULL AND access_code IS NOT NULL;

DO $mig$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND indexname='teams_session_id_username_uniq'
  ) THEN
    -- already created; skip
    NULL;
  ELSE
    CREATE UNIQUE INDEX teams_session_id_username_uniq
      ON teams(session_id, lower(username))
      WHERE username IS NOT NULL;
  END IF;
END $mig$;


-- =============================================================
--  TABLE: decisions
-- =============================================================
CREATE TABLE IF NOT EXISTS decisions (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES sessions(id) ON DELETE CASCADE,
  team_id      UUID REFERENCES teams(id) ON DELETE CASCADE,
  round        INTEGER NOT NULL,
  domain_id    TEXT NOT NULL,
  field_id     TEXT NOT NULL,
  value        TEXT,
  submitted_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(session_id, team_id, round, field_id)
);


-- =============================================================
--  TABLE: outcomes
-- =============================================================
CREATE TABLE IF NOT EXISTS outcomes (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id      UUID REFERENCES sessions(id) ON DELETE CASCADE,
  team_id         UUID REFERENCES teams(id) ON DELETE CASCADE,
  round           INTEGER NOT NULL,
  revenue         NUMERIC(10,2),
  gross_margin    NUMERIC(6,2),
  cash_runway     NUMERIC(6,1),
  market_share    NUMERIC(6,1),
  product_health  NUMERIC(6,1),
  team_capability NUMERIC(6,1),
  score           INTEGER,
  published_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(session_id, team_id, round)
);


-- =============================================================
--  TABLE: curveballs
-- =============================================================
CREATE TABLE IF NOT EXISTS curveballs (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES sessions(id) ON DELETE CASCADE,
  round        INTEGER NOT NULL,
  title        TEXT NOT NULL,
  body         TEXT NOT NULL,
  injected_by  TEXT,
  injected_at  TIMESTAMPTZ DEFAULT NOW()
);


-- =============================================================
--  ROW LEVEL SECURITY
--  - anon can read sessions (login lookup), curveballs (broadcast),
--    cases (catalog), and only PUBLISHED outcomes.
--  - anon cannot read teams (would leak username/password) and cannot
--    insert/update sessions, teams, outcomes, or curveballs.
--  - All writes from a Game Master require an authenticated session
--    (Supabase OTP login) where auth.email() matches admin_email,
--    OR the caller is the master admin (ross.harvey92@gmail.com).
--  - Decisions stay open to anon for v2; gating decisions by team
--    identity requires a per-team JWT (planned for a follow-up).
-- =============================================================

ALTER TABLE cases       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE teams       ENABLE ROW LEVEL SECURITY;
ALTER TABLE decisions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE outcomes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE curveballs  ENABLE ROW LEVEL SECURITY;

-- Drop legacy wide-open policies if present.
DROP POLICY IF EXISTS "anon_select_cases"      ON cases;
DROP POLICY IF EXISTS "anon_select_sessions"   ON sessions;
DROP POLICY IF EXISTS "anon_insert_sessions"   ON sessions;
DROP POLICY IF EXISTS "anon_update_sessions"   ON sessions;
DROP POLICY IF EXISTS "anon_select_teams"      ON teams;
DROP POLICY IF EXISTS "anon_insert_teams"      ON teams;
DROP POLICY IF EXISTS "anon_update_teams"      ON teams;
DROP POLICY IF EXISTS "anon_select_decisions"  ON decisions;
DROP POLICY IF EXISTS "anon_insert_decisions"  ON decisions;
DROP POLICY IF EXISTS "anon_upsert_decisions"  ON decisions;
DROP POLICY IF EXISTS "anon_select_outcomes"   ON outcomes;
DROP POLICY IF EXISTS "anon_insert_outcomes"   ON outcomes;
DROP POLICY IF EXISTS "anon_upsert_outcomes"   ON outcomes;
DROP POLICY IF EXISTS "anon_select_curveballs" ON curveballs;
DROP POLICY IF EXISTS "anon_insert_curveballs" ON curveballs;

DROP POLICY IF EXISTS cases_select              ON cases;
DROP POLICY IF EXISTS sessions_select           ON sessions;
DROP POLICY IF EXISTS sessions_insert_owner     ON sessions;
DROP POLICY IF EXISTS sessions_update_owner     ON sessions;
DROP POLICY IF EXISTS teams_select_owner        ON teams;
DROP POLICY IF EXISTS teams_insert_owner        ON teams;
DROP POLICY IF EXISTS teams_update_owner        ON teams;
DROP POLICY IF EXISTS decisions_select          ON decisions;
DROP POLICY IF EXISTS decisions_insert          ON decisions;
DROP POLICY IF EXISTS decisions_update          ON decisions;
DROP POLICY IF EXISTS outcomes_select_published ON outcomes;
DROP POLICY IF EXISTS outcomes_select_owner     ON outcomes;
DROP POLICY IF EXISTS outcomes_insert_owner     ON outcomes;
DROP POLICY IF EXISTS outcomes_update_owner     ON outcomes;
DROP POLICY IF EXISTS curveballs_select         ON curveballs;
DROP POLICY IF EXISTS curveballs_insert_owner   ON curveballs;


-- Helpers for ownership checks. SECURITY DEFINER so they can read
-- sessions even when a row-level policy on the calling query path
-- might otherwise prevent the lookup.
CREATE OR REPLACE FUNCTION praxis_caller_email() RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT lower(NULLIF(auth.jwt() ->> 'email', ''));
$$;

CREATE OR REPLACE FUNCTION praxis_is_master_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT praxis_caller_email() = 'ross.harvey92@gmail.com';
$$;

CREATE OR REPLACE FUNCTION praxis_is_session_gm(p_session_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM sessions
    WHERE id = p_session_id
      AND lower(admin_email) = praxis_caller_email()
  );
$$;


-- cases: public read.
CREATE POLICY cases_select ON cases FOR SELECT USING (true);

-- sessions: public read (login needs to look up by code); only owner
-- or master admin can write.
CREATE POLICY sessions_select       ON sessions FOR SELECT USING (true);
CREATE POLICY sessions_insert_owner ON sessions FOR INSERT TO authenticated
  WITH CHECK (
    praxis_is_master_admin()
    OR lower(admin_email) = praxis_caller_email()
  );
CREATE POLICY sessions_update_owner ON sessions FOR UPDATE TO authenticated
  USING (praxis_is_master_admin() OR lower(admin_email) = praxis_caller_email())
  WITH CHECK (praxis_is_master_admin() OR lower(admin_email) = praxis_caller_email());

-- teams: never readable by anon (would leak password); only the GM
-- owner (or master admin) can read/write directly. Anon flows go
-- through the verify_team_login / get_session_team_directory RPCs.
CREATE POLICY teams_select_owner ON teams FOR SELECT TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id));
CREATE POLICY teams_insert_owner ON teams FOR INSERT TO authenticated
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));
CREATE POLICY teams_update_owner ON teams FOR UPDATE TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id))
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));

-- decisions: open to anon for v2. A future change will gate SELECT by
-- the participant's team-issued JWT so teams can't read each other's
-- in-flight decisions.
CREATE POLICY decisions_select ON decisions FOR SELECT USING (true);
CREATE POLICY decisions_insert ON decisions FOR INSERT WITH CHECK (true);
CREATE POLICY decisions_update ON decisions FOR UPDATE USING (true);

-- outcomes: anon can read only published rows (published_at NOT NULL);
-- the GM owner (or master admin) can read everything they manage; only
-- they can write.
CREATE POLICY outcomes_select_published ON outcomes FOR SELECT
  USING (published_at IS NOT NULL);
CREATE POLICY outcomes_select_owner ON outcomes FOR SELECT TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id));
CREATE POLICY outcomes_insert_owner ON outcomes FOR INSERT TO authenticated
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));
CREATE POLICY outcomes_update_owner ON outcomes FOR UPDATE TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id))
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));

-- curveballs: anon can read (broadcast); only owner can inject.
CREATE POLICY curveballs_select       ON curveballs FOR SELECT USING (true);
CREATE POLICY curveballs_insert_owner ON curveballs FOR INSERT TO authenticated
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));


-- =============================================================
--  RPC: verify_team_login(session_code, username, password)
--  Anon-callable, SECURITY DEFINER. Returns the team + session if
--  the credentials match. Stamps activated_at on first success.
-- =============================================================
CREATE OR REPLACE FUNCTION verify_team_login(
  p_session_code TEXT,
  p_username     TEXT,
  p_password     TEXT
)
RETURNS TABLE (
  team_id        UUID,
  session_id     UUID,
  session_code   TEXT,
  cohort_name    TEXT,
  case_slug      TEXT,
  case_name      TEXT,
  total_rounds   INTEGER,
  current_round  INTEGER,
  round_open     BOOLEAN,
  status         TEXT,
  team_number    INTEGER,
  slot           TEXT,
  display_name   TEXT,
  username       TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_team_id UUID;
BEGIN
  SELECT t.id INTO v_team_id
  FROM teams t
  JOIN sessions s ON s.id = t.session_id
  WHERE upper(s.code) = upper(p_session_code)
    AND lower(t.username) = lower(p_username)
    AND t.password = p_password
  LIMIT 1;

  IF v_team_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE teams
  SET activated_at = COALESCE(activated_at, NOW())
  WHERE id = v_team_id;

  RETURN QUERY
  SELECT
    t.id, s.id, s.code, s.cohort_name,
    c.slug, c.name,
    s.total_rounds, s.current_round, s.round_open, s.status,
    t.team_number, t.slot, t.display_name, t.username
  FROM teams t
  JOIN sessions s ON s.id = t.session_id
  LEFT JOIN cases c ON c.id = s.case_id
  WHERE t.id = v_team_id;
END;
$$;

REVOKE ALL ON FUNCTION verify_team_login(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION verify_team_login(TEXT, TEXT, TEXT) TO anon, authenticated;


-- =============================================================
--  RPC: get_session_team_directory(session_code)
--  Anon-callable. Returns just team_number + slot + display_name
--  (no username / no password) so the login URL can show the cohort
--  team list without leaking credentials.
-- =============================================================
CREATE OR REPLACE FUNCTION get_session_team_directory(p_session_code TEXT)
RETURNS TABLE (
  team_number  INTEGER,
  slot         TEXT,
  display_name TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT t.team_number, t.slot, t.display_name
  FROM teams t
  JOIN sessions s ON s.id = t.session_id
  WHERE upper(s.code) = upper(p_session_code)
  ORDER BY t.team_number NULLS LAST, t.slot;
$$;

REVOKE ALL ON FUNCTION get_session_team_directory(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_session_team_directory(TEXT) TO anon, authenticated;


-- =============================================================
--  RPC: create_cohort(...)
--  Authenticated-only, SECURITY DEFINER. Creates a session + all
--  teams atomically. Only the GM owner of admin_email (or master
--  admin) can call. p_teams is a JSONB array:
--    [{ team_number, slot, display_name, username, password,
--       representative_email }, ...]
-- =============================================================
CREATE OR REPLACE FUNCTION create_cohort(
  p_cohort_name  TEXT,
  p_case_slug    TEXT,
  p_admin_email  TEXT,
  p_total_rounds INTEGER,
  p_teams        JSONB
)
RETURNS TABLE (session_id UUID, session_code TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller   TEXT := praxis_caller_email();
  v_case_id  UUID;
  v_session  sessions%ROWTYPE;
  v_code     TEXT;
  v_team     JSONB;
  v_attempts INTEGER := 0;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF lower(p_admin_email) <> v_caller AND NOT praxis_is_master_admin() THEN
    RAISE EXCEPTION 'Caller % cannot create a session for %', v_caller, p_admin_email;
  END IF;
  IF p_total_rounds IS NULL OR p_total_rounds < 1 OR p_total_rounds > 6 THEN
    RAISE EXCEPTION 'total_rounds must be between 1 and 6';
  END IF;

  SELECT id INTO v_case_id FROM cases WHERE slug = p_case_slug;
  IF v_case_id IS NULL THEN
    RAISE EXCEPTION 'Unknown case: %', p_case_slug;
  END IF;

  LOOP
    v_attempts := v_attempts + 1;
    v_code := upper(substring(
      regexp_replace(md5(random()::text || clock_timestamp()::text), '[^A-Z0-9]', '', 'gi')
      FROM 1 FOR 6
    ));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM sessions WHERE code = v_code);
    IF v_attempts > 30 THEN
      RAISE EXCEPTION 'Failed to allocate a unique session code';
    END IF;
  END LOOP;

  INSERT INTO sessions (code, case_id, cohort_name, admin_email,
                        total_rounds, current_round, round_open, status)
  VALUES (v_code, v_case_id, p_cohort_name, lower(p_admin_email),
          p_total_rounds, 1, true, 'active')
  RETURNING * INTO v_session;

  FOR v_team IN SELECT * FROM jsonb_array_elements(p_teams) LOOP
    INSERT INTO teams (
      session_id, team_number, slot, display_name, username, password,
      representative_email, access_code
    ) VALUES (
      v_session.id,
      (v_team ->> 'team_number')::INTEGER,
      v_team ->> 'slot',
      v_team ->> 'display_name',
      v_team ->> 'username',
      v_team ->> 'password',
      v_team ->> 'representative_email',
      v_team ->> 'password'  -- mirror into legacy access_code so old code paths still work
    );
  END LOOP;

  RETURN QUERY SELECT v_session.id, v_session.code;
END;
$$;

REVOKE ALL ON FUNCTION create_cohort(TEXT, TEXT, TEXT, INTEGER, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_cohort(TEXT, TEXT, TEXT, INTEGER, JSONB) TO authenticated;


-- =============================================================
--  RPC: rotate_team_password(team_id, new_password)
--  GM-callable, lets the GM regenerate a team's password before
--  resending credentials.
-- =============================================================
CREATE OR REPLACE FUNCTION rotate_team_password(p_team_id UUID, p_new_password TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session_id UUID;
BEGIN
  SELECT session_id INTO v_session_id FROM teams WHERE id = p_team_id;
  IF v_session_id IS NULL THEN
    RETURN false;
  END IF;
  IF NOT (praxis_is_master_admin() OR praxis_is_session_gm(v_session_id)) THEN
    RAISE EXCEPTION 'Not authorised to rotate this team password';
  END IF;
  UPDATE teams
  SET password = p_new_password,
      access_code = p_new_password,
      credentials_sent_at = NULL
  WHERE id = p_team_id;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION rotate_team_password(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rotate_team_password(UUID, TEXT) TO authenticated;


-- =============================================================
--  REALTIME
-- =============================================================
DO $rt$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE sessions;
EXCEPTION WHEN duplicate_object THEN NULL; END $rt$;
DO $rt$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE curveballs;
EXCEPTION WHEN duplicate_object THEN NULL; END $rt$;
DO $rt$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE outcomes;
EXCEPTION WHEN duplicate_object THEN NULL; END $rt$;
DO $rt$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE teams;
EXCEPTION WHEN duplicate_object THEN NULL; END $rt$;


-- =============================================================
--  INDEXES
-- =============================================================
CREATE INDEX IF NOT EXISTS idx_sessions_code           ON sessions(code);
CREATE INDEX IF NOT EXISTS idx_sessions_admin_email    ON sessions(lower(admin_email));
CREATE INDEX IF NOT EXISTS idx_teams_session_id        ON teams(session_id);
CREATE INDEX IF NOT EXISTS idx_teams_session_slot      ON teams(session_id, slot);
CREATE INDEX IF NOT EXISTS idx_decisions_session_team  ON decisions(session_id, team_id, round);
CREATE INDEX IF NOT EXISTS idx_outcomes_session_team   ON outcomes(session_id, team_id, round);
CREATE INDEX IF NOT EXISTS idx_curveballs_session      ON curveballs(session_id);


-- =============================================================
--  VERIFY
-- =============================================================
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' ORDER BY table_name;
