-- =====================================================================
--  016 · Borrowed People — projected year-end on Board 1 before Q4
--
--  bp_boards derived the organisation figure from year-end bands of
--  cumulative points, so the wall read ₹0 after Q1 even when every team
--  delivered. Before Q4, points are now scaled to four quarters
--  (run-rate) and the payload carries org.projected / org.quarters_played
--  so the client can label it. Converges to the true bands at Q4.
--  Only bp_boards changes; reproduced in full from the schema file.
--
--  Applied by hand in the Supabase SQL Editor. Idempotent — safe to re-run.
-- =====================================================================

CREATE OR REPLACE FUNCTION bp_boards(p_session_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s RECORD; b JSONB; teams JSONB; org JSONB; hw INT; rev BOOLEAN;
  bands JSONB := '{}'::jsonb; trow RECORD; tot INT; ab TEXT; qp INT;
BEGIN
  SELECT * INTO s FROM bp_sessions WHERE id=p_session_id;
  SELECT headwind_revealed INTO rev FROM bp_sessions WHERE id=p_session_id;

  teams := (SELECT jsonb_agg(jsonb_build_object(
      'team_id', t.id, 'code', t.code, 'name', t.name, 'objective_key', t.objective_key,
      'quarters', (SELECT jsonb_object_agg(quarter::text, jsonb_build_object(
                     'band',band,'points',points,'avg_rating',avg_rating))
                   FROM bp_quarter_results qr WHERE qr.session_id=p_session_id AND qr.team_id=t.id),
      'total_points', COALESCE((SELECT SUM(points) FROM bp_quarter_results qr WHERE qr.session_id=p_session_id AND qr.team_id=t.id),0)
    ) ORDER BY t.code)
    FROM bp_teams t WHERE t.session_id=p_session_id);

  -- annual bands per objective for org couplings.
  -- Before Q4 the org number is a PROJECTED year-end (migration 016): points so
  -- far are scaled to four quarters, so the wall shows a real figure from the
  -- Q1 results onward instead of ₹0 until the year closes. Converges to the
  -- true annual bands at Q4.
  SELECT COALESCE(MAX(quarter),0) INTO qp FROM bp_quarter_results WHERE session_id=p_session_id;
  FOR trow IN SELECT id, objective_key FROM bp_teams WHERE session_id=p_session_id LOOP
    SELECT COALESCE(SUM(points),0) INTO tot FROM bp_quarter_results WHERE session_id=p_session_id AND team_id=trow.id;
    IF qp BETWEEN 1 AND 3 THEN tot := LEAST(12, ROUND(tot * 4.0 / qp)::INT); END IF;
    bands := bands || jsonb_build_object(trow.objective_key, bp_annual_band(tot));
  END LOOP;

  SELECT value INTO hw FROM bp_headwind WHERE session_id=p_session_id;
  IF rev THEN
    org := bp_org_net(bands->>'battery',bands->>'suppliers',bands->>'spec',bands->>'warranty',bands->>'pricing', hw);
  ELSE
    -- before reveal: show gross only, "before headwind"
    org := bp_org_net(bands->>'battery',bands->>'suppliers',bands->>'spec',bands->>'warranty',bands->>'pricing', 0)
           - 'target_hit' - 'net';
    org := org || jsonb_build_object('before_headwind', true);
  END IF;

  org := org || jsonb_build_object('projected', (qp BETWEEN 1 AND 3), 'quarters_played', qp);
  RETURN jsonb_build_object(
    'quarter', s.current_quarter, 'phase', s.current_phase, 'status', s.status,
    'target_value', s.target_value, 'headwind_revealed', rev,
    'annual_bands', bands, 'teams', teams, 'org', org);
END $$;
