-- =====================================================================
--  007 · Org storyline + facilitator-keyed observer
--
--  (a) bp_org_story — the published, per-quarter org narrative every login
--      reads. Written only by the facilitator (via bp_publish_story);
--      readable by everyone once published.
--  (b) bp_org_spine — the DETERMINISTIC facts a quarter's chapter is built
--      from (bands, momentum, meter, couplings, achievements). The edge
--      function feeds this to Claude, which writes prose around fixed facts.
--  (c) bp_publish_story — facilitator publishes the chapter to all logins.
--  (d) bp_set_observer — the observed style is now keyed in by the
--      FACILITATOR (the observer sits out and reports offline), not entered
--      in a team login.
--  Idempotent — safe to re-run.
-- =====================================================================

-- (a) Published org story -------------------------------------------------
CREATE TABLE IF NOT EXISTS bp_org_story (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id   UUID NOT NULL REFERENCES bp_sessions(id) ON DELETE CASCADE,
  quarter      INT  NOT NULL,
  body         TEXT NOT NULL,
  published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(session_id, quarter)
);
ALTER TABLE bp_org_story ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bp_pub_org_story ON bp_org_story;
-- Published chapters are meant for the whole room.
CREATE POLICY bp_pub_org_story ON bp_org_story FOR SELECT USING (true);
GRANT SELECT ON bp_org_story TO anon, authenticated;

-- Live push: add to the realtime publication (guarded — no error if present).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='bp_org_story'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE bp_org_story';
  END IF;
END $$;

-- (b) Deterministic spine for a quarter's chapter -------------------------
CREATE OR REPLACE FUNCTION bp_org_spine(p_session_code TEXT, p_access_code TEXT, p_quarter INT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a RECORD; s RECORD;
  v_teams JSONB; v_mom INT; v_tier TEXT; v_prov INT; v_final BOOLEAN;
  hw INT; hw_rev BOOLEAN;
  bb TEXT; bs TEXT; bsp TEXT; bw TEXT; bpr TEXT;
  net JSONB; v_ach JSONB; v_coup JSONB; v_leaders JSONB; v_laggards JSONB;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  v_final := (p_quarter >= 4);

  -- per-team, this quarter + cumulative
  SELECT jsonb_agg(x ORDER BY x->>'code') INTO v_teams FROM (
    SELECT jsonb_build_object(
      'code', t.code, 'name', t.name, 'objective', o.label,
      'band', COALESCE(qr.band,'missed'),
      'points', COALESCE(qr.points,0),
      'got_primary', COALESCE(qr.got_primary,false),
      'got_secondary', COALESCE(qr.got_secondary,false),
      'cumulative_points', COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
          WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0)
    ) AS x
    FROM bp_teams t
    JOIN bp_objectives o ON o.session_id=t.session_id AND o.key=t.objective_key
    LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id AND qr.quarter=p_quarter
    WHERE t.session_id=a.session_id
  ) z;

  v_mom := COALESCE((SELECT SUM(points) FROM bp_quarter_results WHERE session_id=a.session_id AND quarter=p_quarter),0);
  v_tier := CASE WHEN v_mom<=4 THEN 'stalling' WHEN v_mom<=8 THEN 'steady'
                 WHEN v_mom<=11 THEN 'rising' ELSE 'surging' END;

  -- provisional gross (linear proxy on cumulative points → ₹, max 4200/team)
  SELECT COALESCE(SUM(ROUND(cum::numeric/12*4200)),0)::INT INTO v_prov FROM (
    SELECT COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
        WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0) AS cum
    FROM bp_teams t WHERE t.session_id=a.session_id
  ) c;

  v_leaders := (SELECT jsonb_agg(code) FROM (
    SELECT t.code, COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
        WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0) AS cum
    FROM bp_teams t WHERE t.session_id=a.session_id ORDER BY cum DESC, t.code LIMIT 2) q);
  v_laggards := (SELECT jsonb_agg(code) FROM (
    SELECT t.code, COALESCE((SELECT SUM(q2.points) FROM bp_quarter_results q2
        WHERE q2.session_id=a.session_id AND q2.team_id=t.id AND q2.quarter<=p_quarter),0) AS cum
    FROM bp_teams t WHERE t.session_id=a.session_id ORDER BY cum ASC, t.code LIMIT 2) q);

  SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;
  hw_rev := s.headwind_revealed;

  IF v_final THEN
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bb FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='battery';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bs FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='suppliers';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bsp FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='spec';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bw FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='warranty';
    SELECT bp_annual_band(COALESCE(SUM(qr.points),0)::INT) INTO bpr FROM bp_teams t
      LEFT JOIN bp_quarter_results qr ON qr.session_id=a.session_id AND qr.team_id=t.id
      WHERE t.session_id=a.session_id AND t.objective_key='pricing';

    net := bp_org_net(bb,bs,bsp,bw,bpr,hw);
    v_coup := jsonb_build_object(
      'battery_suppliers', CASE WHEN bp_band_rank(bb)>=2  AND bp_band_rank(bs)>=2  THEN 1000  ELSE 0 END,
      'warranty_spec',     CASE WHEN bp_band_rank(bw)>=2  AND bp_band_rank(bsp)>=2 THEN 1000  ELSE 0 END,
      'spec_pricing',      CASE WHEN bp_band_rank(bsp)>=2 AND bp_band_rank(bpr)>=2 THEN -1500 ELSE 0 END);
    v_ach := jsonb_build_array(
      jsonb_build_object('key','cost_curve','label','Cost curve bent','status',      CASE WHEN bp_band_rank(bb)>=2  THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','supply','label','Supply de-risked','status',         CASE WHEN bp_band_rank(bs)>=2  THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','vertical','label','Vertical integration','status',   CASE WHEN bp_band_rank(bb)>=2 AND bp_band_rank(bs)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','product','label','A product that ships','status',     CASE WHEN bp_band_rank(bsp)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','field_trust','label','Field trust held','status',    CASE WHEN bp_band_rank(bw)>=2  THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','qbd','label','Quality by design','status',           CASE WHEN bp_band_rank(bw)>=2 AND bp_band_rank(bsp)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','margin','label','Margin held','status',              CASE WHEN bp_band_rank(bpr)>=2 THEN 'achieved' ELSE 'missed' END),
      jsonb_build_object('key','overreach','label','Overreach: spec + pricing squeeze','status', CASE WHEN bp_band_rank(bsp)>=2 AND bp_band_rank(bpr)>=2 THEN 'warning' ELSE 'clear' END),
      jsonb_build_object('key','headwind','label','Weathered the headwind','status', CASE WHEN (net->>'target_hit')::boolean THEN 'achieved' ELSE 'missed' END)
    );
  END IF;

  RETURN jsonb_build_object(
    'quarter', p_quarter, 'is_final', v_final, 'session_name', s.name,
    'teams', COALESCE(v_teams,'[]'::jsonb),
    'momentum', jsonb_build_object('points', v_mom, 'tier', v_tier),
    'leaders', COALESCE(v_leaders,'[]'::jsonb),
    'laggards', COALESCE(v_laggards,'[]'::jsonb),
    'headwind_revealed', hw_rev,
    'headwind', CASE WHEN hw_rev THEN hw ELSE NULL END,
    'meter', jsonb_build_object(
      'provisional_gross', v_prov,
      'net',        CASE WHEN v_final THEN (net->>'net')::int ELSE NULL END,
      'target',     s.target_value,
      'target_hit', CASE WHEN v_final THEN (net->>'target_hit')::boolean ELSE NULL END),
    'couplings', v_coup,
    'achievements', v_ach
  );
