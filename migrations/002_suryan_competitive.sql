-- =============================================================
--  PRAXIS — MIGRATION 002: Suryan Energy (competitive mode)
--  Additive only. Existing cases (volta/arc/demo) unaffected.
--  Applied to the live Praxis project 2026-07-13.
-- =============================================================

-- 9.1 cases: competitive mode + optional data-driven config
ALTER TABLE cases ADD COLUMN IF NOT EXISTS mode TEXT DEFAULT 'parallel'; -- 'parallel' | 'competitive'
ALTER TABLE cases ADD COLUMN IF NOT EXISTS config JSONB;

-- 9.2 teams: declared posture + live engine state
ALTER TABLE teams ADD COLUMN IF NOT EXISTS posture TEXT;                 -- command|coach|steward
ALTER TABLE teams ADD COLUMN IF NOT EXISTS posture_switched BOOLEAN DEFAULT false;
ALTER TABLE teams ADD COLUMN IF NOT EXISTS state JSONB;                  -- live team state snapshot

-- 9.4 outcomes: rich per-round engine output
ALTER TABLE outcomes ADD COLUMN IF NOT EXISTS detail JSONB;

-- 9.3 market news (competitive public feed)
CREATE TABLE IF NOT EXISTS market_news (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id       UUID REFERENCES sessions(id) ON DELETE CASCADE,
  round            INT NOT NULL,
  team_id          UUID REFERENCES teams(id),           -- null = macro/session-wide item
  headline         TEXT NOT NULL,
  detail           TEXT,
  reputation_delta INT DEFAULT 0,
  created_at       TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE market_news ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon_select_market_news" ON market_news FOR SELECT TO anon USING (true);
CREATE POLICY "anon_insert_market_news" ON market_news FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "anon_delete_market_news" ON market_news FOR DELETE TO anon USING (true);

CREATE INDEX IF NOT EXISTS idx_market_news_session ON market_news(session_id, round);

-- realtime
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE market_news;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- case seed
INSERT INTO cases (slug, name, subtitle, difficulty, mode)
VALUES ('suryan', 'Suryan Energy', 'The Subsidy Wave: Competing Through Boom, Crunch, and Sunset', 'complex', 'competitive')
ON CONFLICT (slug) DO UPDATE SET mode = EXCLUDED.mode, difficulty = EXCLUDED.difficulty, subtitle = EXCLUDED.subtitle;
