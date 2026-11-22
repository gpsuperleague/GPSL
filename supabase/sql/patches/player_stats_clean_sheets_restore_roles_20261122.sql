-- Player stats, profiles, and squads: clean sheets only for GK, CB, LB, RB, LWB, RWB, DMF.
-- Ballon d'Or keeps competition_player_ballon_clean_sheets (every starter, club conceded 0).

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
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
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
    AND public.competition_ballon_is_cs_role(p."Position")
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
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
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
    AND public.competition_player_stat_role(p."Position") IN ('goalkeeper', 'defender')
    AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0;
$gpsl$;

DO $cup$
DECLARE
  v_def text;
  v_new text;
  v_from text := 'FILTER (WHERE m.started AND competition_player_conceded_in_fixture';
  v_to text := 'FILTER (WHERE m.started AND (competition_player_stat_role(p."Position") = ANY (ARRAY[''goalkeeper''::text, ''defender''::text])) AND competition_player_conceded_in_fixture';
BEGIN
  v_def := replace(pg_get_viewdef('public.competition_player_cup_stats_public'::regclass, true), E'\r\n', E'\n');
  IF position(v_to IN v_def) > 0 THEN
    v_new := v_def;
  ELSE
    v_new := replace(v_def, v_from, v_to);
    IF v_new = v_def THEN
      RAISE EXCEPTION 'cup clean-sheet filter not found';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW public.competition_player_cup_stats_public WITH (security_invoker = false) AS '
      || v_new;
  END IF;
END;
$cup$;

UPDATE public.competition_player_season_archive a
SET clean_sheets = public.competition_player_clean_sheets(
  a.season_id, a.player_id, a.club_short_name, true
)
WHERE a.season_id IS NOT NULL;

SELECT jsonb_build_object(
  'wirtz_profile', (
    SELECT clean_sheets
    FROM public.competition_player_season_stats_public
    WHERE player_id = '137924'
    LIMIT 1
  ),
  'wirtz_ballon', public.competition_player_ballon_clean_sheets(
    (SELECT id FROM public.competition_seasons WHERE is_current LIMIT 1),
    '137924',
    'BAR'
  ),
  'players_with_cs', (
    SELECT count(*) FROM public.competition_player_season_stats_public WHERE clean_sheets > 0
  ),
  'role_filter_back', position(
    'ballon_is_cs_role' IN pg_get_functiondef('public.competition_player_clean_sheets(bigint, text, text, boolean)'::regprocedure)
  ) > 0
);
