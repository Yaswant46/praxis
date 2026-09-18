-- =====================================================================
--  018 · Borrowed People — facilitator & team visibility (history included)
--
--  Additive only; no table changes.
--   · bp_monitor: has_premap / has_postmap / has_mandate per team.
--   · bp_drift:   capacity this quarter + locked (pressed "Lock my selection").
--   · bp_select_teams: the lock event now records the quarter.
--   · bp_state (participant): my_backers — per quarter, the characters who
--     chose the team, with whether the team had asked for them. Names only.
--     Past quarters always visible; the current one from RESULTS.
--   · bp_state (facilitator): selection_history (every pick, all quarters,
--     live for the current one, with reasons) and stakeholder_all (every
--     team's pre/post map).
--  Functions reproduced in full from the schema file.
--
--  Applied to the live DB 2026-09-18. Idempotent — safe to re-run.
-- =====================================================================

CREATE OR REPLACE FUNCTION bp_monitor(p_sid UUID, p_quarter INT)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_agg(jsonb_build_object(
    'team_id', t.id, 'code', t.code,
    'has_request',   EXISTS(SELECT 1 FROM bp_requests    r WHERE r.session_id=p_sid AND r.team_id=t.id AND r.quarter=p_quarter),
    'style_calls',   (SELECT COUNT(*) FROM bp_style_calls sc WHERE sc.session_id=p_sid AND sc.team_id=t.id AND sc.quarter=p_quarter),
    'has_observer',  EXISTS(SELECT 1 FROM bp_observer_logs o WHERE o.session_id=p_sid AND o.team_id=t.id AND o.quarter=p_quarter),
    -- migration 018: readiness the facilitator could not see before
    'has_premap',    EXISTS(SELECT 1 FROM bp_stakeholder_maps m WHERE m.session_id=p_sid AND m.team_id=t.id AND m.phase='pre'),
    'has_postmap',   EXISTS(SELECT 1 FROM bp_stakeholder_maps m WHERE m.session_id=p_sid AND m.team_id=t.id AND m.phase='post'),
    'has_mandate',   EXISTS(SELECT 1 FROM bp_mandate_decisions md WHERE md.session_id=p_sid AND md.team_id=t.id AND md.quarter=p_quarter)
  ) ORDER BY t.code)
  FROM bp_teams t WHERE t.session_id=p_sid;
$$;

CREATE OR REPLACE FUNCTION bp_drift(p_sid UUID, p_quarter INT)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_agg(x ORDER BY x->>'key') FROM (
    SELECT jsonb_build_object(
      'character_id', c.id, 'key', c.key, 'name', c.name,
      -- migration 018: capacity this quarter, and whether the character has pressed Lock (event log)
      'capacity', (SELECT slots FROM bp_character_capacity cc WHERE cc.session_id=p_sid AND cc.character_id=c.id AND cc.quarter=p_quarter),
      'locked',   EXISTS(SELECT 1 FROM bp_events e WHERE e.session_id=p_sid AND e.action='select'
                         AND e.payload->>'character'=c.id::text AND (e.payload->>'quarter')::int=p_quarter),
      'selected', (SELECT COUNT(*) FROM bp_selections s WHERE s.session_id=p_sid AND s.character_id=c.id AND s.quarter=p_quarter),
      'rated',    (SELECT COUNT(*) FROM bp_ratings r WHERE r.session_id=p_sid AND r.character_id=c.id AND r.quarter=p_quarter),
      'spread',   COALESCE((SELECT MAX(tot)-MIN(tot) FROM (
                     SELECT knew_what_i_cared_about+asked_or_told+left_me_better AS tot
                     FROM bp_ratings r WHERE r.session_id=p_sid AND r.character_id=c.id AND r.quarter=p_quarter) z), 0),
      'compressed', COALESCE((SELECT (MAX(tot)-MIN(tot)) <= 1 AND COUNT(*) >= 2 FROM (
                     SELECT knew_what_i_cared_about+asked_or_told+left_me_better AS tot
                     FROM bp_ratings r WHERE r.session_id=p_sid AND r.character_id=c.id AND r.quarter=p_quarter) z), false)
    ) AS x
    FROM bp_characters c WHERE c.session_id=p_sid AND c.key <> 'sponsor'
  ) q;
$$;

CREATE OR REPLACE FUNCTION bp_select_teams(p_session_code TEXT, p_access_code TEXT, p_picks JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; cap INT; pick JSONB;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'character' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF s.current_phase NOT IN ('SELECTION') THEN RAISE EXCEPTION 'selection_not_open'; END IF;
  SELECT slots INTO cap FROM bp_character_capacity
    WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter;
  IF jsonb_array_length(p_picks) > cap THEN RAISE EXCEPTION 'over_capacity'; END IF;
  -- replace this character's picks for the quarter
  DELETE FROM bp_selections WHERE session_id=a.session_id AND character_id=a.character_id AND quarter=s.current_quarter;
  FOR pick IN SELECT * FROM jsonb_array_elements(p_picks) LOOP
    IF COALESCE(pick->>'reason','') = '' THEN RAISE EXCEPTION 'reason_required'; END IF;
    INSERT INTO bp_selections(session_id, character_id, quarter, team_id, reason)
      VALUES (a.session_id, a.character_id, s.current_quarter, (pick->>'team_id')::uuid, pick->>'reason');
  END LOOP;
  PERFORM bp_log(a.session_id,'character','select',jsonb_build_object('character',a.character_id,'n',jsonb_array_length(p_picks),'quarter',s.current_quarter));
  RETURN jsonb_build_object('ok',true);
END $$;

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

  -- Mandate reveal (migration 011): per-team stance × directive alignment →
  -- the leadership cell. Everyone at DEBRIEF; facilitator always.
  IF a.role = 'facilitator' OR s.current_phase = 'DEBRIEF' THEN
    out := out || jsonb_build_object('mandate_reveal',
      (SELECT jsonb_agg(jsonb_build_object(
          'team_id', t.id,
          'stance', md.stance,
          'dissent_line', md.dissent_line,
          'alignment', d.alignment,
          'leadership_cell', bp_leadership_cell(md.stance, d.alignment)))
        FROM bp_teams t
        LEFT JOIN bp_directives d
          ON d.session_id=a.session_id AND d.team_id=t.id AND d.quarter=s.current_quarter
        LEFT JOIN bp_mandate_decisions md
          ON md.session_id=a.session_id AND md.team_id=t.id AND md.quarter=s.current_quarter
        WHERE t.session_id=a.session_id));
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
                       FROM bp_characters WHERE session_id=a.session_id),
      -- Mandate (migration 011). my_directive is visible from BRIEF onward
      -- (always, if a row exists); alignment is NOT surfaced to the team.
      -- my_mandate is the team's own stance for the current quarter.
      'my_directive', (SELECT jsonb_build_object('text',directive_text,'intended_benefit',intended_benefit)
                       FROM bp_directives WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_mandate', (SELECT jsonb_build_object('stance',stance,'dissent_line',dissent_line)
                       FROM bp_mandate_decisions WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter));
    -- migration 018: who gave this team their time, per quarter. A quarter is
    -- visible once it is past, or once the current one has reached RESULTS.
    -- Names only — the character's written reason never reaches the team.
    out := out || jsonb_build_object('my_backers',
      (SELECT COALESCE(jsonb_agg(jsonb_build_object('quarter', g.q, 'visible', g.vis, 'characters', g.chars) ORDER BY g.q), '[]'::jsonb)
       FROM (
         SELECT q,
           (q < s.current_quarter OR s.current_phase IN ('RESULTS','DEBRIEF') OR s.status='closed') AS vis,
           CASE WHEN (q < s.current_quarter OR s.current_phase IN ('RESULTS','DEBRIEF') OR s.status='closed') THEN
             COALESCE((SELECT jsonb_agg(jsonb_build_object('key', c.key, 'name', c.name,
                 'requested', CASE WHEN r.primary_character_id=c.id THEN 'primary'
                                   WHEN r.secondary_character_id=c.id THEN 'secondary' ELSE NULL END) ORDER BY c.key)
               FROM bp_selections sel
               JOIN bp_characters c ON c.id=sel.character_id
               LEFT JOIN bp_requests r ON r.session_id=sel.session_id AND r.team_id=sel.team_id AND r.quarter=sel.quarter
               WHERE sel.session_id=a.session_id AND sel.team_id=a.team_id AND sel.quarter=q), '[]'::jsonb)
           ELSE NULL END AS chars
         FROM generate_series(1, GREATEST(s.current_quarter,1)) AS q
       ) g));

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
      'drift', bp_drift(a.session_id, s.current_quarter),
      -- migration 018: every selection so far (all quarters, current one live)
      -- and every team's stakeholder maps, for the facilitator only.
      'selection_history', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'quarter', sel.quarter, 'character_key', c.key, 'character_name', c.name,
            'team_id', t.id, 'team_code', t.code, 'reason', sel.reason,
            'requested', CASE WHEN r.primary_character_id=c.id THEN 'primary'
                              WHEN r.secondary_character_id=c.id THEN 'secondary' ELSE NULL END)
          ORDER BY sel.quarter, c.key, t.code), '[]'::jsonb)
        FROM bp_selections sel
        JOIN bp_characters c ON c.id=sel.character_id
        JOIN bp_teams t ON t.id=sel.team_id
        LEFT JOIN bp_requests r ON r.session_id=sel.session_id AND r.team_id=sel.team_id AND r.quarter=sel.quarter
        WHERE sel.session_id=a.session_id),
      'stakeholder_all', (SELECT COALESCE(jsonb_agg(jsonb_build_object('team_id', t.id, 'code', t.code, 'name', t.name,
            'pre',  (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='pre'  LIMIT 1),
            'post', (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='post' LIMIT 1))
          ORDER BY t.code), '[]'::jsonb)
        FROM bp_teams t WHERE t.session_id=a.session_id),
      -- Mandate (migration 011). All teams' directives this quarter incl.
      -- alignment (the Voice re-issue lever reads this), and per-team whether
      -- a stance has been submitted yet.
      'directives', (SELECT jsonb_agg(jsonb_build_object(
                         'team_id',team_id,'directive_text',directive_text,
                         'intended_benefit',intended_benefit,'alignment',alignment))
                       FROM bp_directives WHERE session_id=a.session_id AND quarter=s.current_quarter),
      'mandate_status', (SELECT jsonb_agg(jsonb_build_object(
                         'team_id', t.id,
                         'submitted', EXISTS(SELECT 1 FROM bp_mandate_decisions md
                             WHERE md.session_id=a.session_id AND md.team_id=t.id AND md.quarter=s.current_quarter))
                         ORDER BY t.code)
                       FROM bp_teams t WHERE t.session_id=a.session_id));
  END IF;

  RETURN out;
END $$;

