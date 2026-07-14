-- =============================================================================
-- Medical Room tweaks: €3m physios, €5m doctor, random gender hire, 20 token slots
-- Safe re-run (after club_medical_room.sql).
-- =============================================================================

ALTER TABLE public.club_medical_centre
  DROP CONSTRAINT IF EXISTS club_medical_centre_specialist_tokens_check;
ALTER TABLE public.club_medical_centre
  ADD CONSTRAINT club_medical_centre_specialist_tokens_check
  CHECK (specialist_tokens >= 0 AND specialist_tokens <= 20);

CREATE OR REPLACE FUNCTION public.medical_physio_hire_cost(p_slot int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_slot BETWEEN 1 AND 5 THEN 3000000::numeric
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.medical_doctor_hire_cost()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 5000000::numeric;
$$;

DROP FUNCTION IF EXISTS public.medical_hire_physio(int, text);
CREATE OR REPLACE FUNCTION public.medical_hire_physio(p_slot int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_gender text := CASE WHEN random() < 0.5 THEN 'male' ELSE 'female' END;
  v_cost numeric;
  v_balance numeric;
  v_season bigint;
  v_id bigint;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked to this account'; END IF;
  IF p_slot IS NULL OR p_slot < 1 OR p_slot > 5 THEN
    RAISE EXCEPTION 'Physio slot must be 1–5';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_medical_staff
    WHERE club_short_name = v_club AND role = 'physio' AND slot_index = p_slot
  ) THEN
    RAISE EXCEPTION 'That physio slot is already filled';
  END IF;

  IF public.medical_club_physio_count(v_club) >= 5 THEN
    RAISE EXCEPTION 'Maximum 5 physios';
  END IF;

  v_cost := public.medical_physio_hire_cost(p_slot);
  PERFORM public.medical_ensure_centre(v_club);

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_balance IS NULL THEN RAISE EXCEPTION 'Club finances not found'; END IF;
  -- Medical hires allowed on negative balance (still posts ledger debit)

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  PERFORM public.post_club_ledger(
    v_club,
    'medical_physio_hire',
    -v_cost,
    format('Medical Room — physio hire (slot %s)', p_slot),
    jsonb_build_object('slot', p_slot, 'gender', v_gender),
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
    v_club, 'physio', v_gender, 'Club physiotherapist',
    p_slot, 3, v_season, v_cost
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'staff_id', v_id,
    'slot', p_slot,
    'gender', v_gender,
    'cost', v_cost,
    'physio_count', public.medical_club_physio_count(v_club)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_hire_physio(int) TO authenticated;

DROP FUNCTION IF EXISTS public.medical_hire_doctor(text);
CREATE OR REPLACE FUNCTION public.medical_hire_doctor()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_gender text := CASE WHEN random() < 0.5 THEN 'male' ELSE 'female' END;
  v_cost numeric := public.medical_doctor_hire_cost();
  v_balance numeric;
  v_season bigint;
  v_id bigint;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked to this account'; END IF;

  IF public.medical_club_has_doctor(v_club) THEN
    RAISE EXCEPTION 'Club already has a doctor';
  END IF;

  PERFORM public.medical_ensure_centre(v_club);

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_balance IS NULL THEN RAISE EXCEPTION 'Club finances not found'; END IF;
  -- Medical hires allowed on negative balance (still posts ledger debit)

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  PERFORM public.post_club_ledger(
    v_club,
    'medical_doctor_hire',
    -v_cost,
    'Medical Room — club doctor hire',
    jsonb_build_object('gender', v_gender),
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
    v_club, 'doctor', v_gender, 'Club doctor', NULL, 3, v_season, v_cost
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'staff_id', v_id,
    'gender', v_gender,
    'cost', v_cost
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_hire_doctor() TO authenticated;

CREATE OR REPLACE FUNCTION public.medical_grant_specialist_tokens(
  p_club text,
  p_tokens int DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club), '');
  v_n int := greatest(coalesce(p_tokens, 0), 0);
  v_row public.club_medical_centre;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_club IS NULL THEN RAISE EXCEPTION 'Club required'; END IF;
  IF v_n <= 0 THEN RAISE EXCEPTION 'Token count must be > 0'; END IF;

  v_row := public.medical_ensure_centre(v_club);
  UPDATE public.club_medical_centre
  SET specialist_tokens = least(20, specialist_tokens + v_n),
      updated_at = now()
  WHERE club_short_name = v_club
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'specialist_tokens', v_row.specialist_tokens,
    'granted', v_n,
    'max_specialist_tokens', 20
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_grant_specialist_tokens(text, int) TO authenticated;

-- Refresh state payload max_specialist_tokens (full body matches club_medical_room.sql)
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

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  SELECT to_jsonb(s) INTO v_doctor
  FROM public.club_medical_staff s
  WHERE s.club_short_name = v_club AND s.role = 'doctor'
  LIMIT 1;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.slot_index), '[]'::jsonb)
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

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'balance', coalesce(v_balance, 0),
    'specialist_tokens', v_centre.specialist_tokens,
    'physio_count', v_physio_n,
    'injury_chance_reduction_pct', round(v_physio_n * 0.5, 1),
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
    'physios', coalesce(v_physios, '[]'::jsonb),
    'active_injuries', coalesce(v_injuries, '[]'::jsonb),
    'specialist_matches_removed', 2,
    'doctor_matches_off', 1,
    'physio_bonus_each_pct', 0.5,
    'max_physios', 5,
    'max_specialist_tokens', 20,
    'contract_seasons', 3
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_room_state(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
