-- =============================================================
--  PRAXIS — SUPABASE SCHEMA
--  Run this in: Supabase Dashboard → SQL Editor → New Query
--  Run once on a fresh project. Safe to re-run (uses IF NOT EXISTS).
-- =============================================================


-- =============================================================
--  EXTENSION
-- =============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- =============================================================
--  TABLE: cases
--  Pre-seeded simulation cases (VOLTA, ARC, ShopPulse)
-- =============================================================
CREATE TABLE IF NOT EXISTS cases (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  slug        TEXT UNIQUE NOT NULL,       -- 'volta' | 'arc' | 'demo'
  name        TEXT NOT NULL,              -- 'VOLTA Motors'
  subtitle    TEXT,                       -- 'Navigating the Inflection...'
  difficulty  TEXT DEFAULT 'intermediate' -- 'complex' | 'intermediate' | 'introductory'
);

-- Seed built-in cases (insert only if not present)
INSERT INTO cases (slug, name, subtitle, difficulty)
VALUES
  ('volta', 'VOLTA Motors',  'Navigating the Inflection: Scale, Survival, and Unit Economics', 'complex'),
  ('arc',   'ARC Motors',    'The Velocity Trap: Product Development Under Market Shift',       'intermediate'),
  ('demo',  'ShopPulse',     'The Last Mile Problem: Growth vs. Margin in Quick Commerce',       'introductory')
ON CONFLICT (slug) DO NOTHING;


-- =============================================================
--  TABLE: sessions
--  One row per simulation run (one cohort, one case)
-- =============================================================
CREATE TABLE IF NOT EXISTS sessions (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code           TEXT UNIQUE NOT NULL,          -- 6-char uppercase join code e.g. 'XK9F2A'
  case_id        UUID REFERENCES cases(id),
  cohort_name    TEXT,                          -- 'Catalyst Batch 4'
  admin_email    TEXT NOT NULL,                 -- Game Master email (used for OTP login)
  current_round  INTEGER DEFAULT 1,             -- 1..5
  round_open     BOOLEAN DEFAULT TRUE,          -- true = teams can submit decisions
  status         TEXT DEFAULT 'active',         -- 'active' | 'ended'
  created_at     TIMESTAMPTZ DEFAULT NOW()
);


-- =============================================================
--  TABLE: teams
--  Up to 6 teams per session
-- =============================================================
CREATE TABLE IF NOT EXISTS teams (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id        UUID REFERENCES sessions(id) ON DELETE CASCADE,
  slot              TEXT NOT NULL,              -- 'alpha' | 'beta' | 'gamma' | 'delta' | 'epsilon' | 'zeta'
  display_name      TEXT NOT NULL,              -- 'Alpha', 'Beta', etc. (editable by master admin)
  access_code       TEXT NOT NULL,              -- team login code e.g. 'alpha01'
  participant_email TEXT,                       -- locked on first login (email validation fix)
  activated_at      TIMESTAMPTZ,                -- when first team member logged in
  UNIQUE(session_id, slot)
);


-- =============================================================
--  TABLE: decisions
--  One row per field per team per round
--  (upsert on session_id + team_id + round + field_id)
-- =============================================================
CREATE TABLE IF NOT EXISTS decisions (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES sessions(id) ON DELETE CASCADE,
  team_id      UUID REFERENCES teams(id) ON DELETE CASCADE,
  round        INTEGER NOT NULL,                -- 1..5
  domain_id    TEXT NOT NULL,                   -- 'engineering' | 'manufacturing' | etc.
  field_id     TEXT NOT NULL,                   -- e.g. 'eng_priority'
  value        TEXT,                            -- the selected option or text
  submitted_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(session_id, team_id, round, field_id)
);


