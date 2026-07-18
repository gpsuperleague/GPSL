-- =============================================================================
-- Persist cup + league prize config across seasons
--
-- - competition_admin_copy_cup_prizes(from, to)
-- - competition_admin_copy_league_prizes(from, to)
-- - competition_create_season auto-copies both (and GPDB exclusions if present)
--
-- Safe to re-run. Run after gpdb_season_exclusions_persist.sql if using exclusions.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_copy_cup_prizes(
  p_from_season_id bigint,
  p_to_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from bigint := p_from_season_id;
  v_to bigint := p_to_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_from IS NULL THEN
    SELECT s.id INTO v_from
    FROM public.competition_seasons s
    WHERE s.id <> coalesce(v_to, -1)
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_to IS NULL THEN
    SELECT id INTO v_to
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_from IS NULL OR v_to IS NULL THEN
    RAISE EXCEPTION 'from_season_id and to_season_id required';
  END IF;
  IF v_from = v_to THEN
    RAISE EXCEPTION 'Source and target season are the same';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_from) THEN
    RAISE EXCEPTION 'Source season % not found', v_from;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_to) THEN
    RAISE EXCEPTION 'Target season % not found', v_to;
  END IF;

  INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
  SELECT v_to, c.cup_code, c.stage, c.amount
  FROM public.competition_cup_prize_config c
  WHERE c.season_id = v_from
  ON CONFLICT (season_id, cup_code, stage)
  DO UPDATE SET amount = EXCLUDED.amount;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'from_season_id', v_from,
    'to_season_id', v_to,
    'rows_copied', v_n
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_copy_league_prizes(
  p_from_season_id bigint,
  p_to_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from bigint := p_from_season_id;
  v_to bigint := p_to_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_from IS NULL THEN
    SELECT s.id INTO v_from
    FROM public.competition_seasons s
    WHERE s.id <> coalesce(v_to, -1)
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_to IS NULL THEN
    SELECT id INTO v_to
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_from IS NULL OR v_to IS NULL THEN
    RAISE EXCEPTION 'from_season_id and to_season_id required';
  END IF;
  IF v_from = v_to THEN
    RAISE EXCEPTION 'Source and target season are the same';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_from) THEN
    RAISE EXCEPTION 'Source season % not found', v_from;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_to) THEN
    RAISE EXCEPTION 'Target season % not found', v_to;
  END IF;

  INSERT INTO public.competition_league_prize_config (
    season_id, division, position, amount
  )
  SELECT v_to, c.division, c.position, c.amount
  FROM public.competition_league_prize_config c
  WHERE c.season_id = v_from
  ON CONFLICT (season_id, division, position)
  DO UPDATE SET amount = EXCLUDED.amount, updated_at = now();

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'from_season_id', v_from,
    'to_season_id', v_to,
    'rows_copied', v_n
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_copy_cup_prizes(bigint, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_copy_league_prizes(bigint, bigint) TO authenticated;

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

    IF EXISTS (
      SELECT 1 FROM public.competition_cup_prize_config c WHERE c.season_id = v_prev
    ) THEN
      PERFORM public.competition_admin_copy_cup_prizes(v_prev, v_season_id);
    END IF;

    IF to_regclass('public.competition_league_prize_config') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_league_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_league_prizes(v_prev, v_season_id);
    END IF;
  END IF;

  RETURN v_season_id;
END;
$function$;

NOTIFY pgrst, 'reload schema';
