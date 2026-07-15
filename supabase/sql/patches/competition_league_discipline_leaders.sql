-- =============================================================================
-- League stats — top 10 discipline leaders (current season)
--
-- Columns: yellows (season), yellow period toward next ban (n/8),
--          red cards (direct), suspensions issued (red + every 8 yellows).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_league_discipline_leaders(
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL,
  p_limit int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_div text := nullif(btrim(lower(coalesce(p_division, ''))), '');
  v_limit int := greatest(coalesce(p_limit, 10), 1);
  v_out jsonb;
BEGIN
  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT
      c.player_id,
      p."Name" AS player_name,
      c.club_short_name,
      cl."Club" AS club_name,
      ccs.division,
      c.yellow_cards,
      c.red_cards,
      (c.yellow_cards % 8) AS yellow_period,
      8 AS yellow_period_size,
      c.suspensions,
      c.suspensions_from_red,
      c.suspensions_from_yellow
    FROM (
      SELECT
        m.player_id,
        -- Prefer current contracted club; fall back to last club on a card
        coalesce(
          nullif(btrim(pl."Contracted_Team"), ''),
          (
            SELECT m2.club_short_name
            FROM public.competition_match_player_stats m2
            WHERE m2.season_id = v_season
              AND m2.player_id = m.player_id
              AND (m2.yellow_card OR m2.red_card)
            ORDER BY m2.fixture_id DESC
            LIMIT 1
          )
        ) AS club_short_name,
        count(*) FILTER (WHERE m.yellow_card)::int AS yellow_cards,
        count(*) FILTER (WHERE m.red_card)::int AS red_cards,
        coalesce((
          SELECT count(*)::int
          FROM public.competition_player_suspensions s
          WHERE s.season_id = v_season
            AND s.player_id = m.player_id
            AND s.status IN ('active', 'completed')
        ), 0) AS suspensions,
        coalesce((
          SELECT count(*)::int
          FROM public.competition_player_suspensions s
          WHERE s.season_id = v_season
            AND s.player_id = m.player_id
            AND s.reason = 'red_card'
            AND s.status IN ('active', 'completed')
        ), 0) AS suspensions_from_red,
        coalesce((
          SELECT count(*)::int
          FROM public.competition_player_suspensions s
          WHERE s.season_id = v_season
            AND s.player_id = m.player_id
            AND s.reason = 'yellow_accumulation'
            AND s.status IN ('active', 'completed')
        ), 0) AS suspensions_from_yellow
      FROM public.competition_match_player_stats m
      LEFT JOIN public."Players" pl ON pl."Konami_ID"::text = m.player_id
      WHERE m.season_id = v_season
        AND (m.yellow_card OR m.red_card)
      GROUP BY m.player_id, pl."Contracted_Team"
    ) c
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = c.player_id
    LEFT JOIN public."Clubs" cl ON cl."ShortName" = c.club_short_name
    LEFT JOIN public.competition_club_seasons ccs
      ON ccs.season_id = v_season
     AND ccs.club_short_name = c.club_short_name
    WHERE (v_div IS NULL OR ccs.division = v_div)
      AND (c.yellow_cards > 0 OR c.red_cards > 0 OR c.suspensions > 0)
    ORDER BY
      c.suspensions DESC,
      c.yellow_cards DESC,
      c.red_cards DESC,
      p."Name" ASC NULLS LAST
    LIMIT v_limit
  ) x;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_league_discipline_leaders(bigint, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_league_discipline_leaders(bigint, text, int) TO anon;

NOTIFY pgrst, 'reload schema';
