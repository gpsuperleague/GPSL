-- =============================================================================
-- Fix: Archive Season Stats & Awards — statement timeout
--
-- Symptom (PostgREST 500):
--   canceling statement due to statement timeout
--   RPC: competition_admin_archive_season_with_inbox
--
-- Cause:
--   1) Player archive looped every player/club and called
--      competition_aggregate_player_season_row (each re-scans match stats +
--      clean sheets). That alone can exceed the API statement_timeout.
--   2) with_inbox then ran owner inbox + underperformance in the SAME
--      transaction, so one timeout rolled everything back.
--
-- Fix:
--   1) Raise local statement_timeout for archive work (5 minutes).
--   2) Set-based player season archive (one aggregation pass).
--   3) Split post-archive work into competition_admin_archive_season_followup
--      (own RPC / own timeout). Admin UI calls archive then followup.
--   4) with_inbox still works but also raises timeout (back-compat).
--
-- Run in Supabase SQL Editor, then retry Archive Season Stats & Awards.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_archive_season(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons%rowtype;
  v_row record;
  v_cup record;
  v_max_round int;
  v_winner text;
  v_runner text;
  v_fix_id bigint;
  v_awards jsonb;
  v_clubs int := 0;
  v_players int := 0;
  v_cups int := 0;
  v_finance int := 0;
BEGIN
  -- Heavy admin archive — allow up to 5 minutes for this transaction
  PERFORM set_config('statement_timeout', '300s', true);

  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT * INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    SELECT * INTO v_season FROM public.competition_seasons WHERE id = p_season_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.competition_standings_public s
    WHERE s.season_id = v_season.id
    ORDER BY s.division, s.table_position
  LOOP
    INSERT INTO public.competition_club_season_archive (
      club_short_name, season_label, division, final_position,
      season_id, mp, won, drawn, lost, gf, ga, gd, pts
    )
    VALUES (
      v_row.club_short_name,
      v_season.label,
      v_row.division,
      v_row.table_position::smallint,
      v_season.id,
      v_row.mp::smallint,
      v_row.w::smallint,
      v_row.d::smallint,
      v_row.l::smallint,
      v_row.gf::smallint,
      v_row.ga::smallint,
      v_row.gd::smallint,
      v_row.pts::smallint
    )
    ON CONFLICT (club_short_name, season_label)
    DO UPDATE SET
      division = excluded.division,
      final_position = excluded.final_position,
      season_id = excluded.season_id,
      mp = excluded.mp,
      won = excluded.won,
      drawn = excluded.drawn,
      lost = excluded.lost,
      gf = excluded.gf,
      ga = excluded.ga,
      gd = excluded.gd,
      pts = excluded.pts;

    v_clubs := v_clubs + 1;
  END LOOP;

  FOR v_cup IN
    SELECT unnest(ARRAY['super8','plate','shield','bowl','league_cup']) AS cup_code
  LOOP
    SELECT max(n.round_no) INTO v_max_round
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_season.id AND n.cup_code = v_cup.cup_code;

    IF v_max_round IS NULL THEN
      CONTINUE;
    END IF;

    SELECT n.winner_club_short_name, n.fixture_id
    INTO v_winner, v_fix_id
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_season.id
      AND n.cup_code = v_cup.cup_code
      AND n.round_no = v_max_round
      AND n.winner_club_short_name IS NOT NULL
    ORDER BY n.match_no
    LIMIT 1;

    IF v_winner IS NULL THEN
      CONTINUE;
    END IF;

    SELECT CASE
      WHEN f.home_club_short_name = v_winner THEN f.away_club_short_name
      ELSE f.home_club_short_name
    END
    INTO v_runner
    FROM public.competition_fixtures f
    WHERE f.id = v_fix_id;

    INSERT INTO public.competition_cup_season_winner (
      season_id, season_label, cup_code,
      winner_club_short_name, runner_up_club_short_name, final_fixture_id
    )
    VALUES (
      v_season.id, v_season.label, v_cup.cup_code,
      v_winner, v_runner, v_fix_id
    )
    ON CONFLICT (season_id, cup_code)
    DO UPDATE SET
      winner_club_short_name = excluded.winner_club_short_name,
      runner_up_club_short_name = excluded.runner_up_club_short_name,
      final_fixture_id = excluded.final_fixture_id,
      archived_at = now();

    v_cups := v_cups + 1;
  END LOOP;

  -- Set-based player archive (replaces per-player aggregate loop)
  WITH base AS (
    SELECT
      m.player_id,
      m.club_short_name,
      count(*) FILTER (WHERE m.appeared)::int AS appearances,
      count(*) FILTER (WHERE m.started)::int AS starts,
      coalesce(sum(m.goals), 0)::int AS goals,
      coalesce(sum(m.assists), 0)::int AS assists,
      round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
      count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE m.season_id = v_season.id
      AND f.status = 'played'
    GROUP BY m.player_id, m.club_short_name
    HAVING count(*) FILTER (WHERE m.appeared) > 0
  ),
  clean AS (
    SELECT
      m.player_id,
      m.club_short_name,
      count(*)::int AS clean_sheets
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
    WHERE m.season_id = v_season.id
      AND m.started = true
      AND f.status = 'played'
      AND public.competition_player_stat_role(p."Position") IN ('goalkeeper', 'defender')
      AND CASE
            WHEN f.home_club_short_name = m.club_short_name THEN coalesce(f.away_goals, 0)
            ELSE coalesce(f.home_goals, 0)
          END = 0
    GROUP BY m.player_id, m.club_short_name
  ),
  enriched AS (
    SELECT
      b.player_id,
      b.club_short_name,
      ccs.division,
      p."Position" AS player_position,
      public.competition_player_stat_role(p."Position") AS stat_role,
      b.appearances,
      b.starts,
      b.goals,
      b.assists,
      b.avg_rating,
      b.potm_awards,
      coalesce(c.clean_sheets, 0) AS clean_sheets,
      public.competition_player_ballon_points(
        b.appearances,
        b.goals,
        b.assists,
        b.avg_rating,
        b.potm_awards,
        coalesce(c.clean_sheets, 0),
        public.competition_player_stat_role(p."Position")
      ) AS ballon_points
    FROM base b
    LEFT JOIN clean c
      ON c.player_id = b.player_id AND c.club_short_name = b.club_short_name
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = b.player_id
    LEFT JOIN public.competition_club_seasons ccs
      ON ccs.season_id = v_season.id AND ccs.club_short_name = b.club_short_name
  ),
  upserted AS (
    INSERT INTO public.competition_player_season_archive (
      season_id, season_label, player_id, club_short_name, division,
      player_position, stat_role,
      appearances, starts, goals, assists, avg_rating, potm_awards,
      clean_sheets, ballon_points
    )
    SELECT
      v_season.id,
      v_season.label,
      e.player_id,
      e.club_short_name,
      e.division,
      e.player_position,
      e.stat_role,
      e.appearances,
      e.starts,
      e.goals,
      e.assists,
      e.avg_rating,
      e.potm_awards,
      e.clean_sheets,
      e.ballon_points
    FROM enriched e
    ON CONFLICT (season_id, player_id, club_short_name)
    DO UPDATE SET
      division = excluded.division,
      player_position = excluded.player_position,
      stat_role = excluded.stat_role,
      appearances = excluded.appearances,
      starts = excluded.starts,
      goals = excluded.goals,
      assists = excluded.assists,
      avg_rating = excluded.avg_rating,
      potm_awards = excluded.potm_awards,
      clean_sheets = excluded.clean_sheets,
      ballon_points = excluded.ballon_points,
      archived_at = now()
    RETURNING 1
  )
  SELECT count(*)::int INTO v_players FROM upserted;

  IF to_regprocedure('public.competition_finalize_season_player_awards(bigint,text)') IS NOT NULL THEN
    v_awards := public.competition_finalize_season_player_awards(v_season.id, v_season.label);
  ELSE
    -- Fallback: core awards only (pre-TOTS deploy)
    DELETE FROM public.competition_season_award WHERE season_id = v_season.id;

    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name,
      stat_value, detail
    )
    SELECT
      v_season.id, v_season.label, 'ballon_dor',
      a.player_id, a.club_short_name, a.ballon_points,
      jsonb_build_object(
        'goals', a.goals, 'assists', a.assists, 'potm', a.potm_awards,
        'clean_sheets', a.clean_sheets, 'avg_rating', a.avg_rating,
        'stat_role', a.stat_role
      )
    FROM public.competition_player_season_archive a
    WHERE a.season_id = v_season.id
      AND a.appearances >= 5
      AND a.ballon_points > 0
    ORDER BY a.ballon_points DESC, a.goals DESC, a.assists DESC
    LIMIT 1;

    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    )
    SELECT v_season.id, v_season.label, 'golden_boot', a.player_id, a.club_short_name, a.goals
    FROM public.competition_player_season_archive a
    WHERE a.season_id = v_season.id AND a.goals > 0
    ORDER BY a.goals DESC, a.assists DESC
    LIMIT 1;

    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    )
    SELECT v_season.id, v_season.label, 'golden_playmaker', a.player_id, a.club_short_name, a.assists
    FROM public.competition_player_season_archive a
    WHERE a.season_id = v_season.id AND a.assists > 0
    ORDER BY a.assists DESC, a.goals DESC
    LIMIT 1;

    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    )
    SELECT v_season.id, v_season.label, 'season_potm', a.player_id, a.club_short_name, a.potm_awards
    FROM public.competition_player_season_archive a
    WHERE a.season_id = v_season.id AND a.potm_awards > 0
    ORDER BY a.potm_awards DESC, a.goals DESC
    LIMIT 1;

    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    )
    SELECT v_season.id, v_season.label, 'golden_glove', a.player_id, a.club_short_name, a.clean_sheets
    FROM public.competition_player_season_archive a
    WHERE a.season_id = v_season.id
      AND a.stat_role = 'goalkeeper'
      AND a.clean_sheets > 0
    ORDER BY a.clean_sheets DESC, a.avg_rating DESC NULLS LAST
    LIMIT 1;

    v_awards := jsonb_build_object('ok', true, 'mode', 'core_fallback');
  END IF;

  IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_finance := public.competition_archive_club_finances_for_season(v_season.id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season.id,
    'season_label', v_season.label,
    'clubs_archived', v_clubs,
    'players_archived', v_players,
    'cups_archived', v_cups,
    'clubs_finance_archived', v_finance,
    'player_awards', v_awards
  );
