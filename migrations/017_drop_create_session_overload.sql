-- =====================================================================
--  017 · Borrowed People — drop the stale one-argument bp_create_session
--
--  Migration 008 added bp_create_session(p_name, p_variant DEFAULT 'full')
--  but never dropped the original bp_create_session(p_name). With both
--  present PostgREST answers "Could not choose the best candidate
--  function" when the login page creates a session. The two-argument
--  version covers every call. Also fixes the EXECUTE grant entry.
--
--  Applied to the live DB 2026-09-18. Idempotent — safe to re-run.
-- =====================================================================
DROP FUNCTION IF EXISTS public.bp_create_session(text);
GRANT EXECUTE ON FUNCTION public.bp_create_session(text,text) TO anon, authenticated;