END $$;

-- (c) Publish a chapter to every login ------------------------------------
CREATE OR REPLACE FUNCTION bp_publish_story(p_session_code TEXT, p_access_code TEXT, p_quarter INT, p_body TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF COALESCE(btrim(p_body),'') = '' THEN RAISE EXCEPTION 'empty_body'; END IF;
  INSERT INTO bp_org_story(session_id, quarter, body, published_at)
    VALUES (a.session_id, p_quarter, p_body, now())
    ON CONFLICT (session_id, quarter) DO UPDATE
      SET body=EXCLUDED.body, published_at=now();
  PERFORM bp_log(a.session_id,'facilitator','publish_story', jsonb_build_object('quarter',p_quarter));
  RETURN jsonb_build_object('ok', true);
END $$;

-- (d) Facilitator keys in the observed style (offline observer) ------------
CREATE OR REPLACE FUNCTION bp_set_observer(p_session_code TEXT, p_access_code TEXT,
  p_team UUID, p_style TEXT, p_note TEXT, p_quarter INT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; q INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  q := COALESCE(p_quarter, s.current_quarter);
  IF NOT EXISTS (SELECT 1 FROM bp_teams WHERE id=p_team AND session_id=a.session_id) THEN
    RAISE EXCEPTION 'unknown_team';
  END IF;
  INSERT INTO bp_observer_logs(session_id, team_id, quarter, observed_style, note)
    VALUES (a.session_id, p_team, q, p_style, p_note)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET observed_style=EXCLUDED.observed_style, note=EXCLUDED.note;
  PERFORM bp_log(a.session_id,'facilitator','set_observer', jsonb_build_object('team',p_team,'quarter',q));
  RETURN jsonb_build_object('ok', true);
END $$;
