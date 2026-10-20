-- =============================================================================
-- Public map of clubs on active season absence (for fixtures / tables UI).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.season_absent_clubs_map(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_out jsonb := '{}'::jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN v_out;
  END IF;

  SELECT coalesce(
    jsonb_object_agg(upper(btrim(a.club_short_name)), true),
    '{}'::jsonb
  )
  INTO v_out
  FROM public.club_season_absences a
  WHERE a.season_id = v_season_id
    AND a.status = 'active'
    AND nullif(btrim(a.club_short_name), '') IS NOT NULL;

  RETURN coalesce(v_out, '{}'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.season_absent_clubs_map(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.season_absent_clubs_map(bigint) TO authenticated;

COMMENT ON FUNCTION public.season_absent_clubs_map(bigint) IS
  'Club short names on active season absence → true (fixtures/tables Away mark).';
