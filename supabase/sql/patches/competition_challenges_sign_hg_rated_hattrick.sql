-- =============================================================================
-- Season challenges — HG signing, rated signing (age/HG toggles), hat-trick MD
--
-- New stat_types:
--   transfer_sign_homegrown  — buy a player whose Nation matches the club Nation
--   transfer_sign_rated      — buy a player at or below max rating; optional
--                              max age + optional home-grown (JSON in stat_param)
--   player_hattrick_matchday — a club player scores ≥3 goals on a given matchday
--                              (stat_param = matchday number, e.g. "1" = opening day)
--
-- transfer_sign_rated.stat_param JSON example:
--   {"max_rating":65,"require_age":true,"max_age":21,"require_hg":true}
--
-- Run after competition_challenges_june_transfers.sql (and later award patches).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_challenge_config
  DROP CONSTRAINT IF EXISTS competition_challenge_config_stat_type_check;

ALTER TABLE public.competition_challenge_config
  ADD CONSTRAINT competition_challenge_config_stat_type_check
  CHECK (
    stat_type IN (
      'player_max_goals',
      'player_max_assists',
      'club_wins',
      'club_goals_for',
      'club_clean_sheets',
      'club_potm_awards',
      'transfer_sign_nation',
      'transfer_sign_homegrown',
      'transfer_sign_rated',
      'player_hattrick_matchday'
    )
  );

