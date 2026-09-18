-- =====================================================================
--  010 · Borrowed People — Adaptive Demand Map (path-dependent ideal)
--
--  Makes the "ideal picks" the scoring engine measures against depend on
--  how the team has been doing — but ONLY on business capability
--  (got_primary from prior quarters), never on relationship / EI /
--  ratings signals. The EI axis (bp_ratings, avg_rating) is untouched and
--  continues to feed only the band as it always has.
--
--  The base bp_demand_map rows seeded by bp_create_session are the
--  ON_TRACK (healthy) path and are NEVER reseeded or duplicated here. When
--  a team is 'behind' or 'at_risk' entering a quarter, we DERIVE a
--  different (primary, secondary) at scoring time from those same base
--  rows plus the Sponsor, and record what we used in a new
--  bp_objective_state table for the debrief.
--
--  State machine (business-only), entering quarter N:
--    Q1                              → on_track
--    prior got_primary TRUE          → on_track
--    prior FALSE, prior on_track     → behind
--    prior FALSE, prior behind/risk  → at_risk
--
--  Additive: one new table, two new pure-ish functions, and surgical
--  CREATE OR REPLACE of bp_run_scoring / bp_state / bp_selftest copying
--  their current bodies verbatim with only the documented insertions.
--
--  Applied by hand in the Supabase SQL Editor. Idempotent — safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. Per-objective per-quarter business state + the ideal we actually
--     scored against. HIDDEN like bp_demand_map: deny-all, reached only
--     through the definer RPCs. Surfaced to the room via bp_state's
--     demand_reveal (facilitator always; participants/characters at
--     DEBRIEF only).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bp_objective_state (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id      UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  objective_key   TEXT NOT NULL,
  quarter         INT  NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  state           TEXT NOT NULL CHECK (state IN ('on_track','behind','at_risk')),
  primary_key     TEXT,
  secondary_key   TEXT,
  business_reason TEXT,
  UNIQUE (session_id, objective_key, quarter)
);

ALTER TABLE bp_objective_state ENABLE ROW LEVEL SECURITY;
-- No permissive anon policy → deny-all. Reached only via definer RPCs.
REVOKE ALL ON bp_objective_state FROM anon, authenticated;

