-- Public challenge league table: all clubs ranked by challenge success.
-- Run in Supabase SQL Editor after competition_challenges (+ june_transfers / pack patches).

CREATE OR REPLACE FUNCTION public.competition_challenge_league_table(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_club text;
  v_club_name text;
  v_chal record;
  v_val int;
  v_awarded boolean;
  v_done boolean;
  v_target int;
  v_progress numeric;
  v_start_total int := 0;
  v_mid_total int := 0;
  v_rows jsonb := '[]'::jsonb;
  v_club_map jsonb := '{}'::jsonb;
  v_entry jsonb;
  v_start jsonb;
  v_mid jsonb;
  v_overall jsonb;
  v_item jsonb;
  v_key text;
BEGIN
  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object(
      'season_id', null,
      'start_total', 0,
      'mid_total', 0,
      'start', '[]'::jsonb,
      'mid', '[]'::jsonb,
      'overall', '[]'::jsonb
    );
  END IF;

  SELECT
    count(*) FILTER (WHERE window_phase = 'start'),
    count(*) FILTER (WHERE window_phase = 'mid')
  INTO v_start_total, v_mid_total
  FROM public.competition_challenge_config
  WHERE season_id = v_season_id
    AND is_active = true;

  -- Seed every club in the season
  FOR v_club, v_club_name IN
    SELECT ccs.club_short_name, coalesce(cl."Club", ccs.club_short_name)
    FROM public.competition_club_seasons ccs
    LEFT JOIN public."Clubs" cl ON cl."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    ORDER BY coalesce(cl."Club", ccs.club_short_name)
  LOOP
    v_club_map := v_club_map || jsonb_build_object(
      v_club,
      jsonb_build_object(
        'club_short_name', v_club,
        'club_name', v_club_name,
        'start_completed', 0,
        'start_progress', 0,
        'start_prize', 0,
        'mid_completed', 0,
        'mid_progress', 0,
        'mid_prize', 0
      )
    );
  END LOOP;

  -- Accumulate per challenge
  FOR v_chal IN
    SELECT *
    FROM public.competition_challenge_config
    WHERE season_id = v_season_id
      AND is_active = true
    ORDER BY window_phase, sort_order, id
  LOOP
    v_target := greatest(coalesce(v_chal.target_value, 1), 1);

    FOR v_club IN
      SELECT jsonb_object_keys(v_club_map)
    LOOP
      v_val := public.competition_challenge_stat_value(
        v_season_id,
        v_club,
        v_chal.stat_type,
        v_chal.gpsl_month_from,
        v_chal.gpsl_month_to,
        v_chal.include_league,
        v_chal.include_cup,
        v_chal.stat_param
      );

      SELECT EXISTS (
        SELECT 1
        FROM public.competition_challenge_awarded a
        WHERE a.challenge_id = v_chal.id
          AND a.club_short_name = v_club
      ) INTO v_awarded;

      v_done := v_awarded OR coalesce(v_val, 0) >= v_chal.target_value;
      -- Cap progress at 100% per challenge
      v_progress := least(1.0, coalesce(v_val, 0)::numeric / v_target::numeric);
      IF v_done THEN
        v_progress := 1.0;
      END IF;

      v_entry := v_club_map -> v_club;

      IF v_chal.window_phase = 'mid' THEN
        v_entry := jsonb_set(
          v_entry,
          '{mid_completed}',
          to_jsonb(coalesce((v_entry->>'mid_completed')::int, 0) + CASE WHEN v_done THEN 1 ELSE 0 END)
        );
        v_entry := jsonb_set(
          v_entry,
          '{mid_progress}',
          to_jsonb(coalesce((v_entry->>'mid_progress')::numeric, 0) + v_progress)
        );
        IF v_awarded THEN
          v_entry := jsonb_set(
            v_entry,
            '{mid_prize}',
            to_jsonb(
              coalesce((v_entry->>'mid_prize')::numeric, 0)
              + coalesce(v_chal.prize_amount, 0)
            )
          );
        END IF;
      ELSE
        v_entry := jsonb_set(
          v_entry,
          '{start_completed}',
          to_jsonb(coalesce((v_entry->>'start_completed')::int, 0) + CASE WHEN v_done THEN 1 ELSE 0 END)
        );
        v_entry := jsonb_set(
          v_entry,
          '{start_progress}',
          to_jsonb(coalesce((v_entry->>'start_progress')::numeric, 0) + v_progress)
        );
        IF v_awarded THEN
          v_entry := jsonb_set(
            v_entry,
            '{start_prize}',
            to_jsonb(
              coalesce((v_entry->>'start_prize')::numeric, 0)
              + coalesce(v_chal.prize_amount, 0)
            )
          );
        END IF;
      END IF;

      v_club_map := jsonb_set(v_club_map, ARRAY[v_club], v_entry);
    END LOOP;
  END LOOP;

  -- Flatten to array
  FOR v_key, v_item IN
    SELECT * FROM jsonb_each(v_club_map)
  LOOP
    v_rows := v_rows || jsonb_build_array(
      v_item || jsonb_build_object(
        'start_total', v_start_total,
        'mid_total', v_mid_total,
        'total_completed',
          coalesce((v_item->>'start_completed')::int, 0)
          + coalesce((v_item->>'mid_completed')::int, 0),
        'total_challenges', v_start_total + v_mid_total,
        'total_progress',
          coalesce((v_item->>'start_progress')::numeric, 0)
          + coalesce((v_item->>'mid_progress')::numeric, 0),
        'total_prize',
          coalesce((v_item->>'start_prize')::numeric, 0)
          + coalesce((v_item->>'mid_prize')::numeric, 0),
        'start_pct',
          CASE WHEN v_start_total > 0
            THEN round(
              100.0 * coalesce((v_item->>'start_progress')::numeric, 0) / v_start_total
            )
            ELSE 0
          END,
        'mid_pct',
          CASE WHEN v_mid_total > 0
            THEN round(
              100.0 * coalesce((v_item->>'mid_progress')::numeric, 0) / v_mid_total
            )
            ELSE 0
          END,
        'overall_pct',
          CASE WHEN (v_start_total + v_mid_total) > 0
            THEN round(
              100.0 * (
                coalesce((v_item->>'start_progress')::numeric, 0)
                + coalesce((v_item->>'mid_progress')::numeric, 0)
              ) / (v_start_total + v_mid_total)
            )
            ELSE 0
          END
      )
    );
  END LOOP;

  SELECT coalesce(jsonb_agg(x ORDER BY
    (x->>'start_completed')::int DESC,
    (x->>'start_progress')::numeric DESC,
    x->>'club_name'
  ), '[]'::jsonb)
  INTO v_start
  FROM jsonb_array_elements(v_rows) x
  WHERE v_start_total > 0;

  SELECT coalesce(jsonb_agg(x ORDER BY
    (x->>'mid_completed')::int DESC,
    (x->>'mid_progress')::numeric DESC,
    x->>'club_name'
  ), '[]'::jsonb)
  INTO v_mid
  FROM jsonb_array_elements(v_rows) x
  WHERE v_mid_total > 0;

  SELECT coalesce(jsonb_agg(x ORDER BY
    (x->>'total_completed')::int DESC,
    (x->>'total_progress')::numeric DESC,
    x->>'club_name'
  ), '[]'::jsonb)
  INTO v_overall
  FROM jsonb_array_elements(v_rows) x;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'start_total', v_start_total,
    'mid_total', v_mid_total,
    'start', coalesce(v_start, '[]'::jsonb),
    'mid', coalesce(v_mid, '[]'::jsonb),
    'overall', coalesce(v_overall, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_challenge_league_table(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_league_table(bigint) TO anon;

COMMENT ON FUNCTION public.competition_challenge_league_table(bigint) IS
  'League-table style standings for season challenges (all clubs). Ranked by completed count then progress.';
