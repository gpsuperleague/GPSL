-- Shield cup: include SuperLeague places 17–20 (in addition to CH 5–15).

CREATE OR REPLACE FUNCTION public.competition_qualify_cup_clubs(
  p_season_id bigint,
  p_cup_code text
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[] := ARRAY[]::text[];
BEGIN
  IF p_cup_code = 'super8' THEN
    SELECT array_agg(s.club_short_name ORDER BY s.table_position)
    INTO v_clubs
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id
      AND s.division = 'superleague'
      AND s.table_position <= 8;
  ELSIF p_cup_code = 'plate' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT s.club_short_name AS club, s.table_position AS sort_key
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'superleague'
        AND s.table_position BETWEEN 9 AND 16
      UNION ALL
      SELECT s.club_short_name, 100 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_a'
        AND s.table_position <= 4
      UNION ALL
      SELECT s.club_short_name, 200 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_b'
        AND s.table_position <= 4
    ) x;
  ELSIF p_cup_code = 'shield' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT s.club_short_name AS club, s.table_position AS sort_key
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'superleague'
        AND s.table_position BETWEEN 17 AND 20
      UNION ALL
      SELECT s.club_short_name, 100 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_a'
        AND s.table_position BETWEEN 5 AND 15
      UNION ALL
      SELECT s.club_short_name, 200 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_b'
        AND s.table_position BETWEEN 5 AND 15
      UNION ALL
      SELECT q.club_short_name, 50
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = p_season_id
        AND q.cup_code = 'shield'
        AND q.qualifier_role = 'shield_playoff_winner'
    ) x;
  ELSIF p_cup_code = 'spoon' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT s.club_short_name AS club, s.table_position AS sort_key
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_a'
        AND s.table_position >= 18
      UNION ALL
      SELECT s.club_short_name, 100 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_b'
        AND s.table_position >= 18
      UNION ALL
      SELECT q.club_short_name, 50
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = p_season_id
        AND q.cup_code = 'spoon'
        AND q.qualifier_role = 'spoon_playoff_loser'
    ) x;
  ELSIF p_cup_code = 'league_cup' THEN
    SELECT array_agg(cs.club_short_name ORDER BY cs.club_short_name)
    INTO v_clubs
    FROM public.competition_club_seasons cs
    WHERE cs.season_id = p_season_id
      AND cs.division IN ('superleague', 'championship_a', 'championship_b');
  ELSE
    RETURN ARRAY[]::text[];
  END IF;

  RETURN coalesce(v_clubs, ARRAY[]::text[]);
END;
$function$;
