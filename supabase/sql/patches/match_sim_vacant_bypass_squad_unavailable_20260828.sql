-- =============================================================================
-- Match sim: vacant clubs bypass squad-size + players-out gates
--
-- Owned clubs keep normal rules (matchday XI, injured/suspended blocked,
-- exactly 11 starters, holiday early min squad).
--
-- Vacant clubs (Clubs.owner_id IS NULL):
--   • Auto-pick XI from contracted players (ignore stale matchday squad)
--   • Ignore injured/suspended when fielding / applying stats
--   • Allow fewer than 11 starters if the roster is thin
--   • Skip holiday-early squad minimum check
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_sim_club_is_vacant(p_club text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT c.owner_id IS NULL
      FROM public."Clubs" c
      WHERE c."ShortName" = btrim(p_club)
      LIMIT 1
    ),
    false
  );
$$;

GRANT EXECUTE ON FUNCTION public.match_sim_club_is_vacant(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Load side: vacant → auto XI from roster (no matchday / no unavailable filter)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_sim_load_club_side(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club);
  v_rows jsonb;
  v_n int;
  v_max_subs int := 5;
  v_vacant boolean := public.match_sim_club_is_vacant(v_club);
BEGIN
  BEGIN
    v_max_subs := greatest(
      0,
      least(5, coalesce((public.match_sim_settings()->>'max_subs_on')::int, 5))
    );
  EXCEPTION WHEN OTHERS THEN
    v_max_subs := 5;
  END;

  -- Vacant: never trust a saved matchday XI (often has injured/suspended still listed)
  IF NOT v_vacant THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', sp.player_id,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(sp.pitch_slot, NULL::text),
          'pitch_slot', sp.pitch_slot,
          'profile_pos', p."Position",
          'on_natural', public.match_sim_on_natural_position(sp.pitch_slot, p."Position"),
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        )
        ORDER BY sp.sort_order NULLS LAST, sp.pitch_slot, p."Name"
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM public.club_matchday_squad_player sp
    JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
    WHERE sp.club_short_name = v_club
      AND sp.slot_kind = 'pitch'
      AND p."Contracted_Team" = v_club;

    v_n := coalesce(jsonb_array_length(v_rows), 0);
  ELSE
    v_rows := '[]'::jsonb;
    v_n := 0;
  END IF;

  IF v_n < 11 THEN
    SELECT coalesce(
      jsonb_agg(x.obj ORDER BY x.ord),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL::text, p."Position"),
          'pitch_slot', NULL,
          'profile_pos', p."Position",
          'on_natural', true,
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        ) AS obj,
        row_number() OVER (
          ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
        ) AS ord
      FROM public."Players" p
      WHERE p."Contracted_Team" = v_club
      LIMIT 11
    ) x;
    v_n := coalesce(jsonb_array_length(v_rows), 0);
  END IF;

  IF v_n < 11 THEN
    IF v_vacant AND v_n >= 1 THEN
      -- Thin vacant roster: proceed with whoever is contracted
      NULL;
    ELSE
      RAISE EXCEPTION
        'Club % needs at least 11 contracted players to simulate (have %)',
        v_club, v_n;
    END IF;
  END IF;

  IF v_max_subs <= 0 THEN
    RETURN v_rows;
  END IF;

  IF NOT v_vacant AND EXISTS (
    SELECT 1 FROM public.club_matchday_squad_player sp
    WHERE sp.club_short_name = v_club AND sp.slot_kind = 'bench'
  ) THEN
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', b.player_id,
            'name', b.name,
            'rating', b.rating,
            'role', b.role,
            'pitch_slot', NULL,
            'profile_pos', b.profile_pos,
            'on_natural', true,
            'started', false,
            'subbed_on', true,
            'is_star', b.is_star
          )
          ORDER BY b.ord
        )
        FROM (
          SELECT
            sp.player_id,
            p."Name" AS name,
            public.match_sim_player_rating_num(p."Rating"::text, 70) AS rating,
            public.match_sim_role_from_slot(NULL::text, p."Position") AS role,
            p."Position" AS profile_pos,
            public.match_sim_is_star(
              public.match_sim_player_rating_num(p."Rating"::text, 70)
            ) AS is_star,
            row_number() OVER (
              ORDER BY sp.sort_order NULLS LAST, p."Name"
            ) AS ord
          FROM public.club_matchday_squad_player sp
          JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
          WHERE sp.club_short_name = v_club
            AND sp.slot_kind = 'bench'
            AND p."Contracted_Team" = v_club
        ) b
        WHERE b.ord <= v_max_subs
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  ELSE
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(y.obj ORDER BY y.ord)
        FROM (
          SELECT
            jsonb_build_object(
              'player_id', p."Konami_ID"::text,
              'name', p."Name",
              'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
              'role', public.match_sim_role_from_slot(NULL::text, p."Position"),
              'pitch_slot', NULL,
              'profile_pos', p."Position",
              'on_natural', true,
              'started', false,
              'subbed_on', true,
              'is_star', public.match_sim_is_star(
                public.match_sim_player_rating_num(p."Rating"::text, 70)
              )
            ) AS obj,
            row_number() OVER (
              ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
            ) AS ord
          FROM public."Players" p
          WHERE p."Contracted_Team" = v_club
            AND NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements(v_rows) e
              WHERE e->>'player_id' = p."Konami_ID"::text
            )
        ) y
        WHERE y.ord <= v_max_subs
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  END IF;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_load_club_side(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Holiday early: ignore vacant clubs for min-squad gate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_assert_holiday_early_squad_ready(
  p_fixture_id bigint
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_shortfall int;
  v_away_shortfall int;
  v_min int := public.squad_minimum_size();
BEGIN
  IF NOT public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF NOT public.match_sim_club_is_vacant(v_fixture.home_club_short_name) THEN
    v_home_shortfall := public.club_squad_minimum_shortfall(v_fixture.home_club_short_name);
    IF v_home_shortfall > 0 THEN
      RAISE EXCEPTION
        'Holiday early play requires a full squad (min %). % is short by %.',
        v_min,
        v_fixture.home_club_short_name,
        v_home_shortfall;
    END IF;
  END IF;

  IF NOT public.match_sim_club_is_vacant(v_fixture.away_club_short_name) THEN
    v_away_shortfall := public.club_squad_minimum_shortfall(v_fixture.away_club_short_name);
    IF v_away_shortfall > 0 THEN
      RAISE EXCEPTION
        'Holiday early play requires a full squad (min %). % is short by %.',
        v_min,
        v_fixture.away_club_short_name,
        v_away_shortfall;
    END IF;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_assert_holiday_early_squad_ready(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Apply stats: vacant may field 1–11 starters
-- ---------------------------------------------------------------------------
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
  v_vacant boolean := public.match_sim_club_is_vacant(p_club);
BEGIN
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
    v_goals := coalesce((v_item ->> 'goals')::int, 0);
    v_assists := coalesce((v_item ->> 'assists')::int, 0);
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
       AND v_goals = 0 AND v_assists = 0 AND v_rating IS NULL AND NOT v_potm
       AND NOT v_yellow AND NOT v_red THEN
      CONTINUE;
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
      appeared, started, subbed_on, goals, assists, rating, is_player_of_match,
      yellow_card, red_card
    )
    VALUES (
      p_fixture_id, p_season_id, p_club, v_player_id,
      v_appeared, v_started, v_subbed, v_goals, v_assists, v_rating, v_potm,
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

  IF v_team_goals > 0 AND v_team_goals <> p_expected_goals THEN
    RAISE EXCEPTION 'Player goals (%) must match your team score (%)', v_team_goals, p_expected_goals;
  END IF;

  PERFORM public.competition_process_match_discipline(
    p_fixture_id, p_season_id, p_club, p_player_stats
  );

  PERFORM public.competition_serve_suspensions_for_fixture(p_fixture_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_apply_club_player_stats(bigint, bigint, text, jsonb, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- Discipline: vacant clubs may field injured/suspended for sim
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_process_match_discipline(
  p_fixture_id bigint,
  p_season_id bigint,
  p_club text,
  p_player_stats jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_player_id text;
  v_appeared boolean;
  v_started boolean;
  v_subbed boolean;
  v_yellow boolean;
  v_red boolean;
  v_y_count int;
  v_prev_count int;
  v_threshold int;
  v_block text;
  v_vacant boolean := public.match_sim_club_is_vacant(p_club);
BEGIN
  FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(p_player_stats, '[]'::jsonb))
  LOOP
    v_player_id := trim(both '"' FROM (v_item ->> 'player_id'));
    IF v_player_id IS NULL OR v_player_id = '' THEN
      CONTINUE;
    END IF;

    v_started := coalesce((v_item ->> 'started')::boolean, false);
    v_subbed := coalesce((v_item ->> 'subbed_on')::boolean, false);
    IF v_item ? 'started' OR v_item ? 'subbed_on' THEN
      v_appeared := v_started OR v_subbed;
    ELSE
      v_appeared := coalesce((v_item ->> 'appeared')::boolean, false);
    END IF;

    v_yellow := coalesce((v_item ->> 'yellow_card')::boolean, false)
      OR coalesce((v_item ->> 'yellow')::boolean, false);
    v_red := coalesce((v_item ->> 'red_card')::boolean, false)
      OR coalesce((v_item ->> 'red')::boolean, false);

    IF (v_yellow OR v_red) AND NOT v_appeared THEN
      RAISE EXCEPTION 'Player % must have appeared to receive a card', v_player_id;
    END IF;

    IF v_appeared AND NOT v_vacant THEN
      v_block := public.competition_player_unavailable_for_fixture(p_fixture_id, v_player_id);
      IF v_block IS NOT NULL THEN
        RAISE EXCEPTION 'Player % is unavailable for this match (%)', v_player_id, v_block;
      END IF;
    END IF;
  END LOOP;

  FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(p_player_stats, '[]'::jsonb))
  LOOP
    v_player_id := trim(both '"' FROM (v_item ->> 'player_id'));
    IF v_player_id IS NULL OR v_player_id = '' THEN
      CONTINUE;
    END IF;

    v_yellow := coalesce((v_item ->> 'yellow_card')::boolean, false)
      OR coalesce((v_item ->> 'yellow')::boolean, false);
    v_red := coalesce((v_item ->> 'red_card')::boolean, false)
      OR coalesce((v_item ->> 'red')::boolean, false);

    UPDATE public.competition_match_player_stats
    SET yellow_card = v_yellow,
        red_card = v_red
    WHERE fixture_id = p_fixture_id
      AND club_short_name = p_club
      AND player_id = v_player_id;
  END LOOP;

  FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(p_player_stats, '[]'::jsonb))
  LOOP
    v_player_id := trim(both '"' FROM (v_item ->> 'player_id'));
    IF v_player_id IS NULL OR v_player_id = '' THEN
      CONTINUE;
    END IF;

    v_yellow := coalesce((v_item ->> 'yellow_card')::boolean, false)
      OR coalesce((v_item ->> 'yellow')::boolean, false);
    v_red := coalesce((v_item ->> 'red_card')::boolean, false)
      OR coalesce((v_item ->> 'red')::boolean, false);

    IF v_red THEN
      PERFORM public.competition_issue_player_suspension(
        p_season_id, v_player_id, p_club, 'red_card', p_fixture_id, NULL, 2
      );
    END IF;

    IF v_yellow THEN
      SELECT count(*)::int
      INTO v_y_count
      FROM public.competition_match_player_stats m
      WHERE m.season_id = p_season_id
        AND m.player_id = v_player_id
        AND m.yellow_card = true;

      v_prev_count := greatest(v_y_count - 1, 0);
      IF (v_y_count / 8) > (v_prev_count / 8) THEN
        v_threshold := (v_y_count / 8) * 8;
        PERFORM public.competition_issue_player_suspension(
          p_season_id, v_player_id, p_club, 'yellow_accumulation',
          p_fixture_id, v_threshold, 2
        );
      END IF;
    END IF;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_match_discipline(bigint, bigint, text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
