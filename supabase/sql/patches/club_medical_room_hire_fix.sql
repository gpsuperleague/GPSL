-- =============================================================================
-- Fix medical_hire_physio 400 — drop old overloads, ensure ledger types, recreate
-- Paste this whole file into Supabase SQL editor. Safe re-run.
-- =============================================================================

-- 1) Allow medical ledger entry types (merge with whatever already exists)
DO $ledger_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'medical_physio_hire',
      'medical_doctor_hire',
      'season_loan_fee',
      'season_loan_refund',
      'new_owner_release',
      'voluntary_contract_release',
      'special_auction_fee',
      'special_auction_prize'
    ])
  ) s;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );
END;
$ledger_types$;

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

-- 2) Remove every old hire overload (this is what causes 400 with the new UI)
DROP FUNCTION IF EXISTS public.medical_hire_physio(integer, text);
DROP FUNCTION IF EXISTS public.medical_hire_physio(int, text);
DROP FUNCTION IF EXISTS public.medical_hire_physio(integer);
DROP FUNCTION IF EXISTS public.medical_hire_physio(int);
DROP FUNCTION IF EXISTS public.medical_hire_physio(bigint);
DROP FUNCTION IF EXISTS public.medical_hire_physio(bigint, text);

CREATE OR REPLACE FUNCTION public.medical_hire_physio(p_slot integer)
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

  PERFORM public.medical_ensure_centre(v_club);

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF NOT FOUND OR v_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;
  IF v_balance < v_cost THEN
    RAISE EXCEPTION 'Insufficient balance (need %, have %)', v_cost, v_balance;
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

GRANT EXECUTE ON FUNCTION public.medical_hire_physio(integer) TO authenticated;

DROP FUNCTION IF EXISTS public.medical_hire_doctor(text);
DROP FUNCTION IF EXISTS public.medical_hire_doctor();

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
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF public.medical_club_has_doctor(v_club) THEN
    RAISE EXCEPTION 'Club already has a doctor';
  END IF;

  PERFORM public.medical_ensure_centre(v_club);

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF NOT FOUND OR v_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;
  IF v_balance < v_cost THEN
    RAISE EXCEPTION 'Insufficient balance (need %, have %)', v_cost, v_balance;
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

NOTIFY pgrst, 'reload schema';
