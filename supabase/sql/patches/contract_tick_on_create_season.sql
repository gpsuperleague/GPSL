-- =============================================================================
-- Contract tick on Create next season (including Summer Break)
--
-- Bug: admin UI only called contract_tick_season_rollover() when a competition
-- season was still is_current. After competition_end_season() (Summer Break),
-- Create next season skipped the tick — contracts stayed at 3 seasons.
--
-- Fix: always tick when creating a season that has a previous season row.
-- Safe re-run. Requires contract_tick_season_rollover() (phase2/phase3).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_create_season(p_label text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text := trim(p_label);
  v_season_id bigint;
  v_club_count bigint;
  v_prev bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_label IS NULL OR v_label = '' THEN
    RAISE EXCEPTION 'Season label is required';
  END IF;

  INSERT INTO public.competition_seasons (label, status, is_current)
  VALUES (v_label, 'preseason', false)
  RETURNING id INTO v_season_id;

  INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
  SELECT v_season_id, c."ShortName", 'unassigned'
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
  ORDER BY c."ShortName";

  GET DIAGNOSTICS v_club_count = ROW_COUNT;

  IF v_club_count <> 60 THEN
    RAISE EXCEPTION 'Expected 60 clubs, found %', v_club_count;
  END IF;

  SELECT s.id INTO v_prev
  FROM public.competition_seasons s
  WHERE s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev IS NOT NULL THEN
    IF to_regprocedure('public.admin_gpdb_copy_season_exclusions(bigint, bigint)') IS NOT NULL
       AND (
         EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_players ep WHERE ep.season_id = v_prev
         )
         OR EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_nations en WHERE en.season_id = v_prev
         )
       )
    THEN
      PERFORM public.admin_gpdb_copy_season_exclusions(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_cup_prizes(bigint, bigint)') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_cup_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_cup_prizes(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_league_prizes(bigint, bigint)') IS NOT NULL
       AND to_regclass('public.competition_league_prize_config') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_league_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_league_prizes(v_prev, v_season_id);
    END IF;

    -- Season N → N+1: decrement contracts even when prior year is already complete
    -- (Summer Break / no is_current). Inaugural season (no v_prev) skips this.
    IF to_regprocedure('public.contract_tick_season_rollover()') IS NOT NULL THEN
      PERFORM public.contract_tick_season_rollover();
    END IF;
  END IF;

  RETURN v_season_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_create_season(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
