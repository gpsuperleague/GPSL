-- =============================================================================
-- Owners → Info → Match System directory
-- Public board of each club's GPSL match arrangement system (ON / OFF).
-- Club + owner tag only — never email. Safe re-run.
-- Depends on: club_match_system_preference, club_gpsl_match_system_on,
--             gpsl_month_match_system_half (gpsl_match_system_toggle_20261020.sql).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owners_match_system_directory()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_season_id bigint;
  v_month text;
  v_half text;
  v_half_label text;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'No current season',
      'clubs', '[]'::jsonb
    );
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_half := public.gpsl_month_match_system_half(v_month);
  v_half_label := CASE v_half
    WHEN 'h1' THEN 'August–December'
    WHEN 'h2' THEN 'January–May'
    ELSE 'Pre-season (defaults ON)'
  END;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_key, x.club_short_name), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      c."ShortName" AS club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
      c.owner_id,
      coalesce(
        nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
        nullif(btrim(c.owner), '')
      ) AS owner_tag,
      coalesce(h1.gpsl_system_on, true) AS h1_gpsl_system_on,
      CASE
        WHEN h2.club_short_name IS NOT NULL THEN h2.gpsl_system_on
        ELSE coalesce(h1.gpsl_system_on, true)
      END AS h2_gpsl_system_on,
      (h2.club_short_name IS NOT NULL) AS h2_explicitly_set,
      public.club_gpsl_match_system_on(c."ShortName", v_season_id, v_month)
        AS effective_gpsl_system_on,
      CASE
        WHEN public.club_gpsl_match_system_on(c."ShortName", v_season_id, v_month)
        THEN 'gpsl'
        ELSE 'manual'
      END AS arrangement,
      CASE
        WHEN public.club_gpsl_match_system_on(c."ShortName", v_season_id, v_month)
        THEN 0
        ELSE 1
      END AS sort_key
    FROM public."Clubs" c
    LEFT JOIN public.club_match_system_preference h1
      ON h1.club_short_name = c."ShortName"
     AND h1.season_id = v_season_id
     AND h1.half = 'h1'
    LEFT JOIN public.club_match_system_preference h2
      ON h2.club_short_name = c."ShortName"
     AND h2.season_id = v_season_id
     AND h2.half = 'h2'
    WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
      AND c.owner_id IS NOT NULL
      AND (
        to_regprocedure('public.competition_club_is_vacant(text)') IS NULL
        OR NOT public.competition_club_is_vacant(c."ShortName")
      )
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'active_gpsl_month', v_month,
    'active_half', v_half,
    'active_half_label', v_half_label,
    'clubs', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owners_match_system_directory() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owners_match_system_directory() TO authenticated;

COMMENT ON FUNCTION public.owners_match_system_directory() IS
  'Owners Info board: each owned club''s GPSL match system ON/OFF for the active half.';
