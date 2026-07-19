-- =============================================================
--  PRAXIS — MIGRATION 005: individual_questionnaire_responses
--
--  Stores one row per participant's DARE questionnaire submission. Domain
--  scores are computed at submit time; consistency_index + contradiction_flags
--  are GM-only. RLS follows the split-secrecy pattern: participants may INSERT
--  their submission but may NOT read the table back (they get their scorecard
--  from the submit response, computed client-side, showing participant-safe
--  fields only). GM/master-admin read everything.
-- =============================================================

CREATE TABLE IF NOT EXISTS individual_questionnaire_responses (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id          UUID REFERENCES sessions(id) ON DELETE CASCADE,
  team_id             UUID REFERENCES teams(id),
  participant_email   TEXT,
  participant_name    TEXT,
  responses           JSONB NOT NULL,              -- { Q1:'A', ... Q15:'C' }
  domain_scores       JSONB,                       -- { D,A,R,E } 0–100 (participant-safe)
  proficiency         JSONB,                       -- { D,A,R,E } L1/L2/L3
  consistency_index   TEXT,                        -- GM-only
  contradiction_flags JSONB,                       -- GM-only
  created_at          TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE individual_questionnaire_responses ENABLE ROW LEVEL SECURITY;

-- Participants (anon) may submit; they cannot read the table (no anon SELECT).
CREATE POLICY iqr_insert ON individual_questionnaire_responses FOR INSERT WITH CHECK (true);
-- GM/master-admin read all rows for their session.
CREATE POLICY iqr_select_owner ON individual_questionnaire_responses FOR SELECT TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id));

CREATE INDEX IF NOT EXISTS idx_iqr_session ON individual_questionnaire_responses(session_id);

COMMENT ON TABLE individual_questionnaire_responses IS
  'DARE questionnaire submissions. Anon may INSERT; only GM/master-admin may SELECT. consistency_index + contradiction_flags are GM-only.';
