-- =====================================================================
--  011 · Borrowed People — Mandate mechanic (compliance vs courage)
--
--  A third leadership axis on top of the business (demand-map) and EI
--  (ratings) axes. Each quarter the Sponsor hands every team a DIRECTIVE.
--  Some directives are business-'sound' (they agree with the adaptive
--  demand-map ideal); some are in 'tension' with it (they'd steer the team
--  the wrong way). Each team must take a STANCE — comply, voice, or defy —
--  and, if they voice or defy, write a dissent line. At DEBRIEF the stance
--  crossed with the directive's alignment resolves to a LEADERSHIP CELL:
--
--            | sound              | tension
--    --------+--------------------+---------------------
--    comply  | trust well-placed  | silent compliance
--    voice   | reconciled         | the leadership move
--    defy    | parochial overreach| principled dissent
--
--  This is surfaced ONLY in bp_state's mandate_reveal. It does NOT touch the
--  scoring engine — business/EI band logic stays exactly as in migration 010.
--
--  Data model: bp_directives + bp_mandate_decisions, both deny-all spoiler
--  tables reached only via SECURITY DEFINER RPCs. Client entry points
--  (bp_submit_mandate, bp_set_directive) get EXECUTE for anon/authenticated,
--  matching the other bp_ RPCs.
--
--  This migration additively creates the two tables + the leadership_cell
--  helper + the two RPCs, and CREATE OR REPLACEs bp_create_session (to seed
--  the 20 directives), bp_state (to add my_directive / my_mandate /
--  directives / mandate_status / mandate_reveal) and bp_selftest (to add the
--  leadership-cell check). The reproduced bp_create_session / bp_state /
--  bp_selftest bodies are the current (post-009 / post-010) versions with
--  only the documented mandate insertions.
--
--  Applied by hand in the Supabase SQL Editor. Idempotent — safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. Tables — deny-all spoiler tables like bp_demand_map.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bp_directives (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id       UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id          UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter          INT  NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  directive_text   TEXT NOT NULL,
  intended_benefit TEXT,
  alignment        TEXT NOT NULL CHECK (alignment IN ('sound','tension')),
  issued_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, team_id, quarter)
);

CREATE TABLE IF NOT EXISTS bp_mandate_decisions (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  session_id    UUID REFERENCES bp_sessions(id) ON DELETE CASCADE,
  team_id       UUID REFERENCES bp_teams(id) ON DELETE CASCADE,
  quarter       INT  NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  stance        TEXT NOT NULL CHECK (stance IN ('comply','voice','defy')),
  dissent_line  TEXT,
  submitted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (session_id, team_id, quarter)
);

ALTER TABLE bp_directives         ENABLE ROW LEVEL SECURITY;
ALTER TABLE bp_mandate_decisions  ENABLE ROW LEVEL SECURITY;
-- No permissive anon policy → deny-all. Reached only via definer RPCs.
REVOKE ALL ON bp_directives        FROM anon, authenticated;
REVOKE ALL ON bp_mandate_decisions FROM anon, authenticated;

