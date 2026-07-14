-- =============================================================================
-- Admin test: seed 1 suspended + 1 injured player per club (random)
-- Run after competition_injuries_engine.sql + competition_player_discipline.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_test_seed_squad_discipline(
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_club text;
  v_susp_player text;
  v_inj_player text;
  v_fit_gk int;
  v_cat public.competition_injury_catalogue%rowtype;
  v_susp_id bigint;
  v_inj_id bigint;
  v_fx record;
  v_seq int;
  v_clubs int := 0;
  v_suspensions int := 0;
  v_injuries int := 0;
  v_skipped int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.competition_injury_catalogue WHERE active LIMIT 1) THEN
    RAISE EXCEPTION 'Injury catalogue empty — run competition_injuries_engine.sql';
  END IF;

  FOR v_club IN
    SELECT DISTINCT ccs.club_short_name
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season
    ORDER BY 1
  LOOP
    IF NOT p_force AND EXISTS (
      SELECT 1 FROM public.competition_player_injuries i
      WHERE i.season_id = v_season
        AND i.club_short_name = v_club
        AND i.status = 'active'
        AND coalesce(i.notes, '') = 'admin_test_seed'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF p_force THEN
      -- Clear prior test injuries for this club
      UPDATE public.competition_player_injuries i
      SET status = 'cancelled', recovered_at = coalesce(recovered_at, now())
      WHERE i.season_id = v_season
        AND i.club_short_name = v_club
        AND i.status = 'active'
        AND coalesce(i.notes, '') = 'admin_test_seed';
    END IF;

    IF (
      SELECT count(*) FROM public."Players" p WHERE p."Contracted_Team" = v_club
    ) < 2 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_fit_gk := CASE
      WHEN to_regprocedure('public.competition_injury_fit_gk_count(text)') IS NOT NULL
      THEN public.competition_injury_fit_gk_count(v_club)
      ELSE 99
    END;

    SELECT p."Konami_ID"::text INTO v_susp_player
    FROM public."Players" p
    WHERE p."Contracted_Team" = v_club
    ORDER BY random()
    LIMIT 1;

    SELECT p."Konami_ID"::text INTO v_inj_player
    FROM public."Players" p
    WHERE p."Contracted_Team" = v_club
      AND p."Konami_ID"::text IS DISTINCT FROM v_susp_player
      AND NOT (
        upper(coalesce(p."Position", '')) = 'GK'
        AND v_fit_gk <= 1
      )
    ORDER BY random()
    LIMIT 1;

    IF v_inj_player IS NULL THEN
      SELECT p."Konami_ID"::text INTO v_inj_player
      FROM public."Players" p
      WHERE p."Contracted_Team" = v_club
        AND p."Konami_ID"::text IS DISTINCT FROM v_susp_player
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_susp_player IS NULL OR v_inj_player IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Suspension: 2-match ban on next scheduled fixtures
    INSERT INTO public.competition_player_suspensions (
      season_id, player_id, club_short_name, reason,
      source_fixture_id, ban_matches, status
    )
    VALUES (
      v_season, v_susp_player, v_club, 'red_card',
      NULL, 2, 'active'
    )
    RETURNING id INTO v_susp_id;

    v_seq := 0;
    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season
        AND f.status = 'scheduled'
        AND (f.home_club_short_name = v_club OR f.away_club_short_name = v_club)
      ORDER BY coalesce(f.matchday, 9999), f.id
      LIMIT 2
    LOOP
      v_seq := v_seq + 1;
      INSERT INTO public.competition_player_suspension_matches (
        suspension_id, fixture_id, sequence_no, served
      ) VALUES (v_susp_id, v_fx.id, v_seq, false)
      ON CONFLICT DO NOTHING;
    END LOOP;

    v_suspensions := v_suspensions + 1;

    -- Injury: random catalogue row (any severity)
    SELECT * INTO v_cat
    FROM public.competition_injury_catalogue c
    WHERE c.active
    ORDER BY random()
    LIMIT 1;

    PERFORM public.competition_injury_ensure_club_season(v_season, v_club);

    INSERT INTO public.competition_player_injuries (
      season_id, incurred_season_id, player_id, club_short_name,
      label, status, catalogue_id, severity,
      matches_out, recovery_matches,
      matches_out_remaining, recovery_remaining,
      source_fixture_id, notes
    )
    VALUES (
      v_season, v_season, v_inj_player, v_club,
      v_cat.name, 'active', v_cat.id, v_cat.severity,
      v_cat.matches_out, v_cat.recovery_matches,
      v_cat.matches_out, v_cat.recovery_matches,
      NULL, 'admin_test_seed'
    )
    RETURNING id INTO v_inj_id;

    UPDATE public.competition_club_injury_season
    SET count_total = least(count_total + 1, 99),
        count_major = count_major + CASE WHEN v_cat.severity = 'Major' THEN 1 ELSE 0 END,
        count_moderate = count_moderate + CASE WHEN v_cat.severity = 'Moderate' THEN 1 ELSE 0 END,
        count_minor = count_minor + CASE WHEN v_cat.severity = 'Minor' THEN 1 ELSE 0 END
    WHERE season_id = v_season AND club_short_name = v_club;

    PERFORM public.competition_injury_assign_fixtures(v_inj_id);

    v_injuries := v_injuries + 1;
    v_clubs := v_clubs + 1;

    v_details := v_details || jsonb_build_array(
      jsonb_build_object(
        'club', v_club,
        'suspended_player_id', v_susp_player,
        'injured_player_id', v_inj_player,
        'injury', v_cat.name,
        'severity', v_cat.severity,
        'matches_out', v_cat.matches_out,
        'recovery_matches', v_cat.recovery_matches,
        'suspension_fixtures_linked', v_seq
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'clubs_seeded', v_clubs,
    'suspensions', v_suspensions,
    'injuries', v_injuries,
    'skipped', v_skipped,
    'details', v_details
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_test_seed_squad_discipline(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