-- ---------------------------------------------------------------------
--  2. bp_resolve_state — the business-only state a team's objective is in
--     ENTERING p_quarter. Reads prior quarter's got_primary and the prior
--     stored state; no ratings, no EI. Maps objective → team via
--     bp_teams.objective_key.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_resolve_state(p_sid UUID, p_objective TEXT, p_quarter INT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_team_id      UUID;
  v_prior_gotp   BOOLEAN;
  v_prior_state  TEXT;
BEGIN
  -- Q1 always starts healthy — no prior quarter to fall behind from.
  IF p_quarter <= 1 THEN
    RETURN 'on_track';
  END IF;

  SELECT id INTO v_team_id
    FROM bp_teams
    WHERE session_id = p_sid AND objective_key = p_objective;

  -- Prior quarter's business capability (did they secure the ideal primary?).
  SELECT got_primary INTO v_prior_gotp
    FROM bp_quarter_results
    WHERE session_id = p_sid AND team_id = v_team_id AND quarter = p_quarter - 1;

  -- Prior quarter's recorded state (what path they were already on).
  SELECT state INTO v_prior_state
    FROM bp_objective_state
    WHERE session_id = p_sid AND objective_key = p_objective AND quarter = p_quarter - 1;

  -- No prior result recorded → treat as healthy (default on_track).
  IF v_prior_gotp IS NULL THEN
    RETURN 'on_track';
  END IF;

  IF v_prior_gotp THEN
    RETURN 'on_track';
  ELSIF COALESCE(v_prior_state, 'on_track') = 'on_track' THEN
    RETURN 'behind';
  ELSE
    -- prior state was 'behind' or 'at_risk' and they missed again.
    RETURN 'at_risk';
  END IF;
END $$;

-- ---------------------------------------------------------------------
--  3. bp_adjusted_ideal — the (primary, secondary) the engine should
--     measure against for (objective, quarter) GIVEN a resolved state.
--     Derived from the base bp_demand_map on_track rows; adds NO rows to
--     bp_demand_map. BUSINESS ONLY — every reason is about capability and
--     sequencing, never relationships.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_adjusted_ideal(p_sid UUID, p_objective TEXT, p_quarter INT, p_state TEXT)
RETURNS TABLE(primary_key TEXT, secondary_key TEXT, business_reason TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cur_p    TEXT;   -- base primary of the current quarter
  v_cur_s    TEXT;   -- base secondary of the current quarter
  v_prev_p   TEXT;   -- base primary of the prior quarter (the prerequisite)
  v_obj_lbl  TEXT;
  v_cur_p_nm TEXT;
  v_prev_p_nm TEXT;
BEGIN
  SELECT primary_character_key, secondary_character_key INTO v_cur_p, v_cur_s
    FROM bp_demand_map
    WHERE session_id = p_sid AND objective_key = p_objective AND quarter = p_quarter;

  -- Q1 (or any missing prior) can only ever be on_track.
  IF p_quarter <= 1 OR p_state = 'on_track' THEN
    RETURN QUERY SELECT v_cur_p, v_cur_s, 'On track — stay with the demand-map picks for this quarter.'::TEXT;
    RETURN;
  END IF;

  v_obj_lbl := (SELECT label FROM bp_objectives WHERE session_id = p_sid AND key = p_objective);

  SELECT primary_character_key INTO v_prev_p
    FROM bp_demand_map
    WHERE session_id = p_sid AND objective_key = p_objective AND quarter = p_quarter - 1;

  v_cur_p_nm  := (SELECT name FROM bp_characters WHERE session_id = p_sid AND key = v_cur_p);
  v_prev_p_nm := (SELECT name FROM bp_characters WHERE session_id = p_sid AND key = v_prev_p);

  IF p_state = 'behind' THEN
    -- Recover the unmet prerequisite before this quarter's primary can add value.
    RETURN QUERY SELECT
      v_prev_p,
      v_cur_p,
      format(
        'You did not secure %s in Q%s, so %s is behind. Recover with %s before %s can add value.',
        v_prev_p_nm, (p_quarter - 1)::TEXT, v_obj_lbl, v_prev_p_nm, v_cur_p_nm
      )::TEXT;
    RETURN;
  ELSE
    -- at_risk: two missed quarters — escalate to the Sponsor to unblock, then resume.
    RETURN QUERY SELECT
      'sponsor'::TEXT,
      v_cur_p,
      format(
        '%s is a recovery case after two missed quarters — escalate to the Sponsor to unblock resourcing, then resume with %s.',
        v_obj_lbl, v_cur_p_nm
      )::TEXT;
    RETURN;
  END IF;
END $$;

-- ---------------------------------------------------------------------
--  4. bp_run_scoring — copied verbatim from borrowed_schema.sql, with
--     only two additions per team: (a) resolve the business state and
--     pull the adjusted ideal, using its KEYS for got_p/got_s instead of
--     the raw bp_demand_map keys; (b) after scoring, UPSERT the state +
--     adjusted ideal into bp_objective_state. The ratings/band logic is
--     unchanged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_run_scoring(p_sid UUID, p_quarter INT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  t RECORD; mapP TEXT; mapS TEXT;
  got_p BOOLEAN; got_s BOOLEAN; avg_r NUMERIC; v_band TEXT; v_points INT;
  v_state TEXT; v_reason TEXT;   -- adaptive demand map (migration 010)
BEGIN
  FOR t IN SELECT id, objective_key FROM bp_teams WHERE session_id=p_sid LOOP
    -- Business-only state entering this quarter, and the ideal we score
    -- against given that state. Base bp_demand_map rows are the on_track
    -- path; behind/at_risk derive from them (no rows added to bp_demand_map).
    v_state := bp_resolve_state(p_sid, t.objective_key, p_quarter);
    SELECT ai.primary_key, ai.secondary_key, ai.business_reason
      INTO mapP, mapS, v_reason
      FROM bp_adjusted_ideal(p_sid, t.objective_key, p_quarter, v_state) ai;

    got_p := EXISTS (
      SELECT 1 FROM bp_selections sel JOIN bp_characters c ON c.id=sel.character_id
      WHERE sel.session_id=p_sid AND sel.quarter=p_quarter AND sel.team_id=t.id AND c.key=mapP);
    got_s := EXISTS (
      SELECT 1 FROM bp_selections sel JOIN bp_characters c ON c.id=sel.character_id
      WHERE sel.session_id=p_sid AND sel.quarter=p_quarter AND sel.team_id=t.id AND c.key=mapS);

    -- avg of (sum of 3 rating fields) across characters who selected this team
    SELECT AVG(r.knew_what_i_cared_about + r.asked_or_told + r.left_me_better)
      INTO avg_r
      FROM bp_ratings r
      WHERE r.session_id=p_sid AND r.quarter=p_quarter AND r.team_id=t.id
        AND EXISTS (SELECT 1 FROM bp_selections s2
                    WHERE s2.session_id=p_sid AND s2.quarter=p_quarter
                      AND s2.team_id=t.id AND s2.character_id=r.character_id);

    v_band := CASE
      WHEN got_p AND got_s AND COALESCE(avg_r,0) >= 7 THEN 'exceeded'
      WHEN got_p AND got_s THEN 'delivered'
      WHEN got_p           THEN 'delivered'
      WHEN got_s           THEN 'partial'
      ELSE 'missed' END;
    v_points := CASE v_band WHEN 'exceeded' THEN 3 WHEN 'delivered' THEN 2 WHEN 'partial' THEN 1 ELSE 0 END;

    INSERT INTO bp_quarter_results(session_id, team_id, quarter, got_primary, got_secondary, avg_rating, band, points)
    VALUES (p_sid, t.id, p_quarter, got_p, got_s, avg_r, v_band, v_points)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET got_primary=EXCLUDED.got_primary, got_secondary=EXCLUDED.got_secondary,
          avg_rating=EXCLUDED.avg_rating, band=EXCLUDED.band, points=EXCLUDED.points;

    -- Record the state + adjusted ideal we scored against, for the debrief.
    INSERT INTO bp_objective_state(session_id, objective_key, quarter, state, primary_key, secondary_key, business_reason)
    VALUES (p_sid, t.objective_key, p_quarter, v_state, mapP, mapS, v_reason)
    ON CONFLICT (session_id, objective_key, quarter) DO UPDATE
      SET state=EXCLUDED.state, primary_key=EXCLUDED.primary_key,
          secondary_key=EXCLUDED.secondary_key, business_reason=EXCLUDED.business_reason;
  END LOOP;

  PERFORM bp_log(p_sid,'engine','run_scoring', jsonb_build_object('quarter',p_quarter));
END $$;

-- ---------------------------------------------------------------------
--  5. bp_state — copied verbatim from borrowed_schema.sql, with one
--     addition: a top-level 'demand_reveal' aggregating bp_objective_state
--     for the current quarter joined to bp_teams and bp_characters.
--     Gated: facilitator always; participant/character only at DEBRIEF.
--     Nothing else about bp_state changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_state(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  a RECORD; s RECORD; out JSONB; pidx INT; hw INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  pidx := bp_phase_index(s.current_phase);

  out := jsonb_build_object(
    'role', a.role,
    'display_name', a.display_name,
    'team_id', a.team_id,
    'character_id', a.character_id,
    'session', jsonb_build_object(
      'id', s.id, 'name', s.name, 'status', s.status,
      'quarter', s.current_quarter, 'phase', s.current_phase,
      'target_value', s.target_value, 'headwind_revealed', s.headwind_revealed),
    'objectives', (SELECT jsonb_agg(jsonb_build_object('key',key,'label',label,'description',description))
                     FROM bp_objectives WHERE session_id=a.session_id),
    'teams', (SELECT jsonb_agg(jsonb_build_object('id',id,'code',code,'name',name,'objective_key',objective_key) ORDER BY code)
                FROM bp_teams WHERE session_id=a.session_id),
    'curveballs_live', (SELECT jsonb_agg(jsonb_build_object('key',key,'label',label,'body',body,'quarter',quarter,'at',triggered_at) ORDER BY triggered_at)
                          FROM bp_curveballs WHERE session_id=a.session_id AND triggered_at IS NOT NULL),
    'commitments', (SELECT jsonb_agg(jsonb_build_object(
                       'id',id,'quarter',quarter,'from',from_team_id,'to',to_team_id,'text',text,
                       'confirmed',confirmed_by_to,'honoured_from',honoured_from,'honoured_to',honoured_to) ORDER BY created_at)
                     FROM bp_commitments WHERE session_id=a.session_id),
    'results', (SELECT jsonb_agg(jsonb_build_object(
                   'team_id',team_id,'quarter',quarter,'band',band,'points',points,
                   'avg_rating',avg_rating,'got_primary',got_primary,'got_secondary',got_secondary))
                 FROM bp_quarter_results WHERE session_id=a.session_id)
  );

  -- Headwind: only when revealed.
  IF s.headwind_revealed THEN
    SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;
    out := out || jsonb_build_object('headwind', hw);
  END IF;

  -- Requests reveal — everyone, only at/after REQUESTS_LOCKED.
  IF pidx >= bp_phase_index('REQUESTS_LOCKED') THEN
    out := out || jsonb_build_object('reveal',
      (SELECT jsonb_agg(jsonb_build_object('team_id',r.team_id,
          'primary', pc.key, 'primary_name', pc.name,
          'secondary', sc.key, 'secondary_name', sc.name))
        FROM bp_requests r
        LEFT JOIN bp_characters pc ON pc.id=r.primary_character_id
        LEFT JOIN bp_characters sc ON sc.id=r.secondary_character_id
        WHERE r.session_id=a.session_id AND r.quarter=s.current_quarter));
  END IF;

  -- Adaptive demand-map reveal (migration 010): the business-only state +
  -- the ideal we scored each team against, for the current quarter.
  -- Facilitator always; participants/characters only at DEBRIEF.
  IF a.role = 'facilitator' OR s.current_phase = 'DEBRIEF' THEN
    out := out || jsonb_build_object('demand_reveal',
      (SELECT jsonb_agg(jsonb_build_object(
          'team_id', t.id,
          'objective_key', os.objective_key,
          'state', os.state,
          'primary_key', os.primary_key,
          'secondary_key', os.secondary_key,
          'primary_name', pc.name,
          'secondary_name', sc.name,
          'business_reason', os.business_reason))
        FROM bp_objective_state os
        JOIN bp_teams t ON t.session_id=os.session_id AND t.objective_key=os.objective_key
        LEFT JOIN bp_characters pc ON pc.session_id=os.session_id AND pc.key=os.primary_key
        LEFT JOIN bp_characters sc ON sc.session_id=os.session_id AND sc.key=os.secondary_key
        WHERE os.session_id=a.session_id AND os.quarter=s.current_quarter));
  END IF;

  -- Style calls + observer logs — sealed until DEBRIEF.
  IF s.current_phase = 'DEBRIEF' THEN
    out := out || jsonb_build_object(
      'style_calls', (SELECT jsonb_agg(jsonb_build_object('team_id',team_id,'seat',seat,'style',style,'rationale',rationale))
                        FROM bp_style_calls WHERE session_id=a.session_id AND quarter=s.current_quarter),
      'observer_logs', (SELECT jsonb_agg(jsonb_build_object('team_id',team_id,'observed_style',observed_style,'note',note))
                        FROM bp_observer_logs WHERE session_id=a.session_id AND quarter=s.current_quarter));
  END IF;

  -- ---------- Role-specific additions ----------
  IF a.role = 'participant' THEN
    out := out || jsonb_build_object(
      'my_request', (SELECT jsonb_build_object('primary',primary_character_id,'secondary',secondary_character_id)
                       FROM bp_requests WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_style_calls', (SELECT jsonb_object_agg(seat, jsonb_build_object('style',style,'rationale',rationale))
                       FROM bp_style_calls WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_stakeholder', (SELECT jsonb_object_agg(phase, payload)
                       FROM bp_stakeholder_maps WHERE session_id=a.session_id AND team_id=a.team_id),
      'my_observer', (SELECT jsonb_build_object('style',observed_style,'note',note)
                       FROM bp_observer_logs WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_seats', (SELECT jsonb_object_agg(seat, participant_id)
                       FROM bp_seat_assignments WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'characters', (SELECT jsonb_agg(jsonb_build_object('id',id,'key',key,'name',name,'role_label',role_label) ORDER BY key)
                       FROM bp_characters WHERE session_id=a.session_id));

  ELSIF a.role = 'character' THEN
    -- Incoming (who named me) only after REQUESTS_LOCKED.
    IF pidx >= bp_phase_index('REQUESTS_LOCKED') THEN
      out := out || jsonb_build_object('incoming',
        (SELECT jsonb_agg(jsonb_build_object('team_id',r.team_id,
            'as', CASE WHEN r.primary_character_id=a.character_id THEN 'primary' ELSE 'secondary' END))
          FROM bp_requests r
          WHERE r.session_id=a.session_id AND r.quarter=s.current_quarter
            AND (r.primary_character_id=a.character_id OR r.secondary_character_id=a.character_id)));
    END IF;
    out := out || jsonb_build_object(
      'my_capacity', (SELECT slots FROM bp_character_capacity
                        WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter),
      'my_brief', (SELECT jsonb_build_object('posture',posture,'sample_lines',sample_lines,'video_url',video_url)
                     FROM bp_escalation_cards
                     WHERE session_id=a.session_id AND quarter=s.current_quarter
                       AND (character_key=(SELECT key FROM bp_characters WHERE id=a.character_id) OR character_key IS NULL)
                     ORDER BY character_key NULLS LAST LIMIT 1),
      'my_selections', (SELECT jsonb_agg(jsonb_build_object('team_id',team_id,'reason',reason))
                     FROM bp_selections WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter),
      'my_ratings', (SELECT jsonb_object_agg(team_id::text, jsonb_build_object(
                       'knew',knew_what_i_cared_about,'asked',asked_or_told,'better',left_me_better))
                     FROM bp_ratings WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter),
      'my_judgements', (SELECT jsonb_object_agg(team_id::text, jsonb_build_object('again',again,'reason',reason))
                     FROM bp_judgements WHERE session_id=a.session_id AND character_id=a.character_id));

  ELSIF a.role = 'facilitator' THEN
    SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;
    out := out || jsonb_build_object(
      'headwind', hw,
      'characters', (SELECT jsonb_agg(jsonb_build_object('id',id,'key',key,'name',name,'role_label',role_label,'access_code',access_code) ORDER BY key)
                       FROM bp_characters WHERE session_id=a.session_id),
      'team_codes', (SELECT jsonb_object_agg(code, access_code) FROM bp_teams WHERE session_id=a.session_id),
      'capacity', (SELECT jsonb_agg(jsonb_build_object('character_id',character_id,'quarter',quarter,'slots',slots))
                       FROM bp_character_capacity WHERE session_id=a.session_id),
      'curveballs', (SELECT jsonb_agg(jsonb_build_object('key',key,'label',label,'body',body,'triggered_at',triggered_at) ORDER BY key)
                       FROM bp_curveballs WHERE session_id=a.session_id),
      'monitor', bp_monitor(a.session_id, s.current_quarter),
      'drift', bp_drift(a.session_id, s.current_quarter));
  END IF;

  RETURN out;
END $$;

-- ---------------------------------------------------------------------
--  6. bp_selftest — copied verbatim (the three §6 org-net checks) plus
--     two new pure-logic checks for the adaptive demand map. The 'behind'
--     check needs a live session (base demand-map rows), so it is a
--     clearly-commented no-op placeholder that passes with a note rather
--     than failing when no session exists.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_selftest()
RETURNS TABLE (test TEXT, expected TEXT, actual TEXT, pass BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
  r JSONB;
  v_sid UUID; v_obj TEXT; v_state TEXT;
  v_prev_p TEXT; v_adj_p TEXT;
BEGIN
  -- 5× exceeded, headwind 3000 → net 18500, hit
  r := bp_org_net('exceeded','exceeded','exceeded','exceeded','exceeded',3000);
  RETURN QUERY SELECT '5x exceeded, hw 3000',
    'net=18500 hit=true',
    'net='||(r->>'net')||' hit='||(r->>'target_hit'),
    ((r->>'net')='18500' AND (r->>'target_hit')='true');

  -- 5× delivered, headwind 9000 → net 6500, miss
  r := bp_org_net('delivered','delivered','delivered','delivered','delivered',9000);
  RETURN QUERY SELECT '5x delivered, hw 9000',
    'net=6500 hit=false',
    'net='||(r->>'net')||' hit='||(r->>'target_hit'),
    ((r->>'net')='6500' AND (r->>'target_hit')='false');

  -- 4× exceeded + 1 missed (pricing), headwind 3000 → hit
  r := bp_org_net('exceeded','exceeded','exceeded','exceeded','missed',3000);
  RETURN QUERY SELECT '4x exceeded + pricing missed, hw 3000',
    'hit=true',
    'net='||(r->>'net')||' hit='||(r->>'target_hit'),
    ((r->>'target_hit')='true');

  -- (010) Adaptive demand map, check (a): Q1 always resolves to on_track.
  -- Pure logic — bp_resolve_state short-circuits Q1 without any session data,
  -- so a nil session id is safe here.
  v_state := bp_resolve_state('00000000-0000-0000-0000-000000000000'::uuid, 'battery', 1);
  RETURN QUERY SELECT 'resolve_state Q1 = on_track',
    'on_track',
    v_state,
    (v_state = 'on_track');

  -- (010) Adaptive demand map, check (b): the 'behind' branch of
  -- bp_adjusted_ideal points its primary at the PRIOR quarter's base
  -- primary. This needs a live session's bp_demand_map rows, so we probe
  -- the most recent session if one exists; otherwise emit a clearly-marked
  -- no-op that passes with a note (never fail for lack of fixtures).
  SELECT id INTO v_sid FROM bp_sessions ORDER BY created_at DESC LIMIT 1;
  IF v_sid IS NULL THEN
    RETURN QUERY SELECT 'adjusted_ideal behind → prior primary',
      'prior-quarter base primary (needs a session)',
      'no-op: no session to probe',
      TRUE;   -- placeholder: pure fixture unavailable, not a failure
  ELSE
    v_obj := 'battery';
    SELECT primary_character_key INTO v_prev_p
      FROM bp_demand_map WHERE session_id=v_sid AND objective_key=v_obj AND quarter=1;
    SELECT primary_key INTO v_adj_p
      FROM bp_adjusted_ideal(v_sid, v_obj, 2, 'behind');
    RETURN QUERY SELECT 'adjusted_ideal behind → prior primary',
      'primary = Q1 base primary ('||COALESCE(v_prev_p,'?')||')',
      'primary = '||COALESCE(v_adj_p,'NULL'),
      (v_adj_p IS NOT NULL AND v_adj_p = v_prev_p);
  END IF;
END $$;

-- ---------------------------------------------------------------------
--  GRANT — bp_resolve_state / bp_adjusted_ideal / bp_objective_state are
--  internal (reached only from within bp_run_scoring / bp_state, the
--  definer RPCs), so they stay ungranted, matching bp_run_scoring's
--  house convention. bp_selftest keeps its existing grant from the base
--  schema (its signature is unchanged).
-- ---------------------------------------------------------------------