END;
$function$;

-- Post-archive: inbox notifications + underperformance (separate timeout budget)
CREATE OR REPLACE FUNCTION public.competition_admin_archive_season_followup(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_label text;
  v_under jsonb := NULL;
  v_inbox_ok boolean := false;
BEGIN
  PERFORM set_config('statement_timeout', '300s', true);

  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT s.id, s.label
    INTO v_season_id, v_label
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  ELSE
    SELECT s.label INTO v_label
    FROM public.competition_seasons s
    WHERE s.id = v_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.owner_inbox_notify_club_season_archive(bigint,text)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_club_season_archive(
      v_season_id,
      coalesce(v_label, 'Season')
    );
    v_inbox_ok := true;
  END IF;

  IF to_regprocedure('public.club_underperformance_process_season(bigint)') IS NOT NULL THEN
    v_under := public.club_underperformance_process_season(v_season_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', v_label,
    'inbox_notified', v_inbox_ok,
    'underperformance', v_under
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_archive_season_with_inbox(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result jsonb;
  v_follow jsonb;
BEGIN
  -- Prefer separate RPCs from the admin UI; this path remains for older clients
  PERFORM set_config('statement_timeout', '300s', true);

  v_result := public.competition_admin_archive_season(p_season_id);

  BEGIN
    v_follow := public.competition_admin_archive_season_followup(
      (v_result ->> 'season_id')::bigint
    );
    v_result := v_result || jsonb_build_object('followup', v_follow);
  EXCEPTION WHEN OTHERS THEN
    v_result := v_result || jsonb_build_object(
      'followup_error', SQLERRM
    );
  END;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_archive_season(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_archive_season_followup(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_archive_season_with_inbox(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
