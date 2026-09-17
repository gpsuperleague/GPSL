-- Matchday: optional rating / MOTM; blank rating on starters & introduced subs → 3.0
-- Apply in Supabase SQL Editor after deploying site changes to matchday.js / matchday.html.

CREATE OR REPLACE FUNCTION public.competition_apply_club_player_stats(
  p_fixture_id bigint,
  p_season_id bigint,
  p_club text,
  p_player_stats jsonb,
  p_expected_goals int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_player_id text;
  v_goals int;
  v_own_goals int;
  v_assists int;
  v_rating numeric;
  v_potm boolean;
  v_started boolean;
  v_subbed boolean;
  v_appeared boolean;
  v_yellow boolean;
  v_red boolean;
  v_team_goals int := 0;
  v_potm_count int := 0;
  v_started_count int := 0;
  v_subbed_count int := 0;
  v_vacant boolean := false;
BEGIN
  BEGIN
    v_vacant := public.match_sim_club_is_vacant(p_club);
  EXCEPTION WHEN OTHERS THEN
    v_vacant := false;
  END;

  IF p_player_stats IS NULL OR jsonb_typeof(p_player_stats) <> 'array' THEN
    RAISE EXCEPTION 'player_stats must be a JSON array';
  END IF;

  IF jsonb_array_length(p_player_stats) = 0 THEN
    RAISE EXCEPTION 'Squad match stats are required';
  END IF;

  DELETE FROM public.competition_match_player_stats
  WHERE fixture_id = p_fixture_id
    AND club_short_name = p_club;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_player_stats)
  LOOP
    v_player_id := trim(both '"' FROM (v_item ->> 'player_id'));
    v_goals := greatest(coalesce((v_item ->> 'goals')::int, 0), 0);
    v_own_goals := greatest(coalesce((v_item ->> 'own_goals')::int, 0), 0);
    v_assists := greatest(coalesce((v_item ->> 'assists')::int, 0), 0);
    v_rating := nullif(v_item ->> 'rating', '')::numeric;
    v_potm := coalesce((v_item ->> 'potm')::boolean, false);
    v_started := coalesce((v_item ->> 'started')::boolean, false);
    v_subbed := coalesce((v_item ->> 'subbed_on')::boolean, false);
    v_yellow := coalesce((v_item ->> 'yellow_card')::boolean, false)
      OR coalesce((v_item ->> 'yellow')::boolean, false);
    v_red := coalesce((v_item ->> 'red_card')::boolean, false)
      OR coalesce((v_item ->> 'red')::boolean, false);

    IF v_item ? 'started' OR v_item ? 'subbed_on' THEN
      v_appeared := v_started OR v_subbed;
    ELSE
      v_appeared := coalesce((v_item ->> 'appeared')::boolean, false);
    END IF;

    IF v_started AND v_subbed THEN
      RAISE EXCEPTION 'Player % cannot be both started and subbed on', v_player_id;
    END IF;

    IF v_player_id IS NULL OR v_player_id = '' THEN
      CONTINUE;
    END IF;

    IF NOT v_appeared
       AND v_goals = 0 AND v_own_goals = 0 AND v_assists = 0
       AND v_rating IS NULL AND NOT v_potm
       AND NOT v_yellow AND NOT v_red THEN
      CONTINUE;
    END IF;

    -- Starters / introduced subs without a rating get an automatic 3.0
    IF v_appeared AND v_rating IS NULL THEN
      v_rating := 3.0;
    END IF;

    IF v_rating IS NOT NULL AND (v_rating < 0.1 OR v_rating > 10) THEN
      RAISE EXCEPTION 'Ratings must be between 0.1 and 10 (player %)', v_player_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = v_player_id
        AND p."Contracted_Team" = p_club
    ) THEN
      RAISE EXCEPTION 'Player % is not on your club roster', v_player_id;
    END IF;

    IF v_potm THEN
      v_potm_count := v_potm_count + 1;
    END IF;

    IF v_started THEN
      v_started_count := v_started_count + 1;
    END IF;
    IF v_subbed THEN
      v_subbed_count := v_subbed_count + 1;
    END IF;

    v_team_goals := v_team_goals + v_goals;

    INSERT INTO public.competition_match_player_stats (
      fixture_id, season_id, club_short_name, player_id,
      appeared, started, subbed_on, goals, own_goals, assists, rating, is_player_of_match,
      yellow_card, red_card
    )
    VALUES (
      p_fixture_id, p_season_id, p_club, v_player_id,
      v_appeared, v_started, v_subbed, v_goals, v_own_goals, v_assists, v_rating, v_potm,
      v_yellow, v_red
    );
  END LOOP;

  IF v_vacant THEN
    IF v_started_count < 1 OR v_started_count > 11 THEN
      RAISE EXCEPTION
        'Vacant club % must start between 1 and 11 players (currently %)',
        p_club, v_started_count;
    END IF;
  ELSIF v_started_count <> 11 THEN
    RAISE EXCEPTION 'Exactly 11 players must be marked as started (currently %)', v_started_count;
  END IF;

  IF v_subbed_count > 5 THEN
    RAISE EXCEPTION 'Maximum 5 players can be subbed on (currently %)', v_subbed_count;
  END IF;

  IF v_potm_count > 1 THEN
    RAISE EXCEPTION 'Only one player of the match allowed';
  END IF;

  -- Goals your players scored cannot exceed the team score.
  -- Shortfall is allowed (opponent own goals credited on the scoreline).
  IF v_team_goals > coalesce(p_expected_goals, 0) THEN
    RAISE EXCEPTION
      'Player goals (%) cannot exceed your team score (%). Opponent own goals are not entered on your goals column.',
      v_team_goals, p_expected_goals;
  END IF;

  IF to_regprocedure('public.competition_process_match_discipline(bigint,bigint,text,jsonb)') IS NOT NULL THEN
    PERFORM public.competition_process_match_discipline(
      p_fixture_id, p_season_id, p_club, p_player_stats
    );
  END IF;

  IF to_regprocedure('public.competition_serve_suspensions_for_fixture(bigint)') IS NOT NULL THEN
    PERFORM public.competition_serve_suspensions_for_fixture(p_fixture_id);
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_apply_club_player_stats(bigint, bigint, text, jsonb, int) TO authenticated;
