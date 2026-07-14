-- =============================================================================
-- Medical staff names (random first + surname by gender)
-- Safe re-run. Also backfills existing generic "Club doctor/physiotherapist" rows.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.medical_staff_random_name(p_gender text)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_gender text := lower(coalesce(nullif(btrim(p_gender), ''), 'male'));
  v_first text;
  v_last text;
  v_male text[] := ARRAY[
    'James','Thomas','Daniel','Michael','David','Andrew','Robert','Paul',
    'Mark','Steven','Christopher','Matthew','Jonathan','Benjamin','Alexander',
    'William','Oliver','Harry','Jack','George','Noah','Leo','Arthur','Henry'
  ];
  v_female text[] := ARRAY[
    'Sarah','Emily','Laura','Rachel','Emma','Sophie','Olivia','Charlotte',
    'Amelia','Jessica','Hannah','Megan','Chloe','Lucy','Grace','Ella',
    'Mia','Isla','Poppy','Freya','Lily','Eva','Ruby','Alice'
  ];
  v_surnames text[] := ARRAY[
    'Mitchell','Hughes','Patel','Singh','Murphy','Walsh','O''Brien','Kelly',
    'Campbell','Stewart','Fraser','MacLeod','Nguyen','Chen','Garcia','Rossi',
    'Schmidt','Andersen','Berg','Silva','Costa','Novak','Kowalski','Horvat',
    'Baker','Turner','Collins','Reed','Foster','Bennett','Palmer','Hayes'
  ];
BEGIN
  IF v_gender = 'female' THEN
    v_first := v_female[1 + floor(random() * array_length(v_female, 1))::int];
  ELSE
    v_first := v_male[1 + floor(random() * array_length(v_male, 1))::int];
  END IF;
  v_last := v_surnames[1 + floor(random() * array_length(v_surnames, 1))::int];
  RETURN v_first || ' ' || v_last;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_staff_random_name(text) TO authenticated;

-- Backfill staff that still have placeholder titles
UPDATE public.club_medical_staff s
SET display_name = public.medical_staff_random_name(s.gender)
WHERE coalesce(nullif(btrim(s.display_name), ''), '') = ''
   OR s.display_name IN ('Club doctor', 'Club physiotherapist');

DROP FUNCTION IF EXISTS public.medical_hire_physio(integer);
DROP FUNCTION IF EXISTS public.medical_hire_physio(int);

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
  v_cost numeric;
  v_balance numeric;
  v_season bigint;
  v_id bigint;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;
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
  IF v_cost IS NULL THEN
    RAISE EXCEPTION 'Invalid physio slot';
  END IF;

  v_name := public.medical_staff_random_name(v_gender);
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
    format('Medical Room — physio hire %s (slot %s)', v_name, p_slot),
    jsonb_build_object('slot', p_slot, 'gender', v_gender, 'display_name', v_name),
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
    'gender', v_gender,
    'display_name', v_name,
    'cost', v_cost,
    'physio_count', public.medical_club_physio_count(v_club)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_hire_physio(integer) TO authenticated;

DROP FUNCTION IF EXISTS public.medical_hire_doctor();
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
  v_name text;
  v_cost numeric := public.medical_doctor_hire_cost();
  v_balance numeric;
  v_season bigint;
  v_id bigint;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF public.medical_club_has_doctor(v_club) THEN
    RAISE EXCEPTION 'Club already has a doctor';
  END IF;

  v_name := public.medical_staff_random_name(v_gender);
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
    'medical_doctor_hire',
    -v_cost,
    format('Medical Room — doctor hire %s', v_name),
    jsonb_build_object('gender', v_gender, 'display_name', v_name),
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
    v_club, 'doctor', v_gender, v_name, NULL, 3, v_season, v_cost
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'staff_id', v_id,
    'gender', v_gender,
    'display_name', v_name,
    'cost', v_cost
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_hire_doctor() TO authenticated;

NOTIFY pgrst, 'reload schema';
