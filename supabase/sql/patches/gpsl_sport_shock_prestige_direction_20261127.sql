-- Shock results treated rank 1 (the biggest club) beating a smaller club as an upset.
-- Rank 1 is the top of the prestige table. A shock is the worse rank winning.
-- Safe re-run: the swap only runs while the old direction is still in the function.

DO $swap$
DECLARE
  r record;
  v_def text;
  v_old_home text := 'v_gap := coalesce(v_f.away_prestige, 99) - coalesce(v_f.home_prestige, 99);';
  v_old_away text := 'v_gap := coalesce(v_f.home_prestige, 99) - coalesce(v_f.away_prestige, 99);';
  v_home_win text := 'v_gap := coalesce(v_f.home_prestige, 99) - coalesce(v_f.away_prestige, 99);';
  v_away_win text := 'v_gap := coalesce(v_f.away_prestige, 99) - coalesce(v_f.home_prestige, 99);';
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND pg_get_functiondef(p.oid) LIKE '%' || v_old_home || '%'
  LOOP
    v_def := pg_get_functiondef(r.sig);
    IF position(v_old_home IN v_def) = 0 OR position(v_old_away IN v_def) = 0 THEN
      CONTINUE;
    END IF;
    -- Home win is currently the away-minus-home line. Swap the two assignments.
    v_def := replace(v_def, v_old_home, 'v_gap := __SHOCK_GAP_TOKEN__;');
    v_def := replace(v_def, v_old_away, v_away_win);
    v_def := replace(v_def, 'v_gap := __SHOCK_GAP_TOKEN__;', v_home_win);
    EXECUTE v_def;
    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 AND position(
    v_home_win IN pg_get_functiondef('public.gpsl_sport_build_inseason_month_content(bigint,text)'::regprocedure)
  ) = 0 THEN
    RAISE EXCEPTION 'Shock gap was not rewritten and the corrected line is missing';
  END IF;
END;
$swap$;

-- Republish in-season editions so the stored shock column matches the new rule.
DO $refresh$
DECLARE
  v_id bigint;
  v_season bigint;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);
  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current IS TRUE
  ORDER BY s.id DESC
  LIMIT 1;

  FOR v_id IN
    SELECT e.id
    FROM public.gpsl_sport_editions e
    WHERE e.season_id = v_season
      AND lower(e.gpsl_month) NOT IN ('may', 'june', 'july')
    ORDER BY e.id
  LOOP
    PERFORM public.gpsl_sport_refresh_inseason_edition_by_id(v_id);
  END LOOP;
END;
$refresh$;

SELECT jsonb_build_object(
  'home_win_is_winner_rank_minus_loser', position(
    'v_gap := coalesce(v_f.home_prestige, 99) - coalesce(v_f.away_prestige, 99);'
    IN pg_get_functiondef('public.gpsl_sport_build_inseason_month_content(bigint,text)'::regprocedure)
  ) > 0,
  'december_shocks', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'winner', s->>'winner_name',
      'loser', s->>'loser_name',
      'score', s->>'score'
    )), '[]'::jsonb)
    FROM public.gpsl_sport_editions e
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(e.back_page->'shock_results', e.front_page->'shock_results', '[]'::jsonb)) s
    WHERE e.season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
      AND lower(e.gpsl_month) = 'december'
  )
) AS check;
