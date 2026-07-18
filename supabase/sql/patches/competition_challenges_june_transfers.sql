-- =============================================================================
-- Season challenges — June start window + transfer nationality signings
--
-- Start window can run June → December (transfer window + first half).
-- New stat_type: transfer_sign_nation (stat_param = nation code e.g. NOR, ESP, TPE).
-- Seed includes a few nationality examples; add more anytime via Admin → Season challenges.
--
-- Run after competition_challenges.sql.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema: allow June/July on challenge months + optional stat_param
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_challenge_config
  DROP CONSTRAINT IF EXISTS competition_challenge_config_gpsl_month_from_check;

ALTER TABLE public.competition_challenge_config
  DROP CONSTRAINT IF EXISTS competition_challenge_config_gpsl_month_to_check;

ALTER TABLE public.competition_challenge_config
  DROP CONSTRAINT IF EXISTS competition_challenge_config_stat_type_check;

ALTER TABLE public.competition_challenge_config
  DROP CONSTRAINT IF EXISTS competition_challenge_config_check;

ALTER TABLE public.competition_challenge_config
  ADD COLUMN IF NOT EXISTS stat_param text;

COMMENT ON COLUMN public.competition_challenge_config.stat_param IS
  'Optional param for the stat (e.g. nation code NOR/ESP/TPE for transfer_sign_nation).';

ALTER TABLE public.competition_challenge_config
  ADD CONSTRAINT competition_challenge_config_gpsl_month_from_check
  CHECK (
    gpsl_month_from IN (
      'june', 'july',
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may'
    )
  );

ALTER TABLE public.competition_challenge_config
  ADD CONSTRAINT competition_challenge_config_gpsl_month_to_check
  CHECK (
    gpsl_month_to IN (
      'june', 'july',
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may'
    )
  );

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
      'transfer_sign_nation'
    )
  );

-- Re-apply ordered month window using challenge month sort (below)
ALTER TABLE public.competition_challenge_config
  DROP CONSTRAINT IF EXISTS competition_challenge_config_month_order_check;

