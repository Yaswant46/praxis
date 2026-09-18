-- =====================================================================
--  015 · Borrowed People — Q1 is the squeeze
--
--  Working characters get ONE slot in Q1 (was 2), 2 in Q2–Q4. Sponsor
--  unchanged (1/1/1/2). Ten asks meet five slots in Q1, so Q1 misses feed
--  the adaptive demand map from Q2 instead of every team entering Q2
--  "on track". Only bp_create_session changes; it is reproduced in full
--  from supabase/borrowed_schema.sql. Existing sessions are untouched
--  (use the Capacity tab to change a live one).
--
--  Applied by hand in the Supabase SQL Editor. Idempotent — safe to re-run.
-- =====================================================================

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
  -- SHORT: 3 playable (Arjun, Neha, Farida) + Sponsor; demand map only needs these four.
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
  -- Mandate directives (migration 011). objective_key | quarter | alignment |
  -- directive_text | intended_benefit. Same 20 for both variants — teams and
  -- their objectives are identical across variants. objective_key → team via
  -- bp_teams.objective_key at insert time.
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
  -- Headwind default calibrated to 3500 (migration 012): solid play (2 exceeded +
  -- 3 delivered) clears the ~14,200 floor; adjust per session as needed.
  INSERT INTO bp_headwind(session_id, value) VALUES (v_sid, 3500);

  -- Objectives + teams
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
    -- CAPACITY IS THE CALIBRATION KNOB: loosen if the org floor becomes unhittable.
    -- Q1 IS THE SQUEEZE (migration 015): every working character has ONE slot,
    -- so 10 asks meet 5 slots and half the room misses its primary in the
    -- first quarter. Those misses seed the adaptive demand map (behind /
    -- at_risk from Q2) — Q1 produces real output instead of a warm-up.
    -- Q2–Q4: 2 slots; competition comes from the demand-map CLUSTERS (Farida
    -- wanted by 3 in Q2, Raghav by 3 in Q3, Sponsor/Neha by 3 in Q4) hitting
    -- the 2-slot ceiling — one team misses at each cluster.
    -- Sponsor: scarce (1) in Q1–Q3; 2 in Q4 where 3 teams need escalation, so
    -- the Q4 crunch stays contested (3-into-2) but the org floor stays reachable.
    -- Facilitator can override any cell live from the Capacity tab.
    FOR q IN 1..4 LOOP
      INSERT INTO bp_character_capacity(session_id, character_id, quarter, slots)
        VALUES (v_sid, v_char_id, q,
          CASE WHEN chars[i][1]='sponsor' THEN (CASE WHEN q=4 THEN 2 ELSE 1 END)
               WHEN q=1 THEN 1
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

  -- Mandate directives (migration 011) — one per (team, quarter). Map the
  -- directive's objective_key to the team via bp_teams.objective_key. Same 20
  -- for both variants (teams are identical across variants).
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

  -- Return codes for handout.
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
