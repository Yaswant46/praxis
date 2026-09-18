-- =====================================================================
--  013 · Borrowed People — remove the RUNNER_WINDOW phase
--
--  RUNNER_WINDOW carried no scored consequence and overlapped
--  OPEN_NEGOTIATION (both are "go work the characters"). Removing it drops
--  one facilitator advance per quarter. The runner SEAT and the runner
--  style call (bp_style_calls seat='runner') are INDEPENDENT of the phase
--  and are untouched — delegation + declared-vs-observed lessons stay.
--
--  New sequence:
--    BRIEF → TEAM_DISCUSSION → REQUESTS_OPEN → REQUESTS_LOCKED (the reveal)
--    → OPEN_NEGOTIATION → SELECTION → RESULTS → DEBRIEF
--
--  Relative order is preserved, so every bp_phase_index >= comparison
--  (reveal gate, mandate lock, etc.) still holds.
--
--  Applied by hand in the Supabase SQL Editor. Idempotent — safe to re-run.
-- =====================================================================

-- 1. Guard: move any session currently in RUNNER_WINDOW forward.
UPDATE bp_sessions SET current_phase='OPEN_NEGOTIATION' WHERE current_phase='RUNNER_WINDOW';

-- 2. Swap the current_phase CHECK (discover the old one by definition, drop, re-add).
DO $$
DECLARE cname TEXT;
BEGIN
  SELECT conname INTO cname FROM pg_constraint
   WHERE conrelid='bp_sessions'::regclass AND contype='c'
     AND pg_get_constraintdef(oid) LIKE '%RUNNER_WINDOW%';
  IF cname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE bp_sessions DROP CONSTRAINT %I', cname);
  END IF;
END $$;
ALTER TABLE bp_sessions DROP CONSTRAINT IF EXISTS bp_sessions_current_phase_check;
ALTER TABLE bp_sessions ADD CONSTRAINT bp_sessions_current_phase_check
  CHECK (current_phase IN ('BRIEF','TEAM_DISCUSSION','REQUESTS_OPEN','REQUESTS_LOCKED',
                           'OPEN_NEGOTIATION','SELECTION','RESULTS','DEBRIEF'));

-- 3. Shorten the ordered phase arrays.
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