-- ---------------------------------------------------------------------------
-- Challenge month helpers (June/July sit before August; calendar stays Aug–May)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_challenge_month_sort(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'june' THEN 0
    WHEN 'july' THEN 1
    WHEN 'august' THEN 2
    WHEN 'september' THEN 3
    WHEN 'october' THEN 4
    WHEN 'november' THEN 5
    WHEN 'december' THEN 6
    WHEN 'january' THEN 7
    WHEN 'february' THEN 8
    WHEN 'march' THEN 9
    WHEN 'april' THEN 10
    WHEN 'may' THEN 11
    WHEN 'playoffs' THEN 12
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_challenge_month_label(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT initcap(lower(btrim(coalesce(p_month, ''))));
$$;

ALTER TABLE public.competition_challenge_config
  ADD CONSTRAINT competition_challenge_config_month_order_check
  CHECK (
    public.competition_challenge_month_sort(gpsl_month_from)
    <= public.competition_challenge_month_sort(gpsl_month_to)
  );

-- Timestamp bounds for a challenge month window (June/July inferred from August unlock)
CREATE OR REPLACE FUNCTION public.competition_challenge_window_bounds(
  p_season_id bigint,
  p_month_from text,
  p_month_to text
)
RETURNS TABLE (window_start timestamptz, window_end timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from text := lower(btrim(p_month_from));
  v_to text := lower(btrim(p_month_to));
  v_aug_unlock timestamptz;
  v_start timestamptz;
  v_end timestamptz;
BEGIN
  SELECT c.unlock_at INTO v_aug_unlock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = 'august'
  LIMIT 1;

  IF v_from IN ('june', 'july') THEN
    IF v_aug_unlock IS NOT NULL THEN
      v_start := CASE v_from
        WHEN 'june' THEN v_aug_unlock - interval '8 weeks'
        ELSE v_aug_unlock - interval '4 weeks'
      END;
    ELSE
      -- Calendar not set yet — open from season creation (or far past)
      SELECT coalesce(s.created_at, timestamptz '2000-01-01')
      INTO v_start
      FROM public.competition_seasons s
      WHERE s.id = p_season_id;
    END IF;
  ELSE
    SELECT c.unlock_at INTO v_start
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.gpsl_month = v_from
    LIMIT 1;
    IF v_start IS NULL AND v_aug_unlock IS NOT NULL THEN
      v_start := v_aug_unlock;
    END IF;
    IF v_start IS NULL THEN
      SELECT coalesce(s.created_at, timestamptz '2000-01-01')
      INTO v_start
      FROM public.competition_seasons s
      WHERE s.id = p_season_id;
    END IF;
  END IF;

  IF v_to IN ('june', 'july') THEN
    IF v_aug_unlock IS NOT NULL THEN
      v_end := CASE v_to
        WHEN 'june' THEN v_aug_unlock - interval '4 weeks'
        ELSE v_aug_unlock
      END;
    ELSE
      v_end := timestamptz '2099-01-01';
    END IF;
  ELSE
    SELECT c.lock_at INTO v_end
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.gpsl_month = v_to
    LIMIT 1;
    IF v_end IS NULL THEN
      v_end := timestamptz '2099-01-01';
    END IF;
  END IF;

  window_start := coalesce(v_start, timestamptz '2000-01-01');
  window_end := coalesce(v_end, timestamptz '2099-01-01');
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_challenge_nation_matches(
  p_player_nation text,
  p_nation_code text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := upper(btrim(coalesce(p_nation_code, '')));
  v_label text := btrim(coalesce(p_player_nation, ''));
BEGIN
  IF v_code = '' OR v_label = '' THEN
    RETURN false;
  END IF;

  IF to_regprocedure('public.international_gpdb_matches_nation(text, text)') IS NOT NULL THEN
    RETURN public.international_gpdb_matches_nation(v_label, v_code);
  END IF;

  -- Fallback if international map not installed
  RETURN upper(v_label) = v_code
    OR v_label ILIKE v_code
    OR (
      v_code = 'NOR' AND v_label ILIKE '%norway%'
    )
    OR (
      v_code = 'ESP' AND (v_label ILIKE '%spain%' OR upper(v_label) = 'ESP')
    )
    OR (
      v_code IN ('TPE', 'TWN') AND (
        v_label ILIKE '%taiwan%'
        OR v_label ILIKE '%taipei%'
        OR upper(v_label) IN ('TPE', 'TWN')
      )
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Stat evaluator (challenge month sort + transfer_sign_nation)
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
BEGIN
  v_from_sort := public.competition_challenge_month_sort(p_month_from);
  v_to_sort := public.competition_challenge_month_sort(p_month_to);

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

  v_types := public.competition_challenge_comp_types(p_include_league, p_include_cup);
  IF v_types = ARRAY[]::text[] THEN
    RETURN 0;
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

CREATE OR REPLACE FUNCTION public.competition_challenge_window_open(
  p_season_id bigint,
  p_window_phase text,
  p_gpsl_month_to text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_active text;
  v_active_sort int;
  v_deadline_sort int;
  v_deadline text := lower(btrim(coalesce(p_gpsl_month_to, '')));
BEGIN
  v_active := public.competition_active_gpsl_month(p_season_id, now());
  v_deadline_sort := public.competition_challenge_month_sort(p_gpsl_month_to);

  -- Pre-season / between months / no calendar: keep start window open for transfers
  IF v_active IS NULL THEN
    RETURN true;
  END IF;

  v_active := lower(btrim(v_active));

  -- Only May-deadline challenges stay open through Playoffs (not Jan/Feb/Mar-only)
  IF v_active = 'playoffs' AND v_deadline = 'may' THEN
    RETURN true;
  END IF;

  v_active_sort := public.competition_challenge_month_sort(v_active);
  IF v_active_sort IS NULL OR v_deadline_sort IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_active_sort <= v_deadline_sort;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_try_award_challenges(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.competition_challenge_config;
  v_val int;
  v_awarded int := 0;
BEGIN
  IF p_season_id IS NULL OR p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.competition_challenge_config
    WHERE season_id = p_season_id
      AND is_active = true
    ORDER BY sort_order, id
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_challenge_awarded
      WHERE challenge_id = v_row.id
        AND club_short_name = p_club_short_name
    ) THEN
      CONTINUE;
    END IF;

    IF NOT public.competition_challenge_window_open(
      p_season_id, v_row.window_phase, v_row.gpsl_month_to
    ) THEN
      CONTINUE;
    END IF;

    v_val := public.competition_challenge_stat_value(
      p_season_id,
      p_club_short_name,
      v_row.stat_type,
      v_row.gpsl_month_from,
      v_row.gpsl_month_to,
      v_row.include_league,
      v_row.include_cup,
      v_row.stat_param
    );

    IF v_val >= v_row.target_value THEN
      IF public.competition_award_challenge(v_row.id, p_club_short_name, v_val) THEN
        v_awarded := v_awarded + 1;
        PERFORM public.competition_try_award_period_bonus(
          p_season_id, p_club_short_name, v_row.window_phase
        );
      END IF;
    END IF;
  END LOOP;

  RETURN v_awarded;
END;
$function$;

-- Progress RPC (owner UI expects { challenges: [...] } with awarded/expired)
CREATE OR REPLACE FUNCTION public.competition_challenge_club_progress(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_me text := public.my_club_shortname();
  v_season_id bigint;
  v_challenges jsonb := '[]'::jsonb;
  v_row record;
  v_val int;
  v_awarded boolean;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.is_gpsl_admin() AND (v_me IS NULL OR v_me <> v_club) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  FOR v_row IN
    SELECT *
    FROM public.competition_challenge_config
    WHERE season_id = v_season_id
      AND is_active = true
    ORDER BY window_phase, sort_order, id
  LOOP
    v_val := public.competition_challenge_stat_value(
      v_season_id,
      v_club,
      v_row.stat_type,
      v_row.gpsl_month_from,
      v_row.gpsl_month_to,
      v_row.include_league,
      v_row.include_cup,
      v_row.stat_param
    );

    SELECT EXISTS (
      SELECT 1 FROM public.competition_challenge_awarded
      WHERE challenge_id = v_row.id AND club_short_name = v_club
    ) INTO v_awarded;

    v_challenges := v_challenges || jsonb_build_array(
      jsonb_build_object(
        'id', v_row.id,
        'title', v_row.title,
        'description', v_row.description,
        'window_phase', v_row.window_phase,
        'gpsl_month_from', v_row.gpsl_month_from,
        'gpsl_month_to', v_row.gpsl_month_to,
        'gpsl_month_from_label', public.competition_challenge_month_label(v_row.gpsl_month_from),
        'gpsl_month_to_label', public.competition_challenge_month_label(v_row.gpsl_month_to),
        'stat_type', v_row.stat_type,
        'stat_param', v_row.stat_param,
        'target_value', v_row.target_value,
        'current_value', v_val,
        'prize_amount', v_row.prize_amount,
        'awarded', v_awarded,
        'expired', NOT public.competition_challenge_window_open(
          v_season_id, v_row.window_phase, v_row.gpsl_month_to
        )
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'club_short_name', v_club,
    'challenges', v_challenges
  );
END;
$function$;

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
        WHEN p_challenge ? 'stat_param' THEN v_param
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

-- Seed: Start = June–Dec (includes transfer nationality challenges)
CREATE OR REPLACE FUNCTION public.competition_admin_seed_challenge_defaults(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_default numeric;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    RAISE EXCEPTION 'season_id required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_challenge_config WHERE season_id = p_season_id
  ) THEN
    RAISE EXCEPTION 'Challenges already exist for this season — delete first or add manually';
  END IF;

  v_default := (SELECT challenge_default_prize FROM public.global_settings WHERE id = 1);

  INSERT INTO public.competition_challenge_config (
    season_id, title, description, window_phase, gpsl_month_from, gpsl_month_to,
    stat_type, stat_param, target_value, prize_amount, include_league, include_cup, sort_order
  )
  VALUES
    -- Start (June–December): transfer window + first half
    -- Nationality examples (add more via Admin with any nation code)
    (p_season_id, 'Northern lights', 'Sign a Norwegian player', 'start', 'june', 'december',
      'transfer_sign_nation', 'NOR', 1, v_default, true, false, 1),
    (p_season_id, 'Spanish acquisition', 'Sign a Spanish player', 'start', 'june', 'december',
      'transfer_sign_nation', 'ESP', 1, v_default, true, false, 2),
    (p_season_id, 'Formosa signing', 'Sign a Taiwanese player', 'start', 'june', 'december',
      'transfer_sign_nation', 'TPE', 1, v_default, true, false, 3),
    (p_season_id, 'Golden boot', 'Any player reaches 15 league goals', 'start', 'june', 'december',
      'player_max_goals', NULL, 15, v_default, true, false, 4),
    (p_season_id, 'Winning habit', '10 league wins', 'start', 'june', 'december',
      'club_wins', NULL, 10, v_default, true, false, 5),
    (p_season_id, 'Shutout specialists', '5 league clean sheets', 'start', 'june', 'december',
      'club_clean_sheets', NULL, 5, v_default, true, false, 6),
    -- Mid (January–May)
    (p_season_id, 'Second-half scorer', 'Any player reaches 12 league goals', 'mid', 'january', 'may',
      'player_max_goals', NULL, 12, v_default, true, false, 1),
    (p_season_id, 'Spring surge', '8 league wins', 'mid', 'january', 'may',
      'club_wins', NULL, 8, v_default, true, false, 2),
    (p_season_id, 'Defensive wall', '4 league clean sheets', 'mid', 'january', 'may',
      'club_clean_sheets', NULL, 4, v_default, true, false, 3),
    (p_season_id, 'Free scoring', '28 league goals scored', 'mid', 'january', 'may',
      'club_goals_for', NULL, 28, v_default, true, false, 4),
    (p_season_id, 'Match heroes', '4 player-of-the-match awards', 'mid', 'january', 'may',
      'club_potm_awards', NULL, 4, v_default, true, false, 5);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Views (DROP required when inserting columns mid-list)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.competition_challenges_public;

CREATE VIEW public.competition_challenges_public
WITH (security_invoker = false)
AS
SELECT
  c.id,
  c.season_id,
  c.title,
  c.description,
  c.window_phase,
  c.gpsl_month_from,
  c.gpsl_month_to,
  public.competition_challenge_month_label(c.gpsl_month_from) AS gpsl_month_from_label,
  public.competition_challenge_month_label(c.gpsl_month_to) AS gpsl_month_to_label,
  c.stat_type,
  c.target_value,
  c.stat_param,
  c.prize_amount,
  c.include_league,
  c.include_cup,
  c.is_active,
  c.sort_order,
  c.created_at,
  c.updated_at
FROM public.competition_challenge_config c
JOIN public.competition_seasons s ON s.id = c.season_id
WHERE s.is_current = true;

GRANT SELECT ON public.competition_challenges_public TO authenticated;
GRANT SELECT ON public.competition_challenges_public TO anon;

-- ---------------------------------------------------------------------------
-- Award on transfer completion
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_transfer_history_challenge_award()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_buyer text := nullif(btrim(NEW.buyer_club_id), '');
BEGIN
  IF v_buyer IS NULL OR v_buyer = 'FOREIGN' THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NOT NULL THEN
    PERFORM public.competition_try_award_challenges(v_season_id, v_buyer);
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS transfer_history_challenge_award ON public."Transfer_History";
CREATE TRIGGER transfer_history_challenge_award
  AFTER INSERT ON public."Transfer_History"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_transfer_history_challenge_award();

GRANT EXECUTE ON FUNCTION public.competition_challenge_month_sort(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_month_label(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_window_bounds(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_nation_matches(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_stat_value(bigint, text, text, text, text, boolean, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
