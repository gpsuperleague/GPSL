-- =============================================================================
-- Hotfix: save cup/league prize templates — DELETE requires a WHERE clause
--
-- Supabase/PostgREST (and project safety) reject bare DELETE FROM table.
-- competition_admin_save_*_prize_template used unqualified DELETEs → 400.
--
-- Safe re-run. Also re-GRANTs + schema reload (covers earlier 404 if not exposed).
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.competition_admin_save_cup_prize_template(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season to snapshot';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_cup_prize_config WHERE season_id = v_season_id
  ) THEN
    RAISE EXCEPTION 'Season % has no cup prize config to save', v_season_id;
  END IF;

  -- WHERE true required (bare DELETE is blocked)
  DELETE FROM public.competition_cup_prize_template WHERE true;

  INSERT INTO public.competition_cup_prize_template (cup_code, stage, amount, updated_at)
  SELECT c.cup_code, c.stage, c.amount, now()
  FROM public.competition_cup_prize_config c
  WHERE c.season_id = v_season_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'rows_saved', v_n
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_save_league_prize_template(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season to snapshot';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_league_prize_config WHERE season_id = v_season_id
  ) THEN
    RAISE EXCEPTION 'Season % has no league prize config to save', v_season_id;
  END IF;

  DELETE FROM public.competition_league_prize_template WHERE true;

  INSERT INTO public.competition_league_prize_template (division, position, amount, updated_at)
  SELECT c.division, c.position, c.amount, now()
  FROM public.competition_league_prize_config c
  WHERE c.season_id = v_season_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'rows_saved', v_n
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_save_cup_prize_template(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_save_league_prize_template(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_save_prize_templates(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
