-- SUPERSEDED. Do not run.
-- Player stats, profiles, and squads stay on GK, CB, full-back, wing-back, and DMF.
-- Every playstyle is counted only inside the Ballon d'Or.
DO $block$
BEGIN
  RAISE EXCEPTION 'Superseded. All-position shutouts are Ballon d''Or only.';
END;
$block$;

-- Player-stat clean sheets: any starter in a match the club did not concede.
-- Already-played matches are recounted because the stats views call these functions.

CREATE OR REPLACE FUNCTION public.competition_player_clean_sheets(
  p_season_id bigint,
  p_player_id text,
  p_club_short_name text DEFAULT NULL,
  p_include_cups boolean DEFAULT true
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  SELECT count(*)::int
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  WHERE m.season_id = p_season_id
    AND m.player_id = btrim(p_player_id)
    AND m.started = true
    AND f.status = 'played'
    AND (
      p_include_cups
      OR f.competition_type = 'league'
    )
    AND (
      p_club_short_name IS NULL
      OR m.club_short_name = btrim(p_club_short_name)
    )
    AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_player_clean_sheets_month(
  p_season_id bigint,
  p_gpsl_month text,
  p_player_id text,
  p_club_short_name text DEFAULT NULL
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  SELECT count(*)::int
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  WHERE m.season_id = p_season_id
    AND f.gpsl_month = p_gpsl_month
    AND f.competition_type = 'league'
    AND m.player_id = btrim(p_player_id)
    AND m.started = true
    AND f.status = 'played'
    AND (
      p_club_short_name IS NULL
      OR m.club_short_name = btrim(p_club_short_name)
    )
    AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0;
$gpsl$;

DO $cup$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_viewdef('public.competition_player_cup_stats_public'::regclass, true);
  v_def := replace(v_def, E'\r\n', E'\n');
  v_new := replace(
    v_def,
    '(competition_player_stat_role(p."Position") = ANY (ARRAY[''goalkeeper''::text, ''defender''::text])) AND ',
    ''
  );
  IF v_new = v_def THEN
    RAISE EXCEPTION 'cup clean-sheet role filter not found';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.competition_player_cup_stats_public WITH (security_invoker = false) AS '
    || v_new;
END;
$cup$;

UPDATE public.competition_player_season_archive a
SET clean_sheets = public.competition_player_clean_sheets(
  a.season_id, a.player_id, a.club_short_name, true
)
WHERE a.season_id IS NOT NULL;

GRANT EXECUTE ON FUNCTION public.competition_player_clean_sheets(bigint, text, text, boolean) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_player_clean_sheets_month(bigint, text, text, text) TO authenticated, anon;
GRANT SELECT ON public.competition_player_cup_stats_public TO authenticated, anon;

SELECT jsonb_build_object(
  'wirtz_league', (
    SELECT clean_sheets
    FROM public.competition_player_season_stats_public
    WHERE player_id = '137924'
    LIMIT 1
  ),
  'players_with_cs', (
    SELECT count(*) FROM public.competition_player_season_stats_public WHERE clean_sheets > 0
  ),
  'role_filter_gone', position(
    'ballon_is_cs_role' IN pg_get_functiondef('public.competition_player_clean_sheets(bigint, text, text, boolean)'::regprocedure)
  ) = 0
);
