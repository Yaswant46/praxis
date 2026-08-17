-- =====================================================================
--  PRAXIS · UNIFIED ENROLLMENT
--  One entry URL for every simulation. A participant lands on the entry
--  page, enters a COHORT CODE + their EMAIL, and is routed straight into
--  their specific access — no per-app codes to hand out one by one.
--
--  Access is PRE-REGISTERED: an admin bulk-uploads a roster (CSV) mapping
--  each email to a team / character / facilitator seat. This file is the
--  cross-engine glue; it is namespaced (enroll_*) and additive.
--
--  Idempotent — safe to re-run.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS enrollments (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  cohort_code  TEXT NOT NULL,                 -- human code the admin shares
  email        TEXT NOT NULL,
  name         TEXT,
  app          TEXT NOT NULL CHECK (app IN ('borrowed','praxis')),
  role         TEXT,                           -- participant|character|facilitator|team|gm
  assignment   TEXT,                           -- human label from the CSV (Team A / Arjun / Facilitator)
  access_code  TEXT,                           -- credential handed to the target app
  session_ref  TEXT,                           -- target session id (borrowed) / cohort code (praxis)
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One row per (cohort, email), case-insensitive on both.
CREATE UNIQUE INDEX IF NOT EXISTS enrollments_cohort_email
  ON enrollments (upper(cohort_code), lower(email));

ALTER TABLE enrollments ENABLE ROW LEVEL SECURITY;
-- Deny-all to the API roles; everything flows through the definer RPCs.
REVOKE ALL ON enrollments FROM anon, authenticated;

-- ---------------------------------------------------------------------
--  LOGIN — resolve (cohort code + email) to a routing instruction.
--  No secret is exposed beyond the caller's own access credential.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enroll_login(p_cohort_code TEXT, p_email TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e RECORD;
BEGIN
  SELECT * INTO e FROM enrollments
   WHERE upper(cohort_code) = upper(trim(p_cohort_code))
     AND lower(email)       = lower(trim(p_email));
  IF NOT FOUND THEN RAISE EXCEPTION 'not_enrolled'; END IF;
  RETURN jsonb_build_object(
    'app', e.app, 'role', e.role, 'name', e.name,
    'assignment', e.assignment,
    'access_code', e.access_code, 'session_ref', e.session_ref,
    'email', lower(trim(p_email)));
END $$;

-- ---------------------------------------------------------------------
--  Resolve a human assignment label to a Borrowed People access code,
--  within one session, authorised by that session's facilitator code.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enroll_resolve_bp(p_sid UUID, p_assignment TEXT,
  OUT o_code TEXT, OUT o_role TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a TEXT := upper(trim(p_assignment)); v TEXT;
BEGIN
  o_code := NULL; o_role := NULL;
  -- Facilitator / admin
  IF a IN ('FACILITATOR','ADMIN','GM','FAC') THEN
    SELECT facilitator_code INTO o_code FROM bp_sessions WHERE id=p_sid;
    o_role := 'facilitator'; RETURN;
  END IF;
  -- Team: "A".."E", or "TEAM A", or the team name (Ampere…)
  v := regexp_replace(a, '^TEAM[ _-]*', '');
  SELECT access_code INTO o_code FROM bp_teams
    WHERE session_id=p_sid AND (upper(code)=v OR upper(name)=a OR upper(name)=v);
  IF o_code IS NOT NULL THEN o_role := 'participant'; RETURN; END IF;
  -- Character: by key or name (Arjun / arjun / Sponsor …)
  SELECT access_code INTO o_code FROM bp_characters
    WHERE session_id=p_sid AND (upper(key)=a OR upper(name)=a);
  IF o_code IS NOT NULL THEN o_role := 'character'; RETURN; END IF;
  -- unresolved
END $$;

-- ---------------------------------------------------------------------
--  BULK ROSTER UPLOAD (from a CSV parsed client-side into rows).
--  p_rows: [{ "email":..., "name":..., "assignment":... }, ...]
--  For app='borrowed': p_admin_code must be the facilitator code of the
--  session p_session_ref; assignments resolve to real access codes.
--  Returns a per-row result so the admin sees exactly what mapped.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enroll_bulk(
  p_admin_code TEXT, p_cohort_code TEXT, p_app TEXT, p_session_ref TEXT, p_rows JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sid UUID; row JSONB; v_code TEXT; v_role TEXT;
  v_email TEXT; v_name TEXT; v_assign TEXT;
  n_ok INT := 0; results JSONB := '[]'::jsonb;
BEGIN
  IF p_app <> 'borrowed' THEN
    RAISE EXCEPTION 'unsupported_app';  -- praxis roster is a follow-up
  END IF;

  -- Authorise: admin code must be the facilitator of the named session.
  SELECT id INTO v_sid FROM bp_sessions
    WHERE id = p_session_ref::uuid AND facilitator_code = p_admin_code;
  IF v_sid IS NULL THEN RAISE EXCEPTION 'forbidden'; END IF;

  FOR row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_email  := lower(trim(row->>'email'));
    v_name   := NULLIF(trim(coalesce(row->>'name','')), '');
    v_assign := trim(coalesce(row->>'assignment',''));

    IF v_email = '' OR v_email IS NULL OR position('@' in v_email) = 0 THEN
      results := results || jsonb_build_object('email',row->>'email','assignment',v_assign,'ok',false,'reason','bad_email');
      CONTINUE;
    END IF;

    SELECT o_code, o_role INTO v_code, v_role FROM enroll_resolve_bp(v_sid, v_assign);
    IF v_code IS NULL THEN
      results := results || jsonb_build_object('email',v_email,'assignment',v_assign,'ok',false,'reason','unknown_assignment');
      CONTINUE;
    END IF;

    INSERT INTO enrollments(cohort_code, email, name, app, role, assignment, access_code, session_ref)
    VALUES (p_cohort_code, v_email, v_name, 'borrowed', v_role, v_assign, v_code, v_sid::text)
    ON CONFLICT (upper(cohort_code), lower(email)) DO UPDATE
      SET name=EXCLUDED.name, role=EXCLUDED.role, assignment=EXCLUDED.assignment,
          access_code=EXCLUDED.access_code, session_ref=EXCLUDED.session_ref, app='borrowed';
    n_ok := n_ok + 1;
    results := results || jsonb_build_object('email',v_email,'assignment',v_assign,'ok',true,'role',v_role);
  END LOOP;

  RETURN jsonb_build_object('cohort_code', p_cohort_code, 'enrolled', n_ok,
                            'total', jsonb_array_length(p_rows), 'rows', results);
END $$;

-- ---------------------------------------------------------------------
--  Admin: list the current roster for a session (facilitator-gated).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enroll_list(p_admin_code TEXT, p_session_ref TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_sid UUID;
BEGIN
  SELECT id INTO v_sid FROM bp_sessions
    WHERE id = p_session_ref::uuid AND facilitator_code = p_admin_code;
  IF v_sid IS NULL THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'email',email,'name',name,'assignment',assignment,'role',role,'cohort_code',cohort_code) ORDER BY assignment, email)
    FROM enrollments WHERE session_ref = v_sid::text), '[]'::jsonb);
END $$;

GRANT EXECUTE ON FUNCTION enroll_login(text,text)                       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION enroll_bulk(text,text,text,text,jsonb)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION enroll_list(text,text)                        TO anon, authenticated;
-- enroll_resolve_bp stays internal (called only by enroll_bulk).

-- =====================================================================
--  DONE.
-- =====================================================================
