-- =============================================================
--  PRAXIS — MIGRATION 003: Split-tables secrecy model (foundation)
--
--  GM-only session config that participants must NEVER be able to read.
--  Instead of a column on `sessions` (which anon can SELECT via
--  `sessions_select USING (true)`), sensitive config lives in its OWN table
--  with NO anon policy — so RLS default-deny makes it invisible to the anon
--  (participant) key, while the authenticated GM/master-admin can read+write
--  via the existing helpers (praxis_is_master_admin / praxis_is_session_gm).
--
--  people_weight is ALWAYS (100 - task_weight) — computed, never stored,
--  never exposed to participants.
-- =============================================================

CREATE TABLE IF NOT EXISTS session_secrets (
  session_id  UUID PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  task_weight INT NOT NULL DEFAULT 50 CHECK (task_weight BETWEEN 0 AND 100),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE session_secrets ENABLE ROW LEVEL SECURITY;

-- IMPORTANT: no policy for the `anon` role. With RLS enabled and no matching
-- policy, anon (participant) reads/writes are denied by default — task_weight
-- is unreadable by participants. Only the authenticated GM/master-admin match.
CREATE POLICY session_secrets_select ON session_secrets FOR SELECT TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id));
CREATE POLICY session_secrets_insert ON session_secrets FOR INSERT TO authenticated
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));
CREATE POLICY session_secrets_update ON session_secrets FOR UPDATE TO authenticated
  USING (praxis_is_master_admin() OR praxis_is_session_gm(session_id))
  WITH CHECK (praxis_is_master_admin() OR praxis_is_session_gm(session_id));

COMMENT ON TABLE session_secrets IS
  'GM-only session config (task/people weight). No anon RLS policy — invisible to participants by design.';