-- =============================================================
--  TABLE: outcomes
--  GM-entered results per team per round (published post-debrief)
-- =============================================================
CREATE TABLE IF NOT EXISTS outcomes (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id      UUID REFERENCES sessions(id) ON DELETE CASCADE,
  team_id         UUID REFERENCES teams(id) ON DELETE CASCADE,
  round           INTEGER NOT NULL,
  revenue         NUMERIC(10,2),                -- ₹ Cr, e.g. 16.8
  gross_margin    NUMERIC(6,2),                 -- %, e.g. -5.8
  cash_runway     NUMERIC(6,1),                 -- months, e.g. 22.0
  market_share    NUMERIC(6,1),                 -- index 0-100
  product_health  NUMERIC(6,1),                 -- index 0-100
  team_capability NUMERIC(6,1),                 -- index 0-100
  score           INTEGER,                      -- GM-assigned score /100
  published_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(session_id, team_id, round)
);


-- =============================================================
--  TABLE: curveballs
--  Game Master-injected scenario events, broadcast to all teams
-- =============================================================
CREATE TABLE IF NOT EXISTS curveballs (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id   UUID REFERENCES sessions(id) ON DELETE CASCADE,
  round        INTEGER NOT NULL,
  title        TEXT NOT NULL,
  body         TEXT NOT NULL,
  injected_by  TEXT,                            -- GM email
  injected_at  TIMESTAMPTZ DEFAULT NOW()
);


-- =============================================================
--  ROW LEVEL SECURITY (RLS)
--  All tables use anon key (public access is controlled by
--  application logic, not Postgres policies).
--  Enable RLS but allow all for anon role so the app works
--  without a Supabase auth session for participants.
-- =============================================================

ALTER TABLE cases       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE teams       ENABLE ROW LEVEL SECURITY;
ALTER TABLE decisions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE outcomes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE curveballs  ENABLE ROW LEVEL SECURITY;

-- Allow anon (the app's public key) to read/write everything.
-- Access control is handled in application logic (access codes, email lock, OTP).

CREATE POLICY "anon_select_cases"       ON cases       FOR SELECT TO anon USING (true);
CREATE POLICY "anon_select_sessions"    ON sessions    FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_sessions"    ON sessions    FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_sessions"    ON sessions    FOR UPDATE TO anon USING (true);

CREATE POLICY "anon_select_teams"       ON teams       FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_teams"       ON teams       FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_update_teams"       ON teams       FOR UPDATE TO anon USING (true);

CREATE POLICY "anon_select_decisions"   ON decisions   FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_decisions"   ON decisions   FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_upsert_decisions"   ON decisions   FOR UPDATE TO anon USING (true);

CREATE POLICY "anon_select_outcomes"    ON outcomes    FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_outcomes"    ON outcomes    FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_upsert_outcomes"    ON outcomes    FOR UPDATE TO anon USING (true);

CREATE POLICY "anon_select_curveballs"  ON curveballs  FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_curveballs"  ON curveballs  FOR INSERT TO anon WITH CHECK (true);


-- =============================================================
--  REALTIME
--  Enable Supabase Realtime on the tables that need live push.
--  Required for: curveball broadcast, session state sync.
-- =============================================================

-- Add tables to the realtime publication
-- (run each line separately if you get a "already member" error)
ALTER PUBLICATION supabase_realtime ADD TABLE sessions;
ALTER PUBLICATION supabase_realtime ADD TABLE curveballs;
ALTER PUBLICATION supabase_realtime ADD TABLE outcomes;
ALTER PUBLICATION supabase_realtime ADD TABLE teams;


-- =============================================================
--  INDEXES
--  Speed up the most common query patterns in the app.
-- =============================================================
CREATE INDEX IF NOT EXISTS idx_sessions_code          ON sessions(code);
CREATE INDEX IF NOT EXISTS idx_sessions_admin_email   ON sessions(admin_email);
CREATE INDEX IF NOT EXISTS idx_teams_session_id       ON teams(session_id);
CREATE INDEX IF NOT EXISTS idx_teams_session_slot     ON teams(session_id, slot);
CREATE INDEX IF NOT EXISTS idx_decisions_session_team ON decisions(session_id, team_id, round);
CREATE INDEX IF NOT EXISTS idx_outcomes_session_team  ON outcomes(session_id, team_id, round);
CREATE INDEX IF NOT EXISTS idx_curveballs_session     ON curveballs(session_id);


-- =============================================================
--  VERIFY
--  Run this SELECT at the end to confirm all tables exist.
-- =============================================================
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
ORDER  BY table_name;
