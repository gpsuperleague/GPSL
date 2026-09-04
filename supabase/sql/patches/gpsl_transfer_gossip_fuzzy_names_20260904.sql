-- =============================================================================
-- Transfer gossip: tolerate typos in club / player names
--
-- Uses gpdb_normalize_search_text + pg_trgm similarity when available.
-- Only accepts a fuzzy hit when one candidate clearly wins (unique best).
-- Safe re-run.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.gpsl_rumour_resolve_club(p_text text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $function$
DECLARE
  v_q text := nullif(btrim(coalesce(p_text, '')), '');
  v_norm text;
  v_short text;
  v_name text;
  v_best_short text;
  v_best_name text;
  v_best numeric;
  v_second numeric;
  v_has_norm boolean :=
    to_regprocedure('public.gpdb_normalize_search_text(text)') IS NOT NULL;
BEGIN
  IF v_q IS NULL THEN
    RETURN NULL;
  END IF;

  -- Exact short name
  SELECT c."ShortName", c."Club" INTO v_short, v_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(v_q)
  LIMIT 1;
  IF v_short IS NOT NULL THEN
    RETURN jsonb_build_object('short_name', v_short, 'club_name', v_name);
  END IF;

  -- Exact full name
  SELECT c."ShortName", c."Club" INTO v_short, v_name
  FROM public."Clubs" c
  WHERE lower(c."Club") = lower(v_q)
  LIMIT 1;
  IF v_short IS NOT NULL THEN
    RETURN jsonb_build_object('short_name', v_short, 'club_name', v_name);
  END IF;

  -- Starts with / contains
  SELECT c."ShortName", c."Club" INTO v_short, v_name
  FROM public."Clubs" c
  WHERE lower(c."Club") LIKE lower(v_q) || '%'
     OR lower(c."Club") LIKE '%' || lower(v_q) || '%'
     OR lower(c."ShortName") LIKE lower(v_q) || '%'
  ORDER BY
    CASE
      WHEN lower(c."Club") = lower(v_q) THEN 0
      WHEN lower(c."Club") LIKE lower(v_q) || '%' THEN 1
      WHEN lower(c."ShortName") LIKE lower(v_q) || '%' THEN 2
      ELSE 3
    END,
    length(c."Club")
  LIMIT 1;
  IF v_short IS NOT NULL THEN
    RETURN jsonb_build_object('short_name', v_short, 'club_name', v_name);
  END IF;

  -- Fuzzy typo tolerance (unique clear winner)
  IF v_has_norm AND length(v_q) >= 3 THEN
    v_norm := public.gpdb_normalize_search_text(v_q);

    SELECT
      x."ShortName",
      x."Club",
      x.score,
      x.second_score
    INTO v_best_short, v_best_name, v_best, v_second
    FROM (
      SELECT
        c."ShortName",
        c."Club",
        greatest(
          similarity(public.gpdb_normalize_search_text(c."Club"), v_norm),
          similarity(public.gpdb_normalize_search_text(c."ShortName"), v_norm)
        ) AS score,
        lead(
          greatest(
            similarity(public.gpdb_normalize_search_text(c."Club"), v_norm),
            similarity(public.gpdb_normalize_search_text(c."ShortName"), v_norm)
          )
        ) OVER (
          ORDER BY greatest(
            similarity(public.gpdb_normalize_search_text(c."Club"), v_norm),
            similarity(public.gpdb_normalize_search_text(c."ShortName"), v_norm)
          ) DESC
        ) AS second_score
      FROM public."Clubs" c
      WHERE coalesce(c."ShortName", '') NOT IN ('FOREIGN', 'GPDB')
    ) x
    ORDER BY x.score DESC
    LIMIT 1;

    IF v_best_short IS NOT NULL
       AND v_best >= 0.45
       AND (v_second IS NULL OR v_best - v_second >= 0.08 OR v_best >= 0.72) THEN
      RETURN jsonb_build_object('short_name', v_best_short, 'club_name', v_best_name);
    END IF;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_rumour_resolve_player(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $function$
DECLARE
  v_q text := nullif(btrim(coalesce(p_name, '')), '');
  v_norm text;
  v_id text;
  v_name text;
  v_n int;
  v_best_id text;
  v_best_name text;
  v_best numeric;
  v_second numeric;
  v_has_norm boolean :=
    to_regprocedure('public.gpdb_normalize_search_text(text)') IS NOT NULL;
  v_has_key boolean := EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Players'
      AND column_name = 'name_search_key'
  );
BEGIN
  IF v_q IS NULL THEN
    RETURN NULL;
  END IF;

  -- Exact
  SELECT p."Konami_ID"::text, p."Name"
  INTO v_id, v_name
  FROM public."Players" p
  WHERE lower(btrim(p."Name")) = lower(v_q)
  LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('player_id', v_id, 'player_name', v_name);
  END IF;

  -- Normalized exact (accents / punctuation)
  IF v_has_norm THEN
    v_norm := public.gpdb_normalize_search_text(v_q);
    IF v_has_key THEN
      SELECT p."Konami_ID"::text, p."Name"
      INTO v_id, v_name
      FROM public."Players" p
      WHERE p.name_search_key = v_norm
      LIMIT 1;
    ELSE
      SELECT p."Konami_ID"::text, p."Name"
      INTO v_id, v_name
      FROM public."Players" p
      WHERE public.gpdb_normalize_search_text(p."Name") = v_norm
      LIMIT 1;
    END IF;
    IF v_id IS NOT NULL THEN
      RETURN jsonb_build_object('player_id', v_id, 'player_name', v_name);
    END IF;
  END IF;

  -- Unique contains
  SELECT count(*)::int INTO v_n
  FROM public."Players" p
  WHERE lower(p."Name") LIKE '%' || lower(v_q) || '%';

  IF v_n = 1 THEN
    SELECT p."Konami_ID"::text, p."Name"
    INTO v_id, v_name
    FROM public."Players" p
    WHERE lower(p."Name") LIKE '%' || lower(v_q) || '%'
    LIMIT 1;
    RETURN jsonb_build_object('player_id', v_id, 'player_name', v_name);
  END IF;

  -- Unique surname
  SELECT count(*)::int INTO v_n
  FROM public."Players" p
  WHERE lower(p."Name") LIKE '% ' || lower(v_q)
     OR lower(p."Name") = lower(v_q);

  IF v_n = 1 THEN
    SELECT p."Konami_ID"::text, p."Name"
    INTO v_id, v_name
    FROM public."Players" p
    WHERE lower(p."Name") LIKE '% ' || lower(v_q)
       OR lower(p."Name") = lower(v_q)
    LIMIT 1;
    RETURN jsonb_build_object('player_id', v_id, 'player_name', v_name);
  END IF;

  -- Fuzzy typo tolerance — unique clear winner only
  IF v_has_norm AND length(coalesce(v_norm, v_q)) >= 4 THEN
    v_norm := coalesce(v_norm, public.gpdb_normalize_search_text(v_q));

    IF v_has_key THEN
      SELECT x.player_id, x.player_name, x.score, x.second_score
      INTO v_best_id, v_best_name, v_best, v_second
      FROM (
        SELECT
          p."Konami_ID"::text AS player_id,
          p."Name" AS player_name,
          similarity(p.name_search_key, v_norm) AS score,
          lead(similarity(p.name_search_key, v_norm)) OVER (
            ORDER BY similarity(p.name_search_key, v_norm) DESC
          ) AS second_score
        FROM public."Players" p
        WHERE p.name_search_key % v_norm
           OR similarity(p.name_search_key, v_norm) >= 0.35
      ) x
      ORDER BY x.score DESC
      LIMIT 1;
    ELSE
      SELECT x.player_id, x.player_name, x.score, x.second_score
      INTO v_best_id, v_best_name, v_best, v_second
      FROM (
        SELECT
          p."Konami_ID"::text AS player_id,
          p."Name" AS player_name,
          similarity(public.gpdb_normalize_search_text(p."Name"), v_norm) AS score,
          lead(similarity(public.gpdb_normalize_search_text(p."Name"), v_norm)) OVER (
            ORDER BY similarity(public.gpdb_normalize_search_text(p."Name"), v_norm) DESC
          ) AS second_score
        FROM public."Players" p
      ) x
      WHERE x.score >= 0.35
      ORDER BY x.score DESC
      LIMIT 1;
    END IF;

    IF v_best_id IS NOT NULL
       AND v_best >= 0.42
       AND (v_second IS NULL OR v_best - v_second >= 0.06 OR v_best >= 0.70) THEN
      RETURN jsonb_build_object(
        'player_id', v_best_id,
        'player_name', v_best_name,
        'fuzzy', true,
        'score', round(v_best::numeric, 3)
      );
    END IF;
  END IF;

  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_rumour_resolve_club(text) IS
  'Resolve gossip club text: exact / contains / unique trigram typo match.';
COMMENT ON FUNCTION public.gpsl_rumour_resolve_player(text) IS
  'Resolve gossip player text: exact / contains / surname / unique trigram typo match.';

GRANT EXECUTE ON FUNCTION public.gpsl_rumour_resolve_club(text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_rumour_resolve_player(text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
