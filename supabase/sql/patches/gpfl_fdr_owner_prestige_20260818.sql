-- =============================================================================
-- GPFL FDR: owner skill first, club prestige fallback / balance
--
-- Same idea as bookies_club_strength:
--   • Prefer rolling-4 owner rank when the owner has ranking history
--   • Fall back to club prestige when there is no owner history
--   • Blend in club prestige so equal / similar owners still differ by club
--
-- FDR scale remains 1 (easiest) … 5 (hardest).
--
-- Safe re-run. Run after gpfl_v2_core_20260818.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpfl_fdr_from_strength_rank(p_rank numeric)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  -- Strength rank 1 = strongest opponent. Bands sized for ~40-club prestige pool.
  SELECT CASE
    WHEN p_rank IS NULL THEN 3
    WHEN p_rank <= 4 THEN 5
    WHEN p_rank <= 8 THEN 4
    WHEN p_rank <= 14 THEN 3
    WHEN p_rank <= 22 THEN 2
    ELSE 1
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpfl_fdr_for_club(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner_rank int;
  v_seasons int;
  v_club_rank int;
  v_n int := 40;
  v_owner_str numeric;
  v_club_str numeric;
  v_str numeric;
  v_eff_rank numeric;
BEGIN
  IF p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN 3;
  END IF;

  SELECT r.rank_position::int, coalesce(r.seasons_count, 0)
  INTO v_owner_rank, v_seasons
  FROM public.competition_owner_ranking_rolling4_public r
  WHERE r.club_short_name = p_club_short_name
  ORDER BY r.rank_position
  LIMIT 1;

  SELECT p.prestige_rank::int INTO v_club_rank
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = p_club_short_name
  LIMIT 1;

  SELECT greatest(coalesce(max(prestige_rank), 40), 10)::int INTO v_n
  FROM public.competition_club_prestige_public;

  v_club_rank := coalesce(v_club_rank, greatest(v_n / 2, 10));
  v_club_str := (v_n + 1 - least(v_club_rank, v_n))::numeric;

  IF v_owner_rank IS NOT NULL AND v_seasons > 0 THEN
    -- Owner skill primary; club prestige balances equal / similar owners
    v_owner_str := (v_n + 1 - least(v_owner_rank, v_n))::numeric;
    v_str := (0.75 * v_owner_str) + (0.25 * v_club_str);
  ELSE
    -- No owner ranking history → club prestige only
    v_str := v_club_str;
  END IF;

  v_eff_rank := (v_n + 1)::numeric - v_str;
  RETURN public.gpfl_fdr_from_strength_rank(v_eff_rank);
END;
$function$;

-- Keep old helper for any callers; map table pos the same way as before.
CREATE OR REPLACE FUNCTION public.gpfl_fdr_from_table_pos(p_pos int)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.gpfl_fdr_from_strength_rank(p_pos::numeric);
$$;

CREATE OR REPLACE FUNCTION public.gpfl_player_next_fixtures(
  p_player_id text,
  p_limit int DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint := public.gpfl_current_season_id();
  v_comp_id bigint;
  v_club text;
  v_rows jsonb;
  v_lim int := greatest(1, least(coalesce(p_limit, 5), 10));
BEGIN
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  IF v_gs_id IS NOT NULL THEN
    SELECT gs.competition_season_id INTO v_comp_id
    FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;
  END IF;

  IF v_comp_id IS NULL THEN
    SELECT cs.id INTO v_comp_id
    FROM public.competition_seasons cs
    WHERE cs.is_current = true
    ORDER BY cs.id DESC
    LIMIT 1;
  END IF;

  IF v_comp_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT p."Contracted_Team" INTO v_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id
  LIMIT 1;

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.month_sort, r.matchday), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      f.id AS fixture_id,
      f.gpsl_month,
      coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99) AS month_sort,
      f.matchday,
      f.division,
      (f.home_club_short_name = v_club) AS is_home,
      CASE
        WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
        ELSE f.home_club_short_name
      END AS opponent_short_name,
      coalesce(
        nullif(btrim(c."Club"), ''),
        CASE
          WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
          ELSE f.home_club_short_name
        END
      ) AS opponent_name,
      ow.rank_position AS opponent_owner_rank,
      coalesce(ow.seasons_count, 0) AS opponent_owner_seasons,
      pr.prestige_rank AS opponent_prestige_rank,
      public.competition_club_table_position(
        f.season_id,
        f.division,
        CASE
          WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
          ELSE f.home_club_short_name
        END
      ) AS opponent_position,
      public.gpfl_fdr_for_club(
        CASE
          WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
          ELSE f.home_club_short_name
        END
      ) AS fdr,
      CASE
        WHEN coalesce(ow.seasons_count, 0) > 0 THEN 'owner+club'
        ELSE 'club'
      END AS fdr_basis
    FROM public.competition_fixtures f
    LEFT JOIN public."Clubs" c
      ON c."ShortName" = CASE
        WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
        ELSE f.home_club_short_name
      END
    LEFT JOIN public.competition_owner_ranking_rolling4_public ow
      ON ow.club_short_name = CASE
        WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
        ELSE f.home_club_short_name
      END
    LEFT JOIN public.competition_club_prestige_public pr
      ON pr.club_short_name = CASE
        WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
        ELSE f.home_club_short_name
      END
    WHERE f.season_id = v_comp_id
      AND f.status = 'scheduled'
      AND f.competition_type = ANY (v_cfg.competition_types)
      AND (f.home_club_short_name = v_club OR f.away_club_short_name = v_club)
    ORDER BY coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99), f.matchday
    LIMIT v_lim
  ) r;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_fdr_from_strength_rank(numeric) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_fdr_for_club(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_fdr_from_table_pos(int) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_player_next_fixtures(text, int) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
