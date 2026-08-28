-- =============================================================================
-- Match sim: yellow_per_match is a MAX, not a fixed count
-- Actual yellows rolled uniformly in 0..max each simulated match.
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_sim_assign_match_cards(
  p_fixture_id bigint,
  p_yellow_count int DEFAULT 3,
  p_red_chance_pct numeric DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture record;
  v_y_max int := greatest(0, least(22, coalesce(p_yellow_count, 3)));
  -- Roll 0..max inclusive (setting = ceiling, not guaranteed count)
  v_y_here int := floor(random() * (v_y_max + 1))::int;
  v_r_here int := 0;
  v_i int;
  v_club text;
  v_player text;
  v_pair record;
  v_stats jsonb;
  v_assigned jsonb := '[]'::jsonb;
  v_chance numeric := greatest(0, least(100, coalesce(p_red_chance_pct, 5)));
BEGIN
  SELECT
    f.id,
    f.season_id,
    f.gpsl_month,
    f.competition_type,
    f.status,
    f.home_club_short_name,
    f.away_club_short_name
  INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  IF v_fixture.status <> 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_played');
  END IF;

  -- Exactly one red with the configured chance (e.g. 5% → at most one red).
  IF random() * 100.0 < v_chance THEN
    v_r_here := 1;
  END IF;

  FOR v_i IN 1..v_y_here LOOP
    SELECT m.club_short_name, m.player_id
    INTO v_club, v_player
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
      )
      AND NOT coalesce(m.yellow_card, false)
      AND NOT coalesce(m.red_card, false)
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_player IS NULL;

    UPDATE public.competition_match_player_stats
    SET yellow_card = true
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_club
      AND player_id = v_player;

    v_assigned := v_assigned || jsonb_build_array(
      jsonb_build_object(
        'kind', 'yellow',
        'club_short_name', v_club,
        'player_id', v_player
      )
    );
  END LOOP;

  FOR v_i IN 1..v_r_here LOOP
    SELECT m.club_short_name, m.player_id
    INTO v_club, v_player
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
      )
      AND NOT coalesce(m.red_card, false)
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_player IS NULL;

    UPDATE public.competition_match_player_stats
    SET red_card = true
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_club
      AND player_id = v_player;

    v_assigned := v_assigned || jsonb_build_array(
      jsonb_build_object(
        'kind', 'red',
        'club_short_name', v_club,
        'player_id', v_player
      )
    );
  END LOOP;

  -- Re-run discipline so suspensions / accumulators match live Matchday submit.
  FOR v_pair IN
    SELECT DISTINCT club_short_name
    FROM public.competition_match_player_stats
    WHERE fixture_id = p_fixture_id
      AND (coalesce(yellow_card, false) OR coalesce(red_card, false))
  LOOP
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', m.player_id,
          'started', coalesce(m.started, false),
          'subbed_on', coalesce(m.subbed_on, false),
          'appeared', coalesce(m.appeared, false),
          'goals', m.goals,
          'assists', m.assists,
          'rating', m.rating,
          'potm', coalesce(m.is_player_of_match, false),
          'yellow_card', coalesce(m.yellow_card, false),
          'red_card', coalesce(m.red_card, false)
        )
      ),
      '[]'::jsonb
    )
    INTO v_stats
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = v_pair.club_short_name;

    IF to_regprocedure(
      'public.competition_process_match_discipline(bigint, bigint, text, jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.competition_process_match_discipline(
        p_fixture_id,
        v_fixture.season_id,
        v_pair.club_short_name,
        v_stats
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'mode', 'per_match',
    'yellow_per_match_max', v_y_max,
    'yellows_rolled', v_y_here,
    'red_chance_pct', v_chance,
    'yellows_assigned', (
      SELECT count(*)::int FROM jsonb_array_elements(v_assigned) e WHERE e->>'kind' = 'yellow'
    ),
    'reds_assigned', (
      SELECT count(*)::int FROM jsonb_array_elements(v_assigned) e WHERE e->>'kind' = 'red'
    ),
    'assignments', v_assigned
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_assign_match_cards(bigint, int, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