COMMENT ON COLUMN public.competition_challenge_config.stat_param IS
  'Optional param: nation code (transfer_sign_nation); JSON for transfer_sign_rated '
  '{max_rating,require_age,max_age,require_hg}; matchday number for player_hattrick_matchday.';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_challenge_parse_rated_param(p_param text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v jsonb;
  v_rating int;
  v_age int;
BEGIN
  IF coalesce(nullif(btrim(p_param), ''), '') = '' THEN
    RETURN jsonb_build_object(
      'max_rating', 65,
      'require_age', false,
      'max_age', 21,
      'require_hg', false
    );
  END IF;

  BEGIN
    v := p_param::jsonb;
  EXCEPTION WHEN OTHERS THEN
    -- Plain number → max rating only
    IF p_param ~ '^[0-9]{1,2}$' THEN
      RETURN jsonb_build_object(
        'max_rating', p_param::int,
        'require_age', false,
        'max_age', 21,
        'require_hg', false
      );
    END IF;
    RAISE EXCEPTION 'transfer_sign_rated stat_param must be JSON (e.g. {"max_rating":65,"require_age":true,"max_age":21,"require_hg":true})';
  END;

  v_rating := nullif(v->>'max_rating', '')::int;
  IF v_rating IS NULL OR v_rating < 1 OR v_rating > 99 THEN
    RAISE EXCEPTION 'transfer_sign_rated requires max_rating between 1 and 99';
  END IF;

  v_age := coalesce(nullif(v->>'max_age', '')::int, 21);
  IF v_age < 15 OR v_age > 45 THEN
    RAISE EXCEPTION 'transfer_sign_rated max_age must be between 15 and 45';
  END IF;

  RETURN jsonb_build_object(
    'max_rating', v_rating,
    'require_age', coalesce((v->>'require_age')::boolean, false),
    'max_age', v_age,
    'require_hg', coalesce((v->>'require_hg')::boolean, false)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Stat evaluator
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_challenge_stat_value(
  p_season_id bigint,
  p_club_short_name text,
  p_stat_type text,
  p_month_from text,
  p_month_to text,
  p_include_league boolean,
  p_include_cup boolean,
  p_stat_param text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_types text[];
  v_from_sort int;
  v_to_sort int;
  v_val int := 0;
  v_bounds record;
  v_nation text := upper(btrim(coalesce(p_stat_param, '')));
  v_rated jsonb;
  v_max_rating int;
  v_require_age boolean;
  v_max_age int;
  v_require_hg boolean;
  v_matchday int;
BEGIN
  v_from_sort := public.competition_challenge_month_sort(p_month_from);
  v_to_sort := public.competition_challenge_month_sort(p_month_to);

  -- ---- Transfer: specific nationality ----
  IF p_stat_type = 'transfer_sign_nation' THEN
    IF v_nation = '' THEN
      RETURN 0;
    END IF;

    SELECT * INTO v_bounds
    FROM public.competition_challenge_window_bounds(
      p_season_id, p_month_from, p_month_to
    );

    SELECT count(*)::int INTO v_val
    FROM public."Transfer_History" h
    JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
    WHERE h.buyer_club_id = p_club_short_name
      AND h.buyer_club_id IS DISTINCT FROM 'FOREIGN'
      AND public.competition_challenge_nation_matches(p."Nation", v_nation)
      AND h.transfer_time >= v_bounds.window_start
      AND h.transfer_time <= v_bounds.window_end;

    RETURN coalesce(v_val, 0);
  END IF;

  -- ---- Transfer: home-grown (player Nation = club Nation) ----
  IF p_stat_type = 'transfer_sign_homegrown' THEN
    SELECT * INTO v_bounds
    FROM public.competition_challenge_window_bounds(
      p_season_id, p_month_from, p_month_to
    );

    SELECT count(*)::int INTO v_val
    FROM public."Transfer_History" h
    JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
    JOIN public."Clubs" c ON c."ShortName" = h.buyer_club_id
    WHERE h.buyer_club_id = p_club_short_name
      AND h.buyer_club_id IS DISTINCT FROM 'FOREIGN'
      AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
      AND public.normalize_nation_key(p."Nation") <> ''
      AND h.transfer_time >= v_bounds.window_start
      AND h.transfer_time <= v_bounds.window_end;

    RETURN coalesce(v_val, 0);
  END IF;

  -- ---- Transfer: max rating (+ optional age / HG) ----
  IF p_stat_type = 'transfer_sign_rated' THEN
    BEGIN
      v_rated := public.competition_challenge_parse_rated_param(p_stat_param);
    EXCEPTION WHEN OTHERS THEN
      RETURN 0;
    END;

    v_max_rating := (v_rated->>'max_rating')::int;
    v_require_age := coalesce((v_rated->>'require_age')::boolean, false);
    v_max_age := coalesce((v_rated->>'max_age')::int, 21);
    v_require_hg := coalesce((v_rated->>'require_hg')::boolean, false);

    SELECT * INTO v_bounds
    FROM public.competition_challenge_window_bounds(
      p_season_id, p_month_from, p_month_to
    );

    SELECT count(*)::int INTO v_val
    FROM public."Transfer_History" h
    JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
    JOIN public."Clubs" c ON c."ShortName" = h.buyer_club_id
    WHERE h.buyer_club_id = p_club_short_name
      AND h.buyer_club_id IS DISTINCT FROM 'FOREIGN'
      AND h.transfer_time >= v_bounds.window_start
      AND h.transfer_time <= v_bounds.window_end
      AND public.player_rating_as_numeric(p."Rating"::text) > 0
      AND public.player_rating_as_numeric(p."Rating"::text) <= v_max_rating
      AND (
        NOT v_require_age
        OR (
          p."Age" IS NOT NULL
          AND btrim(p."Age"::text) <> ''
          AND btrim(p."Age"::text)::numeric <= v_max_age
        )
      )
      AND (
        NOT v_require_hg
        OR (
          public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
          AND public.normalize_nation_key(p."Nation") <> ''
        )
      );

    RETURN coalesce(v_val, 0);
  END IF;

  -- Match-based stats below
  v_types := public.competition_challenge_comp_types(p_include_league, p_include_cup);
  IF v_types = ARRAY[]::text[] THEN
    RETURN 0;
  END IF;

  -- ---- Hat-trick on a specific matchday ----
  IF p_stat_type = 'player_hattrick_matchday' THEN
    v_matchday := nullif(regexp_replace(coalesce(p_stat_param, ''), '[^0-9]', '', 'g'), '')::int;
    IF v_matchday IS NULL OR v_matchday < 1 THEN
      RETURN 0;
    END IF;

    SELECT count(*)::int INTO v_val
    FROM (
      SELECT DISTINCT m.fixture_id
      FROM public.competition_match_player_stats m
      JOIN public.competition_fixtures f ON f.id = m.fixture_id
      WHERE m.season_id = p_season_id
        AND m.club_short_name = p_club_short_name
        AND coalesce(m.goals, 0) >= 3
        AND f.status = 'played'
        AND f.competition_type = ANY (v_types)
        AND f.matchday = v_matchday
        AND public.competition_challenge_month_sort(f.gpsl_month)
              BETWEEN v_from_sort AND v_to_sort
    ) x;

    RETURN coalesce(v_val, 0);
  END IF;

  IF p_stat_type = 'player_max_goals' THEN
    SELECT coalesce(max(x.goals), 0)::int INTO v_val
    FROM (
      SELECT sum(m.goals)::int AS goals
      FROM public.competition_match_player_stats m
      JOIN public.competition_fixtures f ON f.id = m.fixture_id
      WHERE m.season_id = p_season_id
        AND m.club_short_name = p_club_short_name
        AND f.status = 'played'
        AND f.competition_type = ANY (v_types)
        AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from_sort AND v_to_sort
      GROUP BY m.player_id
    ) x;

  ELSIF p_stat_type = 'player_max_assists' THEN
    SELECT coalesce(max(x.assists), 0)::int INTO v_val
    FROM (
      SELECT sum(m.assists)::int AS assists
      FROM public.competition_match_player_stats m
      JOIN public.competition_fixtures f ON f.id = m.fixture_id
      WHERE m.season_id = p_season_id
        AND m.club_short_name = p_club_short_name
        AND f.status = 'played'
        AND f.competition_type = ANY (v_types)
        AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from_sort AND v_to_sort
      GROUP BY m.player_id
    ) x;

  ELSIF p_stat_type = 'club_wins' THEN
    SELECT count(*)::int INTO v_val
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND f.competition_type = ANY (v_types)
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from_sort AND v_to_sort
      AND (
        (f.home_club_short_name = p_club_short_name AND f.home_goals > f.away_goals)
        OR (f.away_club_short_name = p_club_short_name AND f.away_goals > f.home_goals)
      );

  ELSIF p_stat_type = 'club_goals_for' THEN
    SELECT coalesce(sum(
      CASE
        WHEN f.home_club_short_name = p_club_short_name THEN f.home_goals
        ELSE f.away_goals
      END
    ), 0)::int INTO v_val
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND f.competition_type = ANY (v_types)
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from_sort AND v_to_sort
      AND (f.home_club_short_name = p_club_short_name OR f.away_club_short_name = p_club_short_name);

  ELSIF p_stat_type = 'club_clean_sheets' THEN
    SELECT count(*)::int INTO v_val
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'played'
      AND f.competition_type = ANY (v_types)
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from_sort AND v_to_sort
      AND (
        (f.home_club_short_name = p_club_short_name AND f.away_goals = 0)
        OR (f.away_club_short_name = p_club_short_name AND f.home_goals = 0)
      );

  ELSIF p_stat_type = 'club_potm_awards' THEN
    SELECT coalesce(count(*), 0)::int INTO v_val
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE m.season_id = p_season_id
      AND m.club_short_name = p_club_short_name
      AND m.is_player_of_match = true
      AND f.status = 'played'
      AND f.competition_type = ANY (v_types)
      AND public.competition_challenge_month_sort(f.gpsl_month) BETWEEN v_from_sort AND v_to_sort;
  END IF;

  RETURN coalesce(v_val, 0);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin save — validate new types
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_save_challenge(p_challenge jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_season_id bigint;
  v_default numeric;
  v_stat text;
  v_param text;
  v_rated jsonb;
  v_matchday int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_challenge IS NULL OR jsonb_typeof(p_challenge) <> 'object' THEN
    RAISE EXCEPTION 'challenge must be a JSON object';
  END IF;

  v_season_id := (p_challenge->>'season_id')::bigint;
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'season_id required';
  END IF;

  v_default := (SELECT challenge_default_prize FROM public.global_settings WHERE id = 1);
  v_stat := coalesce(p_challenge->>'stat_type', 'club_wins');
  v_param := nullif(btrim(coalesce(p_challenge->>'stat_param', '')), '');

  IF v_stat = 'transfer_sign_nation' AND v_param IS NULL THEN
    RAISE EXCEPTION 'Nation code required for transfer nationality challenges (e.g. NOR, ESP, TPE)';
  END IF;

  IF v_stat = 'transfer_sign_homegrown' THEN
    v_param := NULL;
  END IF;

  IF v_stat = 'transfer_sign_rated' THEN
    v_rated := public.competition_challenge_parse_rated_param(v_param);
    v_param := v_rated::text;
  END IF;

  IF v_stat = 'player_hattrick_matchday' THEN
    v_matchday := nullif(regexp_replace(coalesce(v_param, ''), '[^0-9]', '', 'g'), '')::int;
    IF v_matchday IS NULL OR v_matchday < 1 OR v_matchday > 50 THEN
      RAISE EXCEPTION 'Matchday required for hat-trick challenges (e.g. 1 = opening day)';
    END IF;
    v_param := v_matchday::text;
  END IF;

  v_id := nullif(p_challenge->>'id', '')::bigint;

  IF v_id IS NOT NULL THEN
    UPDATE public.competition_challenge_config
    SET
      title = coalesce(p_challenge->>'title', title),
      description = coalesce(p_challenge->>'description', description),
      window_phase = coalesce(p_challenge->>'window_phase', window_phase),
      gpsl_month_from = coalesce(p_challenge->>'gpsl_month_from', gpsl_month_from),
      gpsl_month_to = coalesce(p_challenge->>'gpsl_month_to', gpsl_month_to),
      stat_type = coalesce(p_challenge->>'stat_type', stat_type),
      stat_param = CASE
        WHEN p_challenge ? 'stat_param' OR v_stat IN (
          'transfer_sign_homegrown', 'transfer_sign_rated', 'player_hattrick_matchday'
        ) THEN v_param
        ELSE stat_param
      END,
      target_value = coalesce((p_challenge->>'target_value')::int, target_value),
      prize_amount = coalesce((p_challenge->>'prize_amount')::numeric, prize_amount),
      include_league = coalesce((p_challenge->>'include_league')::boolean, include_league),
      include_cup = coalesce((p_challenge->>'include_cup')::boolean, include_cup),
      is_active = coalesce((p_challenge->>'is_active')::boolean, is_active),
      sort_order = coalesce((p_challenge->>'sort_order')::smallint, sort_order),
      updated_at = now()
    WHERE id = v_id AND season_id = v_season_id;
    RETURN v_id;
  END IF;

  INSERT INTO public.competition_challenge_config (
    season_id, title, description, window_phase,
    gpsl_month_from, gpsl_month_to, stat_type, stat_param, target_value, prize_amount,
    include_league, include_cup, is_active, sort_order
  )
  VALUES (
    v_season_id,
    p_challenge->>'title',
    p_challenge->>'description',
    coalesce(p_challenge->>'window_phase', 'start'),
    coalesce(p_challenge->>'gpsl_month_from', 'june'),
    coalesce(p_challenge->>'gpsl_month_to', 'december'),
    v_stat,
    v_param,
    coalesce((p_challenge->>'target_value')::int, 1),
    coalesce((p_challenge->>'prize_amount')::numeric, v_default),
    coalesce((p_challenge->>'include_league')::boolean, true),
    coalesce((p_challenge->>'include_cup')::boolean, false),
    coalesce((p_challenge->>'is_active')::boolean, true),
    coalesce((p_challenge->>'sort_order')::smallint, 0)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_challenge_parse_rated_param(text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_challenge_stat_value(bigint, text, text, text, text, boolean, boolean, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_save_challenge(jsonb)
  TO authenticated;
