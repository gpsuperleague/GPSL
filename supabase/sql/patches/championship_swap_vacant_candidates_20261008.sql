-- Championship A swap panel: "Bring in" list now includes vacant (unowned) clubs
-- on Standby / Unassigned / not registered, as well as owned ones.
-- Each candidate carries an 'owned' flag so the page can group them.
-- The swap RPC itself already accepts any non-league club. Safe to re-run.

CREATE OR REPLACE FUNCTION public.competition_admin_championship_status(
  p_season_id bigint,
  p_division text DEFAULT 'championship_a'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_div text := coalesce(nullif(btrim(p_division), ''), 'championship_a');
  v_status text;
  v_fixtures int;
  v_members jsonb;
  v_candidates jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.status INTO v_status FROM public.competition_seasons s WHERE s.id = p_season_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  SELECT count(*) INTO v_fixtures
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.division = v_div
    AND f.competition_type = 'league';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'club', cs.club_short_name,
    'club_name', coalesce(c."Club", cs.club_short_name),
    'owned', c.owner_id IS NOT NULL,
    'owner_tag', nullif(btrim(c.owner), ''),
    'slot', cs.league_position
  ) ORDER BY (c.owner_id IS NULL), coalesce(c."Club", cs.club_short_name)), '[]'::jsonb)
  INTO v_members
  FROM public.competition_club_seasons cs
  JOIN public."Clubs" c ON c."ShortName" = cs.club_short_name
  WHERE cs.season_id = p_season_id
    AND cs.division = v_div;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'club', c."ShortName",
    'club_name', coalesce(c."Club", c."ShortName"),
    'owned', c.owner_id IS NOT NULL,
    'owner_tag', nullif(btrim(c.owner), ''),
    'division', coalesce(cs.division, 'not registered')
  ) ORDER BY (c.owner_id IS NULL), coalesce(c."Club", c."ShortName")), '[]'::jsonb)
  INTO v_candidates
  FROM public."Clubs" c
  LEFT JOIN public.competition_club_seasons cs
    ON cs.season_id = p_season_id AND cs.club_short_name = c."ShortName"
  WHERE c."ShortName" <> 'FOREIGN'
    AND NOT coalesce(c.is_archived, false)
    AND coalesce(cs.division, 'unassigned') IN ('unassigned', 'standby');

  RETURN jsonb_build_object(
    'season_id', p_season_id,
    'season_status', v_status,
    'division', v_div,
    'fixtures_drawn', v_fixtures > 0,
    'fixture_count', v_fixtures,
    'club_count', jsonb_array_length(v_members),
    'owned_count', (SELECT count(*) FROM jsonb_array_elements(v_members) m WHERE (m->>'owned')::boolean),
    'members', v_members,
    'candidates', v_candidates
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_championship_status(bigint, text) TO authenticated;

SELECT
  (SELECT count(*) FROM public."Clubs" c
   LEFT JOIN public.competition_club_seasons cs
     ON cs.club_short_name = c."ShortName"
    AND cs.season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
   WHERE c.owner_id IS NULL AND c."ShortName" <> 'FOREIGN' AND NOT coalesce(c.is_archived, false)
     AND coalesce(cs.division, 'unassigned') IN ('unassigned', 'standby')) AS vacant_candidates_now_listed,
  pg_get_functiondef('public.competition_admin_championship_status(bigint,text)'::regprocedure)
    NOT LIKE '%WHERE c.owner_id IS NOT NULL%' AS patch_installed;
