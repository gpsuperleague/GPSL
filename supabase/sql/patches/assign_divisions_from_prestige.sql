-- =============================================================================
-- Assign divisions from current prestige order (Season 1 / first-season setup)
-- =============================================================================
-- Uses competition_club_prestige_public (same order as Admin → Club attendance /
-- prestige page): seed + capacity when no rolling history yet.
--
--   ranks 1–20  → Super League
--   ranks 21+   → Championship A / B alternating (21=A, 22=B, 23=A, …)
--
-- Overwrites SL / pool / A–B on the selected setup/preseason. Sets
-- championship_drawn_at so Activate season can proceed without a random draw.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_assign_divisions_from_prestige(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_total int;
  v_sl int;
  v_a int;
  v_b int;
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  SELECT count(*)::int INTO v_total
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id;

  IF v_total <> 60 THEN
    RAISE EXCEPTION 'Season must have exactly 60 registered clubs (currently %)', v_total;
  END IF;

  IF to_regclass('public.competition_club_prestige_public') IS NULL THEN
    RAISE EXCEPTION 'Prestige view missing — run stadium attendance / prestige patches first';
  END IF;

  WITH ordered AS (
    SELECT
      ccs.club_short_name,
      row_number() OVER (
        ORDER BY p.prestige_rank NULLS LAST, ccs.club_short_name
      ) AS rn
    FROM public.competition_club_seasons ccs
    LEFT JOIN public.competition_club_prestige_public p
      ON p.club_short_name = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
  )
  UPDATE public.competition_club_seasons ccs
  SET division = CASE
    WHEN o.rn <= 20 THEN 'superleague'
    WHEN ((o.rn - 21) % 2) = 0 THEN 'championship_a'
    ELSE 'championship_b'
  END
  FROM ordered o
  WHERE ccs.season_id = p_season_id
    AND ccs.club_short_name = o.club_short_name;

  UPDATE public.competition_seasons
  SET championship_drawn_at = now()
  WHERE id = p_season_id;

  SELECT
    count(*) FILTER (WHERE division = 'superleague')::int,
    count(*) FILTER (WHERE division = 'championship_a')::int,
    count(*) FILTER (WHERE division = 'championship_b')::int
  INTO v_sl, v_a, v_b
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id;

  IF v_sl <> 20 OR v_a <> 20 OR v_b <> 20 THEN
    RAISE EXCEPTION
      'Prestige assign produced invalid counts (SL %, A %, B %). Check prestige ranks cover all 60 clubs.',
      v_sl, v_a, v_b;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'superleague', v_sl,
    'championship_a', v_a,
    'championship_b', v_b,
    'source', 'competition_club_prestige_public'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_assign_divisions_from_prestige(bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
