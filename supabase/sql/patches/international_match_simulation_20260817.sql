-- =============================================================================
-- International match simulation (reuse club match_sim engine)
--
-- When match_result_simulation is ON, owners (and staff for vacant nations)
-- can Instant result / Simulate international fixtures.
-- Finalizes via international_apply_fixture_result (standings / KO / career).
--
-- Safe re-run. Requires match_result_simulation* patches + WC engine.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Month unlock for international fixtures (same calendar windows as club)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_assert_fixture_month_unlocked(
  p_fixture_id bigint
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fix public.international_fixtures;
  v_active text;
  v_unlock timestamptz;
  v_lock timestamptz;
BEGIN
  SELECT f.* INTO v_fix
  FROM public.international_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'International fixture not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fix.season_id
  ) THEN
    RETURN;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fix.season_id, now());

  IF v_active IS NOT NULL AND v_active = v_fix.gpsl_month THEN
    RETURN;
  END IF;

  SELECT unlock_at, lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_fix.season_id
    AND m.gpsl_month = v_fix.gpsl_month;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No calendar window for GPSL %',
      public.competition_gpsl_month_label(v_fix.gpsl_month);
  END IF;

  IF now() < v_unlock THEN
    RAISE EXCEPTION '% internationals unlock at % UK',
      public.competition_gpsl_month_label(v_fix.gpsl_month),
      to_char(v_unlock AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI');
  END IF;

  IF v_lock IS NOT NULL AND now() > v_lock THEN
    RAISE EXCEPTION '% internationals are locked (ended % UK)',
      public.competition_gpsl_month_label(v_fix.gpsl_month),
      to_char(v_lock AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI');
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Load XI for a nation (matchday pitch → call-ups → GPDB pool by rating)
-- Same jsonb shape as match_sim_load_club_side.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_sim_load_nation_side(p_nation_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := upper(nullif(btrim(p_nation_code), ''));
  v_rows jsonb := '[]'::jsonb;
  v_n int := 0;
  v_name text;
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'Nation code required';
  END IF;

  SELECT n.name INTO v_name
  FROM public.international_nations n
  WHERE n.code = v_nation;

  -- 1) Saved matchday pitch XI
  IF to_regclass('public.international_matchday_squad_player') IS NOT NULL THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', sp.player_id,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(sp.pitch_slot, p."Position"),
          'pitch_slot', sp.pitch_slot,
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
    FROM public.international_matchday_squad_player sp
    JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
    WHERE sp.nation_code = v_nation
      AND sp.slot_kind = 'pitch';

    v_n := jsonb_array_length(v_rows);
  END IF;

  -- 2) Active call-ups by rating
  IF v_n < 11 AND to_regclass('public.international_squad_callups') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(x.obj ORDER BY x.ord), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', c.player_id,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL, p."Position"),
          'pitch_slot', NULL,
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        ) AS obj,
        row_number() OVER (
          ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
        ) AS ord
      FROM public.international_squad_callups c
      JOIN public."Players" p ON p."Konami_ID"::text = c.player_id
      WHERE c.nation_code = v_nation
        AND c.is_active = true
      LIMIT 11
    ) x;

    v_n := jsonb_array_length(v_rows);
  END IF;

  -- 3) GPDB pool for this nationality (vacant / no call-ups)
  IF v_n < 11 THEN
    SELECT coalesce(jsonb_agg(x.obj ORDER BY x.ord), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL, p."Position"),
          'pitch_slot', NULL,
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
      WHERE public.international_normalize_nation_label(p."Nation")
              = public.international_normalize_nation_label(coalesce(v_name, v_nation))
         OR public.international_normalize_nation_label(p."Nation") = v_nation
      LIMIT 11
    ) x;

    v_n := jsonb_array_length(v_rows);
  END IF;

  IF v_n < 11 THEN
    RAISE EXCEPTION
      'Nation % needs at least 11 players to simulate (have %). Call up a squad or refresh the GPDB pool.',
      v_nation, v_n;
  END IF;

  -- Optional bench from matchday (top 5 as subbed_on)
  IF to_regclass('public.international_matchday_squad_player') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.international_matchday_squad_player sp
       WHERE sp.nation_code = v_nation AND sp.slot_kind = 'bench'
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
            public.match_sim_role_from_slot(NULL, p."Position") AS role,
            public.match_sim_is_star(
              public.match_sim_player_rating_num(p."Rating"::text, 70)
            ) AS is_star,
            row_number() OVER (
              ORDER BY sp.sort_order NULLS LAST, p."Name"
            ) AS ord
          FROM public.international_matchday_squad_player sp
          JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
          WHERE sp.nation_code = v_nation
            AND sp.slot_kind = 'bench'
          LIMIT 5
        ) b
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  END IF;

  RETURN v_rows;
