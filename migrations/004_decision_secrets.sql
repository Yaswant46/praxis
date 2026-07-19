-- =============================================================
--  PRAXIS — MIGRATION 004: decision_secrets (behavioural AI score, GM-only)
--
--  The qualitative AI score must NOT be visible to participants during play.
--  `decisions` is anon-readable (decisions_select USING (true)), so the score
--  can't live there. It lives here, with NO anon policy — invisible to the
--  participant key. The score-behavioural Edge Function writes via the service
--  role (bypasses RLS); the GM/master-admin reads + can override via the
--  existing praxis helpers.
--
--  One qualitative response per team per round → PK (session_id, team_id, round).
-- =============================================================

CREATE TABLE IF NOT EXISTS decision_secrets (
  session_id            UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  team_id               UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  round                 INT  NOT NULL,
  clarity               INT,
  stakeholder_awareness INT,
  ethical_alignment     INT,
  total                 INT,
  people_score          INT,   -- 0–100 (total/15)
  gm_override           INT,   -- GM manual override of people_score (0–100)
  gm_note               TEXT,  -- mandatory reason when overriding
  updated_at            TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (session_id, team_id, round)
);

ALTER TABLE decision_secrets ENABLE ROW LEVEL SECURITY;

-- No anon policy → participants cannot read their AI score. Service role (the
-- Edge Function) bypasses RLS to INSERT. GM/master-admin read + override.
CREATE POLICY decision_secrets_select ON decision_secrets FOR SELECT TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id));
CREATE POLICY decision_secrets_update ON decision_secrets FOR UPDATE TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id))
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));

COMMENT ON TABLE decision_secrets IS
  'Behavioural AI score per team/round. No anon RLS — invisible to participants. Written by the score-behavioural Edge Function (service role); GM reads + overrides.';
