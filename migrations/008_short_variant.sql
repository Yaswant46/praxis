-- =====================================================================
--  008 · Borrowed People — Short Version (a session variant)
--
--  Same engine, same five objectives / couplings / ₹14,200 target / org
--  story — but a smaller room:
--    • 3 playable characters (Arjun, Neha, Farida) + the Sponsor (the
--      facilitator), instead of 5 + Sponsor.
--    • A reduced demand map that only ever needs those three (plus the
--      Sponsor in Q4), re-pointing every Raghav / Devika reference.
--    • No observers (the app hides the observer log + observed column when
--      the session is 'short').
--  Intended headcount: 15 players on 5 teams of 3, + 3 on characters.
--
--  bp_create_session gains an optional p_variant ('full' | 'short'); old
--  one-arg callers keep the full game. Idempotent.
-- =====================================================================

ALTER TABLE bp_sessions ADD COLUMN IF NOT EXISTS variant TEXT NOT NULL DEFAULT 'full';

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
    ARRAY['sponsor','Sponsor','COO — facilitator plays this']];
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
    ARRAY['sponsor','Sponsor','COO — facilitator plays this']];
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
    FOR q IN 1..4 LOOP
      INSERT INTO bp_character_capacity(session_id, character_id, quarter, slots)
        VALUES (v_sid, v_char_id, q,
          CASE WHEN chars[i][1]='sponsor' THEN 1
               WHEN q=3 THEN 1 ELSE 2 END);
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
