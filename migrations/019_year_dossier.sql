-- =====================================================================
--  019 · Borrowed People — year dossier for the Year's summary
--
--  New facilitator-gated read (bp_year_dossier) used by the bp-year edge
--  function to write "The Meridian — the year" once Q4 has reached
--  RESULTS. Additive: no existing function or table changes. The summary
--  itself is published through bp_publish_story with quarter = 5.
--
--  Applied to the live DB 2026-09-18. Idempotent — safe to re-run.
-- =====================================================================

-- =====================================================================
--  YEAR DOSSIER (migration 019) — everything the year's summary is written
--  from, in one facilitator-gated read. Per quarter and team: result band,
--  who they asked for, the adjusted ideal, both Style Calls (lead + runner)
--  with rationale, the observed style, the Sponsor's directive and the
--  team's mandate, and every character who gave them time — with the
--  character's own reason and the rating they then gave. Plus Q4
--  judgements, commitments, stakeholder shift, and the final boards.
--  Only readable once Q4 has reached RESULTS (or the session is closed).
--  Read by the bp-year edge function; never exposed to teams or characters.
-- =====================================================================
CREATE OR REPLACE FUNCTION bp_year_dossier(p_session_code TEXT, p_access_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD; hw INT;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF NOT (s.status='closed' OR (s.current_quarter >= 4 AND s.current_phase IN ('RESULTS','DEBRIEF'))) THEN
    RAISE EXCEPTION 'year_not_over';
  END IF;
  SELECT value INTO hw FROM bp_headwind WHERE session_id=a.session_id;

  RETURN jsonb_build_object(
    'session', jsonb_build_object('name', s.name, 'variant', s.variant, 'target_value', s.target_value,
                                  'headwind', hw, 'headwind_revealed', s.headwind_revealed),
    'boards', bp_boards(a.session_id),
    'teams', (SELECT jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'objective', t.objective_key,
                'objective_label', o.label, 'objective_description', o.description) ORDER BY t.code)
              FROM bp_teams t LEFT JOIN bp_objectives o ON o.session_id=t.session_id AND o.key=t.objective_key
              WHERE t.session_id=a.session_id),
    'characters', (SELECT jsonb_agg(jsonb_build_object('key', key, 'name', name, 'role', role_label) ORDER BY key)
                   FROM bp_characters WHERE session_id=a.session_id),
    'quarters', (SELECT jsonb_agg(jsonb_build_object(
        'quarter', g.q,
        'curveballs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', cb.label, 'body', cb.body)), '[]'::jsonb)
                       FROM bp_curveballs cb WHERE cb.session_id=a.session_id AND cb.quarter=g.q AND cb.triggered_at IS NOT NULL),
        'teams', (SELECT jsonb_agg(jsonb_build_object(
            'team', t.code,
            'result', (SELECT jsonb_build_object('band', band, 'points', points, 'avg_rating', avg_rating,
                                                 'got_primary', got_primary, 'got_secondary', got_secondary)
                       FROM bp_quarter_results r WHERE r.session_id=a.session_id AND r.team_id=t.id AND r.quarter=g.q),
            'requested', (SELECT jsonb_build_object('primary', pc.name, 'secondary', sc.name)
                          FROM bp_requests r
                          LEFT JOIN bp_characters pc ON pc.id=r.primary_character_id
                          LEFT JOIN bp_characters sc ON sc.id=r.secondary_character_id
                          WHERE r.session_id=a.session_id AND r.team_id=t.id AND r.quarter=g.q),
            'ideal', (SELECT jsonb_build_object('primary', os.primary_key, 'secondary', os.secondary_key,
                                                'state', os.state, 'business_reason', os.business_reason)
                      FROM bp_objective_state os
                      WHERE os.session_id=a.session_id AND os.objective_key=t.objective_key AND os.quarter=g.q),
            'style_calls', (SELECT jsonb_object_agg(seat, jsonb_build_object('style', style, 'rationale', rationale))
                            FROM bp_style_calls sc WHERE sc.session_id=a.session_id AND sc.team_id=t.id AND sc.quarter=g.q),
            'observed', (SELECT jsonb_build_object('style', observed_style, 'note', note)
                         FROM bp_observer_logs ol WHERE ol.session_id=a.session_id AND ol.team_id=t.id AND ol.quarter=g.q),
            'directive', (SELECT jsonb_build_object('text', directive_text, 'intended_benefit', intended_benefit, 'alignment', alignment)
                          FROM bp_directives d WHERE d.session_id=a.session_id AND d.team_id=t.id AND d.quarter=g.q),
            'mandate', (SELECT jsonb_build_object('stance', md.stance, 'dissent_line', md.dissent_line,
                          'leadership_cell', bp_leadership_cell(md.stance,
                             (SELECT alignment FROM bp_directives d WHERE d.session_id=a.session_id AND d.team_id=t.id AND d.quarter=g.q)))
                        FROM bp_mandate_decisions md WHERE md.session_id=a.session_id AND md.team_id=t.id AND md.quarter=g.q),
            'backed_by', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'character', c.name, 'reason', sel.reason,
                            'requested_as', CASE WHEN r.primary_character_id=c.id THEN 'primary'
                                                 WHEN r.secondary_character_id=c.id THEN 'secondary' ELSE NULL END,
                            'rating', (SELECT jsonb_build_object('knew_what_i_cared_about', knew_what_i_cared_about,
                                                                 'asked_or_told', asked_or_told, 'left_me_better', left_me_better)
                                       FROM bp_ratings rt WHERE rt.session_id=a.session_id AND rt.character_id=c.id
                                         AND rt.team_id=t.id AND rt.quarter=g.q)) ORDER BY c.key), '[]'::jsonb)
                          FROM bp_selections sel
                          JOIN bp_characters c ON c.id=sel.character_id
                          LEFT JOIN bp_requests r ON r.session_id=sel.session_id AND r.team_id=sel.team_id AND r.quarter=sel.quarter
                          WHERE sel.session_id=a.session_id AND sel.team_id=t.id AND sel.quarter=g.q)
          ) ORDER BY t.code) FROM bp_teams t WHERE t.session_id=a.session_id)
      ) ORDER BY g.q) FROM generate_series(1,4) AS g(q)),
    'judgements', (SELECT COALESCE(jsonb_agg(jsonb_build_object('character', c.name, 'team', t.code,
                       'work_with_again', j.again, 'reason', j.reason) ORDER BY c.key, t.code), '[]'::jsonb)
                   FROM bp_judgements j JOIN bp_characters c ON c.id=j.character_id JOIN bp_teams t ON t.id=j.team_id
                   WHERE j.session_id=a.session_id),
    'commitments', (SELECT COALESCE(jsonb_agg(jsonb_build_object('quarter', cm.quarter, 'from', tf.code, 'to', tt.code,
                        'text', cm.text, 'confirmed', cm.confirmed_by_to,
                        'honoured_from', cm.honoured_from, 'honoured_to', cm.honoured_to) ORDER BY cm.created_at), '[]'::jsonb)
                    FROM bp_commitments cm JOIN bp_teams tf ON tf.id=cm.from_team_id JOIN bp_teams tt ON tt.id=cm.to_team_id
                    WHERE cm.session_id=a.session_id),
    'stakeholder_shift', (SELECT COALESCE(jsonb_agg(jsonb_build_object('team', t.code,
                            'pre',  (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='pre'  LIMIT 1),
                            'post', (SELECT payload FROM bp_stakeholder_maps m WHERE m.session_id=a.session_id AND m.team_id=t.id AND m.phase='post' LIMIT 1)) ORDER BY t.code), '[]'::jsonb)
                          FROM bp_teams t WHERE t.session_id=a.session_id)
  );
END $$;
GRANT EXECUTE ON FUNCTION bp_year_dossier(text,text) TO anon, authenticated;
