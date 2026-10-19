-- =============================================================================
-- Physio grade ladder (fixed slots 1→5) + TIG refund/reprice
--
-- Slot 1 Trainee              0.20%   ₿500k
-- Slot 2 Physiotherapist      0.35%   ₿750k
-- Slot 3 Senior               0.60%   ₿1.25m
-- Slot 4 Advanced             1.00%   ₿2m
-- Slot 5 Consultant           2.00%   ₿4m
-- Full stack: −4.15 pp for ₿8.5m. Must hire in order.
--
-- TIG: refund 2×₿3m, keep Alice/Steven on slots 1–2, charge ₿500k+₿750k.
-- MAR doctor untouched.
--
-- Safe re-run (TIG migration is idempotent via ledger note key).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.medical_physio_grade_title(p_slot int)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_slot
    WHEN 1 THEN 'Trainee physiotherapist'
    WHEN 2 THEN 'Physiotherapist'
    WHEN 3 THEN 'Senior physiotherapist'
    WHEN 4 THEN 'Advanced physiotherapist'
    WHEN 5 THEN 'Consultant physiotherapist'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.medical_physio_grade_effect(p_slot int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  -- Absolute chance reduction (0.002 = 0.20 percentage points)
  SELECT CASE p_slot
    WHEN 1 THEN 0.0020::numeric
    WHEN 2 THEN 0.0035::numeric
    WHEN 3 THEN 0.0060::numeric
    WHEN 4 THEN 0.0100::numeric
    WHEN 5 THEN 0.0200::numeric
    ELSE 0::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.medical_physio_hire_cost(p_slot int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_slot
    WHEN 1 THEN 500000::numeric
    WHEN 2 THEN 750000::numeric
    WHEN 3 THEN 1250000::numeric
    WHEN 4 THEN 2000000::numeric
    WHEN 5 THEN 4000000::numeric
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.medical_injury_chance_reduction(p_club text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(sum(public.medical_physio_grade_effect(s.slot_index)), 0)::numeric
  FROM public.club_medical_staff s
  WHERE s.club_short_name = nullif(btrim(p_club), '')
    AND s.role = 'physio'
    AND s.seasons_remaining > 0
    AND s.slot_index BETWEEN 1 AND 5;
$$;

CREATE OR REPLACE FUNCTION public.medical_hire_physio(p_slot integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_gender text := CASE WHEN random() < 0.5 THEN 'male' ELSE 'female' END;
  v_name text;
  v_title text;
  v_effect numeric;
  v_cost numeric;
  v_balance numeric;
  v_season bigint;
  v_id bigint;
  v_filled int;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;
  IF p_slot IS NULL OR p_slot < 1 OR p_slot > 5 THEN
    RAISE EXCEPTION 'Physio slot must be 1–5';
  END IF;

  v_title := public.medical_physio_grade_title(p_slot);
  v_effect := public.medical_physio_grade_effect(p_slot);
  v_cost := public.medical_physio_hire_cost(p_slot);
  IF v_title IS NULL OR v_cost IS NULL THEN
    RAISE EXCEPTION 'Invalid physio grade slot';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_medical_staff
    WHERE club_short_name = v_club AND role = 'physio' AND slot_index = p_slot
  ) THEN
    RAISE EXCEPTION 'That physio grade is already filled';
  END IF;

  -- Fixed ladder: slot N only after slots 1..N-1 are filled
  IF p_slot > 1 THEN
    SELECT count(*)::int INTO v_filled
    FROM public.club_medical_staff
    WHERE club_short_name = v_club
      AND role = 'physio'
      AND slot_index BETWEEN 1 AND (p_slot - 1);

    IF v_filled < (p_slot - 1) THEN
      RAISE EXCEPTION
        'Hire the previous physio grade first (slot %)',
        p_slot - 1;
    END IF;
  END IF;

  IF to_regprocedure('public.medical_staff_random_name(text)') IS NOT NULL THEN
    v_name := public.medical_staff_random_name(v_gender);
  ELSE
    v_name := v_title;
  END IF;

  PERFORM public.medical_ensure_centre(v_club);

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF NOT FOUND OR v_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  PERFORM public.post_club_ledger(
    v_club,
    'medical_physio_hire',
    -v_cost,
    format('Medical Room — %s (grade %s)', v_title, p_slot),
    jsonb_build_object(
      'slot', p_slot,
      'grade', p_slot,
      'title', v_title,
      'effect', v_effect,
      'gender', v_gender
    ),
    v_season,
    NULL,
    false,
    true
  );

  INSERT INTO public.club_medical_staff (
    club_short_name, role, gender, display_name, slot_index,
    seasons_remaining, hired_season_id, hire_cost
  )
  VALUES (
    v_club, 'physio', v_gender, v_name,
    p_slot, 3, v_season, v_cost
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'staff_id', v_id,
    'slot', p_slot,
    'grade', p_slot,
    'title', v_title,
    'effect_pct', round(v_effect * 100, 2),
    'display_name', v_name,
    'gender', v_gender,
    'cost', v_cost,
    'physio_count', public.medical_club_physio_count(v_club),
    'injury_chance_reduction_pct',
      round(public.medical_injury_chance_reduction(v_club) * 100, 2)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_hire_physio(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_physio_grade_title(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_physio_grade_effect(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_physio_hire_cost(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_injury_chance_reduction(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.medical_room_state(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club), '');
  v_centre public.club_medical_centre;
  v_doctor jsonb;
  v_physios jsonb;
  v_injuries jsonb;
  v_balance numeric;
  v_physio_n int;
  v_reduction numeric;
  v_next_slot int;
  v_grades jsonb;
BEGIN
  IF v_club IS NULL THEN
    v_club := public.my_club_shortname();
  END IF;
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No club');
  END IF;
  IF v_club IS DISTINCT FROM public.my_club_shortname()
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  v_centre := public.medical_ensure_centre(v_club);
  v_physio_n := public.medical_club_physio_count(v_club);
  v_reduction := public.medical_injury_chance_reduction(v_club);

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  SELECT to_jsonb(s) INTO v_doctor
  FROM public.club_medical_staff s
  WHERE s.club_short_name = v_club AND s.role = 'doctor'
  LIMIT 1;

  SELECT coalesce(
    jsonb_agg(
      to_jsonb(s)
        || jsonb_build_object(
          'grade', s.slot_index,
          'title', public.medical_physio_grade_title(s.slot_index),
          'effect_pct', round(public.medical_physio_grade_effect(s.slot_index) * 100, 2)
        )
      ORDER BY s.slot_index
    ),
    '[]'::jsonb
  )
  INTO v_physios
  FROM public.club_medical_staff s
  WHERE s.club_short_name = v_club AND s.role = 'physio';

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'injury_id', i.id,
      'player_id', i.player_id,
      'player_name', p."Name",
      'label', i.label,
      'severity', i.severity,
      'matches_out_remaining', coalesce(i.matches_out_remaining, 0),
      'recovery_remaining', coalesce(i.recovery_remaining, 0),
      'token_used', EXISTS (
        SELECT 1 FROM public.club_medical_token_use u WHERE u.injury_id = i.id
      )
    )
    ORDER BY i.id
  ), '[]'::jsonb)
  INTO v_injuries
  FROM public.competition_player_injuries i
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
  WHERE i.club_short_name = v_club
    AND i.status = 'active'
    AND (
      coalesce(i.matches_out_remaining, 0) > 0
      OR coalesce(i.recovery_remaining, 0) > 0
    );

  v_next_slot := CASE
    WHEN v_physio_n >= 5 THEN NULL
    ELSE v_physio_n + 1
  END;

  SELECT jsonb_agg(
    jsonb_build_object(
      'slot', g.slot,
      'grade', g.slot,
      'title', public.medical_physio_grade_title(g.slot),
      'effect_pct', round(public.medical_physio_grade_effect(g.slot) * 100, 2),
      'hire_cost', public.medical_physio_hire_cost(g.slot),
      'filled', EXISTS (
        SELECT 1 FROM public.club_medical_staff s
        WHERE s.club_short_name = v_club
          AND s.role = 'physio'
          AND s.slot_index = g.slot
      ),
      'hireable', (v_next_slot IS NOT NULL AND g.slot = v_next_slot)
    )
    ORDER BY g.slot
  )
  INTO v_grades
  FROM (SELECT generate_series(1, 5) AS slot) g;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'balance', coalesce(v_balance, 0),
    'specialist_tokens', v_centre.specialist_tokens,
    'physio_count', v_physio_n,
    'injury_chance_reduction_pct', round(v_reduction * 100, 2),
    'has_doctor', public.medical_club_has_doctor(v_club),
    'doctor', v_doctor,
    'doctor_hire_cost', public.medical_doctor_hire_cost(),
    'physio_hire_costs', jsonb_build_object(
      '1', public.medical_physio_hire_cost(1),
      '2', public.medical_physio_hire_cost(2),
      '3', public.medical_physio_hire_cost(3),
      '4', public.medical_physio_hire_cost(4),
      '5', public.medical_physio_hire_cost(5)
    ),
    'physio_grades', coalesce(v_grades, '[]'::jsonb),
    'next_physio_slot', v_next_slot,
    'physios', coalesce(v_physios, '[]'::jsonb),
    'active_injuries', coalesce(v_injuries, '[]'::jsonb),
    'specialist_matches_removed', 2,
    'doctor_matches_off', 1,
    'physio_bonus_each_pct', NULL,
    'max_physios', 5,
    'max_specialist_tokens', 20,
    'contract_seasons', 3,
    'physio_ladder', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_room_state(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- TIG migration: refund old ₿3m×2, charge grade 1+2, keep names
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_season bigint;
  v_rows int;
  v_already boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = 'TIG'
      AND l.entry_type = 'medical_physio_hire'
      AND l.description = 'Medical Room — physio grade ladder reprice (refund ×2 @ ₿3m)'
  ) INTO v_already;

  IF v_already THEN
    RAISE NOTICE 'TIG physio ladder migration already applied — skip';
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_rows
  FROM public.club_medical_staff
  WHERE club_short_name = 'TIG'
    AND role = 'physio'
    AND slot_index IN (1, 2);

  IF v_rows <> 2 THEN
    RAISE NOTICE 'TIG does not have exactly two physios (found %) — skip migration', v_rows;
    RETURN;
  END IF;

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  -- Refund both old hires
  PERFORM public.post_club_ledger(
    'TIG',
    'medical_physio_hire',
    6000000,
    'Medical Room — physio grade ladder reprice (refund ×2 @ ₿3m)',
    jsonb_build_object('migration', 'physio_grade_ladder_20261019', 'refund', 6000000),
    v_season,
    NULL,
    false,
    true
  );

  -- Charge new grade costs
  PERFORM public.post_club_ledger(
    'TIG',
    'medical_physio_hire',
    -500000,
    'Medical Room — Trainee physiotherapist (grade 1) reprice',
    jsonb_build_object('migration', 'physio_grade_ladder_20261019', 'slot', 1, 'title', 'Trainee physiotherapist'),
    v_season,
    NULL,
    false,
    true
  );

  PERFORM public.post_club_ledger(
    'TIG',
    'medical_physio_hire',
    -750000,
    'Medical Room — Physiotherapist (grade 2) reprice',
    jsonb_build_object('migration', 'physio_grade_ladder_20261019', 'slot', 2, 'title', 'Physiotherapist'),
    v_season,
    NULL,
    false,
    true
  );

  UPDATE public.club_medical_staff
  SET hire_cost = public.medical_physio_hire_cost(slot_index)
  WHERE club_short_name = 'TIG'
    AND role = 'physio'
    AND slot_index IN (1, 2);

  RAISE NOTICE 'TIG physio ladder migration done — net +₿4.75m, slots 1–2 repriced';
END;
$$;

NOTIFY pgrst, 'reload schema';
