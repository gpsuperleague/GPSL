-- =============================================================================
-- Persist GPDB season exclusions across seasons
--
-- 1) admin_gpdb_copy_season_exclusions — copy players + nations from A → B
-- 2) competition_create_season — auto-copy from previous season
-- 3) Eligibility — when no open season, still honour the resolved season
--    (so Summer Break after End Season keeps Season 1 exclusions active)
--
-- Safe to re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_gpdb_copy_season_exclusions(
  p_from_season_id bigint,
  p_to_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from bigint := p_from_season_id;
  v_to bigint := p_to_season_id;
  v_players int := 0;
  v_nations int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_from IS NULL THEN
    SELECT s.id INTO v_from
    FROM public.competition_seasons s
    WHERE s.id <> coalesce(v_to, -1)
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_to IS NULL THEN
    v_to := public.gpdb_exclusion_season_id(NULL);
  END IF;

  IF v_from IS NULL OR v_to IS NULL THEN
    RAISE EXCEPTION 'from_season_id and to_season_id required';
  END IF;

  IF v_from = v_to THEN
    RAISE EXCEPTION 'Source and target season are the same';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_from) THEN
    RAISE EXCEPTION 'Source season % not found', v_from;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons WHERE id = v_to) THEN
    RAISE EXCEPTION 'Target season % not found', v_to;
  END IF;

  INSERT INTO public.gpdb_season_excluded_players (
    season_id, player_id, reason, excluded_at, excluded_by
  )
  SELECT
    v_to,
    ep.player_id,
    ep.reason,
    now(),
    auth.uid()
  FROM public.gpdb_season_excluded_players ep
  WHERE ep.season_id = v_from
  ON CONFLICT (season_id, player_id) DO UPDATE
  SET
    reason = COALESCE(EXCLUDED.reason, gpdb_season_excluded_players.reason),
    excluded_at = now(),
    excluded_by = auth.uid();

  GET DIAGNOSTICS v_players = ROW_COUNT;

  INSERT INTO public.gpdb_season_excluded_nations (
    season_id, nation_code, reason, excluded_at, excluded_by
  )
  SELECT
    v_to,
    en.nation_code,
    en.reason,
    now(),
    auth.uid()
  FROM public.gpdb_season_excluded_nations en
  WHERE en.season_id = v_from
  ON CONFLICT (season_id, nation_code) DO UPDATE
  SET
    reason = COALESCE(EXCLUDED.reason, gpdb_season_excluded_nations.reason),
    excluded_at = now(),
    excluded_by = auth.uid();

  GET DIAGNOSTICS v_nations = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'from_season_id', v_from,
    'to_season_id', v_to,
    'players_copied', v_players,
    'nations_copied', v_nations
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpdb_copy_season_exclusions(bigint, bigint) TO authenticated;

-- Auto-copy when a new season is created
CREATE OR REPLACE FUNCTION public.competition_create_season(p_label text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text := trim(p_label);
  v_season_id bigint;
  v_club_count bigint;
  v_prev bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_label IS NULL OR v_label = '' THEN
    RAISE EXCEPTION 'Season label is required';
  END IF;

  INSERT INTO public.competition_seasons (label, status, is_current)
  VALUES (v_label, 'preseason', false)
  RETURNING id INTO v_season_id;

  INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
  SELECT v_season_id, c."ShortName", 'unassigned'
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
  ORDER BY c."ShortName";

  GET DIAGNOSTICS v_club_count = ROW_COUNT;

  IF v_club_count <> 60 THEN
    RAISE EXCEPTION 'Expected 60 clubs, found %', v_club_count;
  END IF;

  SELECT s.id INTO v_prev
  FROM public.competition_seasons s
  WHERE s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev IS NOT NULL
     AND (
       EXISTS (
         SELECT 1 FROM public.gpdb_season_excluded_players ep WHERE ep.season_id = v_prev
       )
       OR EXISTS (
         SELECT 1 FROM public.gpdb_season_excluded_nations en WHERE en.season_id = v_prev
       )
     )
  THEN
    PERFORM public.admin_gpdb_copy_season_exclusions(v_prev, v_season_id);
  END IF;

  RETURN v_season_id;
END;
$function$;

-- Eligibility: open seasons OR the resolved gpdb_exclusion_season_id (latest / current)
CREATE OR REPLACE FUNCTION public.gpdb_player_is_season_excluded(
  p_player_id text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_sid bigint;
BEGIN
  IF v_pid IS NULL OR v_pid = '' THEN
    RETURN false;
  END IF;

  IF p_season_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_players ep
      WHERE ep.season_id = p_season_id
        AND ep.player_id = v_pid
    ) THEN
      RETURN true;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_nations en
      WHERE en.season_id = p_season_id
        AND public.international_player_matches_nation(v_pid, en.nation_code)
    ) THEN
      RETURN true;
    END IF;

    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_players ep
    JOIN public.competition_seasons s ON s.id = ep.season_id
    WHERE ep.player_id = v_pid
      AND (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
  ) THEN
    RETURN true;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
      AND public.international_player_matches_nation(v_pid, en.nation_code)
  ) THEN
    RETURN true;
  END IF;

  -- Summer Break / between seasons: honour latest (or current) exclusion season
  v_sid := public.gpdb_exclusion_season_id(NULL);
  IF v_sid IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_players ep
      WHERE ep.season_id = v_sid
        AND ep.player_id = v_pid
    ) THEN
      RETURN true;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_nations en
      WHERE en.season_id = v_sid
        AND public.international_player_matches_nation(v_pid, en.nation_code)
    ) THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_nation_is_season_excluded(
  p_nation_code text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := upper(btrim(p_nation_code));
  v_sid bigint;
BEGIN
  IF v_code IS NULL OR v_code = '' THEN
    RETURN false;
  END IF;

  IF p_season_id IS NOT NULL THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_nations en
      WHERE en.season_id = p_season_id
        AND upper(en.nation_code) = v_code
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE upper(en.nation_code) = v_code
      AND (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
  ) THEN
    RETURN true;
  END IF;

  v_sid := public.gpdb_exclusion_season_id(NULL);
  IF v_sid IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    WHERE en.season_id = v_sid
      AND upper(en.nation_code) = v_code
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