-- ---------------------------------------------------------------------
--  2. Leadership-cell helper — pure logic, no session data. Maps a team's
--     stance × the directive's alignment to the leadership cell. Internal
--     (called only from bp_state / bp_selftest); stays ungranted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_leadership_cell(p_stance TEXT, p_alignment TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_stance IS NULL THEN 'no decision'
    WHEN p_stance='comply' AND p_alignment='sound'   THEN 'trust well-placed'
    WHEN p_stance='comply' AND p_alignment='tension' THEN 'silent compliance'
    WHEN p_stance='voice'  AND p_alignment='sound'   THEN 'reconciled'
    WHEN p_stance='voice'  AND p_alignment='tension' THEN 'the leadership move'
    WHEN p_stance='defy'   AND p_alignment='sound'   THEN 'parochial overreach'
    WHEN p_stance='defy'   AND p_alignment='tension' THEN 'principled dissent'
    ELSE 'no decision' END;
$$;

-- ---------------------------------------------------------------------
--  3. bp_create_session — reproduced from the post-009 schema with ONE
--     addition: a directives[] table and a seed loop that maps each
--     directive's objective_key → team via bp_teams and inserts into
--     bp_directives. Same 20 directives for both variants (teams and their
--     objectives are identical across variants). Nothing else changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_create_session(p_name TEXT, p_variant TEXT DEFAULT 'full')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sid UUID;
  v_fac TEXT;
  r RECORD;
  v_variant TEXT := CASE WHEN lower(COALESCE(p_variant,'full'))='short' THEN 'short' ELSE 'full' END;
  v_team_codes JSONB := '{}'::jsonb;
  v_char_codes JSONB := '{}'::jsonb;
  -- objective → team code, name  (SAME for both variants)
  objs TEXT[][] := ARRAY[
    ARRAY['battery','A','Battery','Cell cost, energy density, and thermal safety.'],
    ARRAY['suppliers','B','Suppliers','Second-source the critical bill of materials.'],
    ARRAY['spec','C','Spec','Lock the product specification without gold-plating.'],
    ARRAY['warranty','D','Warranty','Contain field-failure exposure and warranty reserve.'],
    ARRAY['pricing','E','Pricing','Hold margin against a price-led market.']];
  team_names TEXT[] := ARRAY['Ampere','Bastion','Crucible','Dynamo','Envoy'];

  -- FULL: 5 playable + Sponsor
  chars_full TEXT[][] := ARRAY[
    ARRAY['arjun','Arjun','Design lead'],
    ARRAY['neha','Neha','Supply chain — 14 months in'],
    ARRAY['raghav','Raghav','Manufacturing — 19 years'],
    ARRAY['farida','Farida','Quality'],
    ARRAY['devika','Devika','Regional Sales Head'],
    ARRAY['sponsor','Sponsor','Sponsor — facilitator plays this']];
  dmap_full TEXT[][] := ARRAY[
    ARRAY['battery',  'arjun','neha',  'neha','farida', 'farida','raghav', 'arjun','neha'],
    ARRAY['suppliers','neha','raghav', 'neha','raghav', 'raghav','neha',   'sponsor','neha'],
    ARRAY['spec',     'arjun','devika','farida','devika','arjun','devika', 'sponsor','farida'],
    ARRAY['warranty', 'farida','raghav','raghav','farida','neha','raghav', 'farida','neha'],
    ARRAY['pricing',  'devika','farida','devika','arjun', 'devika','farida','sponsor','devika']];

  -- SHORT: 3 playable (Arjun, Neha, Farida) + Sponsor. Demand map uses only
  -- these four; scarcity across 5 teams and the Q3 squeeze are preserved.
  chars_short TEXT[][] := ARRAY[
    ARRAY['arjun','Arjun','Design lead'],
    ARRAY['neha','Neha','Supply chain — 14 months in'],
    ARRAY['farida','Farida','Quality'],
    ARRAY['sponsor','Sponsor','Sponsor — facilitator plays this']];
  dmap_short TEXT[][] := ARRAY[
    ARRAY['battery',  'arjun','neha',   'neha','farida',  'farida','arjun', 'arjun','neha'],
    ARRAY['suppliers','neha','farida',  'neha','arjun',   'arjun','neha',   'sponsor','neha'],
    ARRAY['spec',     'arjun','farida', 'farida','arjun', 'arjun','farida', 'sponsor','farida'],
    ARRAY['warranty', 'farida','neha',  'neha','farida',  'neha','farida',  'farida','neha'],
    ARRAY['pricing',  'farida','arjun', 'arjun','farida', 'farida','neha',  'sponsor','farida']];

  chars TEXT[][];
  dmap  TEXT[][];
  i INT; q INT;
  v_char_id UUID;
  -- Mandate directives (this migration). objective_key | quarter | alignment |
  -- directive_text | intended_benefit. Same 20 for both variants.
  directives TEXT[][] := ARRAY[
    ARRAY['battery','1','sound',$q$Nail the cell architecture first — get Arjun's design lock before anything moves.$q$,$q$A stable platform the whole programme builds on.$q$],
    ARRAY['suppliers','1','sound',$q$Put Neha on second-sourcing the critical BOM now.$q$,$q$De-risk the supply base before volumes ramp.$q$],
    ARRAY['spec','1','sound',$q$Work with Arjun to define the spec envelope.$q$,$q$A clear, buildable spec — no ambiguity downstream.$q$],
    ARRAY['warranty','1','sound',$q$Get Farida to set the quality gates and reserve model early.$q$,$q$Contain field-failure exposure before it compounds.$q$],
    ARRAY['pricing','1','sound',$q$Get Devika's market read and set the pricing corridor.$q$,$q$Hold margin against price-led competitors.$q$],
    ARRAY['battery','2','sound',$q$Cell prices are moving — get Neha to lock second-source cells before the squeeze hits battery.$q$,$q$Secure supply before margin erodes.$q$],
    ARRAY['suppliers','2','tension',$q$Neha's still new; bring Raghav's weight to the supplier table for harder terms.$q$,$q$Better commercial terms from a veteran.$q$],
    ARRAY['spec','2','sound',$q$Bring Farida in to pressure-test the spec against field reality.$q$,$q$A spec that survives contact with customers.$q$],
    ARRAY['warranty','2','sound',$q$Most warranty risk is born on the line — bring Raghav in.$q$,$q$Build quality in, don't inspect it in.$q$],
    ARRAY['pricing','2','tension',$q$Work with Arjun to strip design cost so we can fund a lower price.$q$,$q$Win share on price.$q$],
    ARRAY['battery','3','tension',$q$Board wants energy-density gains — push Arjun for the next design iteration.$q$,$q$A headline spec bump for the launch story.$q$],
    ARRAY['suppliers','3','sound',$q$Bring Raghav in to lock manufacturing-side supplier commitments.$q$,$q$Production-ready supply.$q$],
    ARRAY['spec','3','tension',$q$Spec's set — hand it to Raghav for manufacturability and stop iterating.$q$,$q$Protect the timeline; no gold-plating.$q$],
    ARRAY['warranty','3','tension',$q$Double down with Farida on pre-launch testing.$q$,$q$Catch failures before customers do.$q$],
    ARRAY['pricing','3','sound',$q$Stay with Devika and defend the price in-market.$q$,$q$Protect the margin line.$q$],
    ARRAY['battery','4','sound',$q$Back to Arjun — close the design for production freeze.$q$,$q$A clean freeze for launch.$q$],
    ARRAY['suppliers','4','sound',$q$This one's above your level — escalate the second-source sign-off to me.$q$,$q$I can clear the cross-functional logjam.$q$],
    ARRAY['spec','4','sound',$q$Bring the final spec trade-offs to me for sign-off.$q$,$q$A decision that sticks.$q$],
    ARRAY['warranty','4','sound',$q$Back to Farida to close out the warranty reserve.$q$,$q$A defensible number for the board.$q$],
    ARRAY['pricing','4','tension',$q$You've got this — hold price and close it yourself, no need to escalate.$q$,$q$Show the board pricing is under control.$q$]];
  v_team_id UUID;
BEGIN
  IF v_variant='short' THEN chars := chars_short; dmap := dmap_short;
  ELSE                     chars := chars_full;  dmap := dmap_full;  END IF;

  v_fac := bp_gencode('FAC');
  INSERT INTO bp_sessions(name, facilitator_code, variant) VALUES (p_name, v_fac, v_variant) RETURNING id INTO v_sid;
  INSERT INTO bp_headwind(session_id, value) VALUES (v_sid, 6000);

  -- Objectives + teams (same 5 for both variants)
  FOR i IN 1..array_length(objs,1) LOOP
    INSERT INTO bp_objectives(session_id, key, label, description)
      VALUES (v_sid, objs[i][1], objs[i][3], objs[i][4]);
    INSERT INTO bp_teams(session_id, code, name, objective_key, access_code)
      VALUES (v_sid, objs[i][2], team_names[i], objs[i][1], bp_gencode('TEAM'||objs[i][2]));
  END LOOP;

  -- Characters
  FOR i IN 1..array_length(chars,1) LOOP
    INSERT INTO bp_characters(session_id, key, name, role_label, access_code)
      VALUES (v_sid, chars[i][1], chars[i][2], chars[i][3], bp_gencode('CHR'))
      RETURNING id INTO v_char_id;
    -- CAPACITY IS THE CALIBRATION KNOB (migration 009): working chars 2 slots
    -- every quarter; Sponsor scarce (1) in Q1–Q3, 2 in Q4.
    FOR q IN 1..4 LOOP
      INSERT INTO bp_character_capacity(session_id, character_id, quarter, slots)
        VALUES (v_sid, v_char_id, q,
          CASE WHEN chars[i][1]='sponsor' THEN (CASE WHEN q=4 THEN 2 ELSE 1 END)
               ELSE 2 END);
    END LOOP;
  END LOOP;

  -- Demand map (hidden)
  FOR i IN 1..array_length(dmap,1) LOOP
    FOR q IN 1..4 LOOP
      INSERT INTO bp_demand_map(session_id, objective_key, quarter,
                                primary_character_key, secondary_character_key)
        VALUES (v_sid, dmap[i][1], q, dmap[i][2*q], dmap[i][2*q+1]);
    END LOOP;
  END LOOP;

  -- Mandate directives (this migration) — one per (team, quarter). Map the
  -- directive's objective_key to the team via bp_teams.objective_key.
  FOR i IN 1..array_length(directives,1) LOOP
    SELECT id INTO v_team_id FROM bp_teams
      WHERE session_id=v_sid AND objective_key=directives[i][1];
    INSERT INTO bp_directives(session_id, team_id, quarter, directive_text, intended_benefit, alignment)
      VALUES (v_sid, v_team_id, directives[i][2]::int, directives[i][4], directives[i][5], directives[i][3]);
  END LOOP;

  -- Curveballs (seed)
  INSERT INTO bp_curveballs(session_id, key, label, body) VALUES
    (v_sid,'cell_prices','Cell prices +6%','Cell prices are up 6%. Battery hardest hit, Suppliers next.'),
    (v_sid,'quality_escape','Field quality escape','A field quality escape. Puts Warranty and Spec in direct opposition.'),
    (v_sid,'sponsor_praise','Sponsor praise','The Sponsor praises one team by name. (Facilitator picks which.)'),
    (v_sid,'character_pulled','Character pulled','One character is unavailable this quarter. Fired AFTER requests lock.');

  -- Escalation cards (generic per-quarter posture, character_key NULL)
  INSERT INTO bp_escalation_cards(session_id, character_key, quarter, posture, sample_lines) VALUES
    (v_sid,NULL,1,'Polite, vague, non-committal.','"Send me something and I''ll take a look."'),
    (v_sid,NULL,2,'Competing claims, named out loud.','"Team C already asked me for the same week."'),
    (v_sid,NULL,3,'Push back, refuse.','"I''ve heard this before. It died. Why is this different?"'),
    (v_sid,NULL,4,'Judge.','"I''d work with A again. I would not work with B."');

  FOR r IN SELECT code, name, access_code FROM bp_teams WHERE session_id=v_sid ORDER BY code LOOP
    v_team_codes := v_team_codes || jsonb_build_object(r.code, jsonb_build_object('name',r.name,'code',r.access_code));
  END LOOP;
  FOR r IN SELECT key, name, access_code FROM bp_characters WHERE session_id=v_sid ORDER BY key LOOP
    v_char_codes := v_char_codes || jsonb_build_object(r.key, jsonb_build_object('name',r.name,'code',r.access_code));
  END LOOP;

  PERFORM bp_log(v_sid,'facilitator','create_session', jsonb_build_object('name',p_name,'variant',v_variant));

  RETURN jsonb_build_object(
    'session_id', v_sid,
    'variant', v_variant,
    'facilitator_code', v_fac,
    'teams', v_team_codes,
    'characters', v_char_codes);
END $$;

-- ---------------------------------------------------------------------
--  4. bp_submit_mandate — participant only; allowed only while phase index
--     < REQUESTS_LOCKED. voice/defy require a dissent line. Upserts the
--     caller's team + current quarter decision.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_submit_mandate(p_session_code TEXT, p_access_code TEXT,
  p_stance TEXT, p_dissent_line TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; s RECORD;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_access_code);
  IF a.role <> 'participant' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM bp_sessions WHERE id=a.session_id;
  IF bp_phase_index(s.current_phase) >= bp_phase_index('REQUESTS_LOCKED') THEN
    RAISE EXCEPTION 'mandate_locked';
  END IF;
  IF p_stance IN ('voice','defy') AND COALESCE(btrim(p_dissent_line),'') = '' THEN
    RAISE EXCEPTION 'dissent_line_required';
  END IF;
  INSERT INTO bp_mandate_decisions(session_id, team_id, quarter, stance, dissent_line)
    VALUES (a.session_id, a.team_id, s.current_quarter, p_stance, p_dissent_line)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET stance=EXCLUDED.stance, dissent_line=EXCLUDED.dissent_line, submitted_at=NOW();
  PERFORM bp_log(a.session_id,'participant','mandate',
    jsonb_build_object('team',a.team_id,'quarter',s.current_quarter,'stance',p_stance));
  RETURN jsonb_build_object('ok',true);
END $$;

-- ---------------------------------------------------------------------
--  5. bp_set_directive — facilitator only (the Voice re-issue lever).
--     Upserts a team's directive for a quarter.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_set_directive(p_session_code TEXT, p_fac_code TEXT,
  p_team_code TEXT, p_quarter INT, p_text TEXT, p_benefit TEXT, p_alignment TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a RECORD; v_team_id UUID;
BEGIN
  SELECT * INTO a FROM bp_auth(p_session_code, p_fac_code);
  IF a.role <> 'facilitator' THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT id INTO v_team_id FROM bp_teams WHERE session_id=a.session_id AND code=p_team_code;
  IF v_team_id IS NULL THEN RAISE EXCEPTION 'unknown_team'; END IF;
  IF p_alignment NOT IN ('sound','tension') THEN RAISE EXCEPTION 'bad_alignment'; END IF;
  INSERT INTO bp_directives(session_id, team_id, quarter, directive_text, intended_benefit, alignment)
    VALUES (a.session_id, v_team_id, p_quarter, p_text, p_benefit, p_alignment)
    ON CONFLICT (session_id, team_id, quarter) DO UPDATE
      SET directive_text=EXCLUDED.directive_text, intended_benefit=EXCLUDED.intended_benefit,
          alignment=EXCLUDED.alignment, issued_at=NOW();
  PERFORM bp_log(a.session_id,'facilitator','set_directive',
    jsonb_build_object('team',v_team_id,'quarter',p_quarter,'alignment',p_alignment));
  RETURN jsonb_build_object('ok',true);
END $$;

-- ---------------------------------------------------------------------
--  6. bp_state — reproduced from the post-010 schema with the mandate
--     additions: participant my_directive (from BRIEF onward) + my_mandate;
--     facilitator directives + mandate_status; and mandate_reveal (facilitator
--     always, everyone at DEBRIEF). Scoring is untouched — leadership is a
--     third axis surfaced only in mandate_reveal.
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

  -- Mandate reveal (this migration): per-team stance × directive alignment →
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
      -- Mandate (this migration). my_directive is visible from BRIEF onward
      -- (always, if a row exists); alignment is NOT surfaced to the team.
      -- my_mandate is the team's own stance for the current quarter.
      'my_directive', (SELECT jsonb_build_object('text',directive_text,'intended_benefit',intended_benefit)
                       FROM bp_directives WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter),
      'my_mandate', (SELECT jsonb_build_object('stance',stance,'dissent_line',dissent_line)
                       FROM bp_mandate_decisions WHERE session_id=a.session_id AND team_id=a.team_id AND quarter=s.current_quarter));

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
      -- Mandate (this migration). All teams' directives this quarter incl.
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

-- ---------------------------------------------------------------------
--  7. bp_selftest — reproduced from the post-010 schema with one added
--     pure-logic check: comply + tension → 'silent compliance'.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bp_selftest()
RETURNS TABLE (test TEXT, expected TEXT, actual TEXT, pass BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
  r JSONB;
  v_sid UUID; v_obj TEXT; v_state TEXT;
  v_prev_p TEXT; v_adj_p TEXT;
  v_cell TEXT;
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
  v_state := bp_resolve_state('00000000-0000-0000-0000-000000000000'::uuid, 'battery', 1);
  RETURN QUERY SELECT 'resolve_state Q1 = on_track',
    'on_track',
    v_state,
    (v_state = 'on_track');

  -- (010) Adaptive demand map, check (b): 'behind' → prior-quarter base primary.
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

  -- (011) Mandate: comply + tension resolves to 'silent compliance'.
  v_cell := bp_leadership_cell('comply','tension');
  RETURN QUERY SELECT 'leadership_cell comply+tension = silent compliance',
    'silent compliance',
    v_cell,
    (v_cell = 'silent compliance');
END $$;

-- ---------------------------------------------------------------------
--  8. GRANTS — the two client entry points need EXECUTE for anon /
--     authenticated (like the other bp_ RPCs). bp_leadership_cell stays
--     ungranted (internal helper). bp_directives / bp_mandate_decisions
--     stay deny-all (REVOKE above).
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION bp_submit_mandate(text,text,text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION bp_set_directive(text,text,text,int,text,text,text) TO anon, authenticated;

-- bp_create_session / bp_state / bp_selftest keep their existing grants from
-- the base schema (signatures unchanged).
