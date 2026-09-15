-- =============================================================================
-- Backfill vacant (unowned) clubs in the active league setup
--
-- For each SL / ChA / ChB club with owner_id IS NULL:
--   1) Ensure Club_Finances exists
--   2) If no assignment stadium infra_purchase yet (and not a continuing club):
--        post infra_purchase (capacity × stadium rate) with starting_budget meta
--        and debit live cash (keeps gates/prizes already earned)
--   3) If no club doctor: hire one (₿5m medical_doctor_hire) — baseline staff
--
-- Safe re-run. Admin only.
--
-- Run once in Supabase SQL Editor, then:
--   SELECT public.admin_backfill_vacant_league_club_costs();
-- Or use League finance balance → Backfill vacant clubs.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_medical_hire_doctor_for_club(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_gender text := CASE WHEN random() < 0.5 THEN 'male' ELSE 'female' END;
  v_cost numeric;
  v_season bigint;
  v_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club = '' OR v_club = 'FOREIGN' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF to_regprocedure('public.medical_club_has_doctor(text)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'skipped', true, 'reason', 'medical_room_not_deployed');
  END IF;

  IF public.medical_club_has_doctor(v_club) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_has_doctor', 'club', v_club);
  END IF;

  v_cost := public.medical_doctor_hire_cost();
  PERFORM public.medical_ensure_centre(v_club);

  IF NOT EXISTS (SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_club) THEN
    INSERT INTO public."Club_Finances" (club_name, balance) VALUES (v_club, 0);
  END IF;

  v_season := public.competition_finances_current_season_id();

  PERFORM public.post_club_ledger(
    v_club,
    'medical_doctor_hire',
    -v_cost,
    'Medical Room — club doctor hire (vacant league backfill)',
    jsonb_build_object(
      'gender', v_gender,
      'source', 'vacant_league_backfill'
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
    v_club, 'doctor', v_gender, 'Club doctor', NULL, 3, v_season, v_cost
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'skipped', false,
    'club', v_club,
    'staff_id', v_id,
    'cost', v_cost,
    'gender', v_gender
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_backfill_vacant_league_club_costs(
  p_season_id bigint DEFAULT NULL,
  p_hire_doctor boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_starting numeric;
  v_row record;
  v_stadium numeric;
  v_cash numeric;
  v_ledger_id bigint;
  v_club_name text;
  v_desc text;
  v_fin jsonb;
  v_doc jsonb;
  v_results jsonb := '[]'::jsonb;
  v_fixed int := 0;
  v_stadium_posted int := 0;
  v_doctors int := 0;
  v_skipped int := 0;
  v_dup_key text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NOT NULL THEN
    v_season_id := p_season_id;
  ELSE
    v_season_id := public.competition_finances_current_season_id();
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current finance season';
  END IF;

  v_starting := greatest(coalesce(public.club_auction_default_starting_balance(), 650000000), 0);

  FOR v_row IN
    SELECT
      c."ShortName" AS short_name,
      c."Club" AS club_name,
      coalesce(c."Capacity", 0)::bigint AS capacity,
      coalesce(f.balance, 0) AS cash_before
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    LEFT JOIN public."Club_Finances" f ON f.club_name = c."ShortName"
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND c.owner_id IS NULL
      AND c."ShortName" <> 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
    ORDER BY c."ShortName"
  LOOP
    v_fin := jsonb_build_object('club', v_row.short_name);
    v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_row.short_name), 0);
    v_dup_key := 'vacant:' || v_row.short_name || ':' || v_season_id::text;

    -- Ensure finance row
    IF NOT EXISTS (
      SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_row.short_name
    ) THEN
      INSERT INTO public."Club_Finances" (club_name, balance)
      VALUES (v_row.short_name, v_starting);
      v_cash := v_starting;
    ELSE
      v_cash := v_row.cash_before;
      -- Seed zero/null cash up to starting before stadium debit (do not wipe richer balances)
      IF v_cash IS NULL OR v_cash <= 0 THEN
        UPDATE public."Club_Finances"
        SET balance = v_starting
        WHERE club_name = v_row.short_name;
        v_cash := v_starting;
      END IF;
    END IF;

    -- Stadium / starting-budget trail
    IF public.club_had_prior_finance_season(v_row.short_name, v_season_id)
       OR public.club_has_assignment_infra_purchase(v_row.short_name, NULL) THEN
      v_fin := v_fin || jsonb_build_object(
        'stadium', 'skipped_already_posted_or_continuing',
        'stadium_cost', v_stadium
      );
    ELSIF v_stadium > 0 THEN
      v_club_name := coalesce(v_row.club_name, v_row.short_name);
      v_desc := format(
        'Stadium purchase — %s (%s) — vacant league backfill (capacity × rate)',
        v_club_name,
        v_row.short_name
      );

      v_ledger_id := public.post_club_ledger(
        v_row.short_name,
        'infra_purchase',
        -v_stadium,
        v_desc,
        jsonb_build_object(
          'source', 'vacant_league_backfill',
          'assignment_key', v_dup_key,
          'dup_key', v_dup_key,
          'stadium_cost', v_stadium,
          'total_debit', v_stadium,
          'starting_budget', v_starting,
          'capacity', v_row.capacity
        ),
        v_season_id,
        NULL,
        false,
        true
      );

      v_stadium_posted := v_stadium_posted + 1;
      v_fin := v_fin || jsonb_build_object(
        'stadium', 'posted',
        'stadium_cost', v_stadium,
        'ledger_id', v_ledger_id,
        'starting_budget', v_starting
      );
    ELSE
      v_fin := v_fin || jsonb_build_object('stadium', 'skipped_zero_cost');
    END IF;

    -- Baseline medical staff (doctor only)
    IF coalesce(p_hire_doctor, true) THEN
      BEGIN
        v_doc := public.admin_medical_hire_doctor_for_club(v_row.short_name);
        v_fin := v_fin || jsonb_build_object('doctor', v_doc);
        IF coalesce((v_doc->>'skipped')::boolean, false) = false
           AND coalesce((v_doc->>'ok')::boolean, false) = true THEN
          v_doctors := v_doctors + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_fin := v_fin || jsonb_build_object(
          'doctor', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
      END;
    ELSE
      v_fin := v_fin || jsonb_build_object('doctor', 'skipped_by_flag');
    END IF;

    SELECT balance INTO v_cash
    FROM public."Club_Finances"
    WHERE club_name = v_row.short_name;

    v_fin := v_fin || jsonb_build_object(
      'cash_before', v_row.cash_before,
      'cash_after', v_cash
    );
    v_results := v_results || jsonb_build_array(v_fin);
    v_fixed := v_fixed + 1;
  END LOOP;

  IF v_fixed = 0 THEN
    v_skipped := 0;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'starting_budget', v_starting,
    'hire_doctor', coalesce(p_hire_doctor, true),
    'clubs_processed', v_fixed,
    'stadium_posts', v_stadium_posted,
    'doctors_hired', v_doctors,
    'note',
      'Vacant league clubs only. Stadium debit preserves existing cash (gates etc). Doctor hire is baseline Medical Room staff. Manager salary still posts at Close Finances when a manager is assigned.',
    'results', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_medical_hire_doctor_for_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_backfill_vacant_league_club_costs(bigint, boolean)
  TO authenticated;

COMMENT ON FUNCTION public.admin_backfill_vacant_league_club_costs(bigint, boolean) IS
  'Backfill unowned SL/ChA/ChB clubs: stadium infra_purchase + starting_budget meta, optional doctor hire.';

NOTIFY pgrst, 'reload schema';
