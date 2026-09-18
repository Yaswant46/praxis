-- =====================================================================
--  014 · Borrowed People — withhold access codes from the API roles
--
--  bp_sessions.facilitator_code and bp_teams.access_code sat on publicly
--  readable tables (SELECT USING (true) + table GRANT). Any participant
--  with DevTools could read the facilitator code and every team code.
--  Column-level SELECT grants keep everything the client needs (Realtime
--  phase pointer on bp_sessions, select('variant'), team names) and
--  withhold the two code columns. bp_auth / bp_state are SECURITY
--  DEFINER and unaffected.
--
--  Applied by hand in the Supabase SQL Editor. Idempotent — safe to re-run.
-- =====================================================================

REVOKE ALL ON bp_sessions, bp_teams FROM anon, authenticated;
GRANT SELECT (id, name, status, current_quarter, current_phase, headwind_revealed,
              target_value, variant, created_at) ON bp_sessions TO anon, authenticated;
GRANT SELECT (id, session_id, code, name, objective_key) ON bp_teams TO anon, authenticated;
GRANT SELECT ON bp_objectives, bp_quarter_results, bp_commitments TO anon, authenticated;