END;
$function$;

-- Lightweight playback for Simulate match graphic (no club fixture row)
CREATE OR REPLACE FUNCTION public.match_sim_build_intl_playback(
  p_home_name text,
  p_away_name text,
  p_home_goals int,
  p_away_goals int,
  p_duration_sec int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
  v_dur numeric := greatest(8, least(60, coalesce(p_duration_sec, 20)))::numeric;
  v_events jsonb := '[]'::jsonb;
  v_i int;
  v_t numeric;
BEGIN
  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', 0, 'type', 'kickoff', 'side', null, 'text', 'Kick-off', 'minute', 1
  ));

  FOR v_i IN 1..greatest(coalesce(p_home_goals, 0), 0) LOOP
    v_t := round((v_dur * (0.12 + 0.7 * v_i / greatest(p_home_goals + p_away_goals, 1)))::numeric, 2);
    v_events := v_events || jsonb_build_array(jsonb_build_object(
      't', v_t, 'type', 'goal', 'side', 'home',
      'text', coalesce(p_home_name, 'Home') || ' score!', 'minute', least(90, 8 + v_i * 11)
    ));
  END LOOP;

  FOR v_i IN 1..greatest(coalesce(p_away_goals, 0), 0) LOOP
    v_t := round((v_dur * (0.18 + 0.7 * v_i / greatest(p_home_goals + p_away_goals, 1)))::numeric, 2);
    v_events := v_events || jsonb_build_array(jsonb_build_object(
      't', v_t, 'type', 'goal', 'side', 'away',
      'text', coalesce(p_away_name, 'Away') || ' score!', 'minute', least(90, 10 + v_i * 12)
    ));
  END LOOP;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', v_dur, 'type', 'fulltime', 'side', null,
    'text', format('FT %s–%s', coalesce(p_home_goals, 0), coalesce(p_away_goals, 0)),
    'minute', 90
  ));

  RETURN jsonb_build_object(
    'duration_sec', v_dur,
    'events', v_events,
    'home_name', p_home_name,
    'away_name', p_away_name
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Main RPC — same toggle as club sim (match_result_simulation_enabled)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_simulate_fixture_result(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fix public.international_fixtures;
  v_my text;
  v_home_club text;
  v_away_club text;
  v_staff boolean;
  v_settings jsonb;
  v_home jsonb;
  v_away jsonb;
  v_home_str numeric;
  v_away_str numeric;
  v_diff numeric;
  v_home_star_json jsonb;
  v_away_star_json jsonb;
  v_home_star_def numeric;
  v_home_star_create numeric;
  v_home_star_fin numeric;
  v_away_star_def numeric;
  v_away_star_create numeric;
  v_away_star_fin numeric;
  v_home_star_pwr numeric;
  v_away_star_pwr numeric;
  v_outcome text;
  v_score int[];
  v_hg int;
  v_ag int;
  v_et_h smallint := NULL;
  v_et_a smallint := NULL;
  v_pen_h smallint := NULL;
  v_pen_a smallint := NULL;
  v_home_won boolean;
  v_away_won boolean;
  v_draw boolean;
  v_motm_home boolean;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_all_stats jsonb;
  v_playback jsonb;
  v_playback_sec int;
  v_home_name text;
  v_away_name text;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match simulation is turned off (Admin → Match simulation settings)';
  END IF;

  SELECT f.* INTO v_fix
  FROM public.international_fixtures f
  WHERE f.id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'International fixture not found';
  END IF;

  IF v_fix.played THEN
    RAISE EXCEPTION 'Fixture already played';
  END IF;

  v_my := public.international_my_nation_code();
  v_home_club := public.international_club_for_nation(v_fix.home_nation);
  v_away_club := public.international_club_for_nation(v_fix.away_nation);
  v_staff := public.is_gpsl_admin();
  IF NOT v_staff AND to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL THEN
    v_staff := public.is_gpsl_admin_or_mod();
  END IF;

  IF NOT (
    v_staff
    OR (v_my IS NOT NULL AND v_my IN (v_fix.home_nation, v_fix.away_nation))
  ) THEN
    RAISE EXCEPTION 'Only a nation owner (or staff) can simulate this fixture';
  END IF;

  -- Vacant vs vacant: staff only
  IF v_home_club IS NULL AND v_away_club IS NULL AND NOT v_staff THEN
    RAISE EXCEPTION 'Staff only can simulate vacant vs vacant internationals';
  END IF;

  PERFORM public.international_assert_fixture_month_unlocked(p_fixture_id);

  v_settings := public.match_sim_settings();
  v_playback_sec := greatest(8, least(60, coalesce((v_settings->>'playback_seconds')::int, 20)));

  v_home := public.match_sim_load_nation_side(v_fix.home_nation);
  v_away := public.match_sim_load_nation_side(v_fix.away_nation);

  v_home_str := public.match_sim_side_strength(v_home);
  v_away_str := public.match_sim_side_strength(v_away);
  v_diff := v_home_str - v_away_str;

  v_home_star_json := public.match_sim_side_star_powers(v_home);
  v_away_star_json := public.match_sim_side_star_powers(v_away);
  v_home_star_def := coalesce((v_home_star_json->>'def')::numeric, 0);
  v_home_star_create := coalesce((v_home_star_json->>'create')::numeric, 0);
  v_home_star_fin := coalesce((v_home_star_json->>'fin')::numeric, 0);
  v_away_star_def := coalesce((v_away_star_json->>'def')::numeric, 0);
  v_away_star_create := coalesce((v_away_star_json->>'create')::numeric, 0);
  v_away_star_fin := coalesce((v_away_star_json->>'fin')::numeric, 0);
  v_home_star_pwr := coalesce((v_home_star_json->>'total')::numeric, 0);
  v_away_star_pwr := coalesce((v_away_star_json->>'total')::numeric, 0);

  v_outcome := public.match_sim_pick_outcome_with_stars(
    v_home_str, v_away_str, v_home_star_pwr, v_away_star_pwr
  );
  v_score := public.match_sim_sample_goals(
    v_outcome,
    v_diff,
    public.match_sim_side_attack(v_home),
    public.match_sim_side_attack(v_away),
    public.match_sim_side_defence(v_home),
    public.match_sim_side_defence(v_away),
    v_home_star_def,
    v_away_star_def,
    v_home_star_create,
    v_away_star_create,
    v_home_star_fin,
    v_away_star_fin
  );
  v_hg := v_score[1];
  v_ag := v_score[2];

  -- Knockout cannot finish level after 90 — force a winner (same idea as dry-run)
  IF v_fix.phase = 'knockout' AND v_hg = v_ag THEN
    IF random() < 0.5 THEN
      v_et_h := (v_hg + 1)::smallint;
      v_et_a := v_ag::smallint;
    ELSE
      v_et_h := v_hg::smallint;
      v_et_a := (v_ag + 1)::smallint;
    END IF;
  END IF;

  v_home_won := CASE
    WHEN v_et_h IS NOT NULL THEN v_et_h > v_et_a
    ELSE v_hg > v_ag
  END;
  v_away_won := CASE
    WHEN v_et_h IS NOT NULL THEN v_et_a > v_et_h
    ELSE v_ag > v_hg
  END;
  v_draw := NOT v_home_won AND NOT v_away_won;
  v_motm_home := CASE
    WHEN v_home_won THEN true
    WHEN v_away_won THEN false
    ELSE random() < 0.5
  END;

  v_home_stats := public.match_sim_build_club_stats(
    v_home, v_hg, v_ag, v_home_won, v_draw, v_motm_home
  );
  v_away_stats := public.match_sim_build_club_stats(
    v_away, v_ag, v_hg, v_away_won, v_draw, NOT v_motm_home
  );
  v_all_stats := coalesce(v_home_stats, '[]'::jsonb) || coalesce(v_away_stats, '[]'::jsonb);

  -- Drop pending owner submissions (sim is final)
  UPDATE public.international_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by match simulation',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  PERFORM public.international_apply_fixture_result(
    p_fixture_id,
    v_hg::smallint,
    v_ag::smallint,
    v_all_stats,
    v_et_h,
    v_et_a,
    v_pen_h,
    v_pen_a
  );

  SELECT hn.name, an.name
  INTO v_home_name, v_away_name
  FROM public.international_nations hn
  CROSS JOIN public.international_nations an
  WHERE hn.code = v_fix.home_nation
    AND an.code = v_fix.away_nation;

  v_playback := public.match_sim_build_intl_playback(
    coalesce(v_home_name, v_fix.home_nation),
    coalesce(v_away_name, v_fix.away_nation),
    v_hg,
    v_ag,
    v_playback_sec
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home_goals', v_hg,
    'away_goals', v_ag,
    'home_goals_et', v_et_h,
    'away_goals_et', v_et_a,
    'home_name', coalesce(v_home_name, v_fix.home_nation),
    'away_name', coalesce(v_away_name, v_fix.away_nation),
    'home_nation', v_fix.home_nation,
    'away_nation', v_fix.away_nation,
    'outcome', v_outcome,
    'home_strength', v_home_str,
    'away_strength', v_away_str,
    'playback', v_playback,
    'simulated', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_assert_fixture_month_unlocked(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_load_nation_side(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_build_intl_playback(text, text, int, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
