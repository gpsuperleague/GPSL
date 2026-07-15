-- =============================================================================
-- club_fixtures_my_club — show cards + injuries on played fixtures
--
-- Adds for the logged-in club on played matches:
--   • yellow / red cards (from competition_match_player_stats)
--   • injuries incurred in that fixture (source_fixture_id)
--
-- Run after club_fixtures_my_club_kickoff.sql (or any prior club_fixtures_my_club).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_fixtures_my_club()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(row_to_json(t)::jsonb ORDER BY t.gpsl_month_sort, t.matchday, t.id)
      FROM (
        SELECT
          f.id,
          f.season_id,
          f.division,
          f.competition_type,
          f.cup_code,
          f.cup_round,
          f.cup_match,
          f.matchday,
          f.gpsl_month,
          f.week_in_month,
          public.competition_gpsl_month_sort(f.gpsl_month) AS gpsl_month_sort,
          f.home_club_short_name,
          hc."Club" AS home_club_name,
          f.away_club_short_name,
          ac."Club" AS away_club_name,
          f.weather,
          f.pitch_condition,
          f.kit_season,
          public.competition_club_continent(f.home_club_short_name) AS home_continent,
          f.home_goals,
          f.away_goals,
          f.status,
          f.is_forfeit,
          (f.home_club_short_name = v_club) AS is_home,
          coalesce(sch.status, 'unscheduled') AS schedule_status,
          sch.agreed_kickoff_at,
          CASE
            WHEN f.competition_type = 'league' AND f.status = 'played' THEN
              public.competition_club_table_position_as_of(
                f.season_id,
                f.division,
                v_club,
                f.matchday + 1
              )
            ELSE NULL
          END AS league_position,
          CASE
            WHEN f.status = 'played' THEN (
              SELECT round(
                (l.metadata ->> 'capacity')::numeric
                * (l.metadata ->> 'attendance_rate')::numeric
              )::int
              FROM public.competition_finance_ledger l
              WHERE l.fixture_id = f.id
                AND l.entry_type = 'gate_league_home'
              LIMIT 1
            )
            ELSE NULL
          END AS attendance,
          CASE
            WHEN f.status = 'played' THEN (
              SELECT coalesce(
                jsonb_agg(
                  jsonb_build_object(
                    'player_id', m.player_id,
                    'player_name', p."Name",
                    'goals', m.goals,
                    'assists', m.assists,
                    'is_player_of_match', m.is_player_of_match,
                    'yellow_card', coalesce(m.yellow_card, false),
                    'red_card', coalesce(m.red_card, false)
                  )
                  ORDER BY
                    m.is_player_of_match DESC,
                    m.goals DESC,
                    m.assists DESC,
                    m.red_card DESC,
                    m.yellow_card DESC,
                    p."Name"
                ),
                '[]'::jsonb
              )
              FROM public.competition_match_player_stats m
              JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
              WHERE m.fixture_id = f.id
                AND m.club_short_name = v_club
                AND (
                  m.goals > 0
                  OR m.assists > 0
                  OR m.is_player_of_match
                  OR coalesce(m.yellow_card, false)
                  OR coalesce(m.red_card, false)
                )
            )
            ELSE '[]'::jsonb
          END AS match_contributions,
          CASE
            WHEN f.status = 'played'
             AND to_regclass('public.competition_player_injuries') IS NOT NULL THEN (
              SELECT coalesce(
                jsonb_agg(
                  jsonb_build_object(
                    'player_id', i.player_id,
                    'player_name', p."Name",
                    'label', coalesce(nullif(btrim(i.label), ''), cat.name, 'Injury'),
                    'severity', coalesce(i.severity, cat.severity)
                  )
                  ORDER BY p."Name"
                ),
                '[]'::jsonb
              )
              FROM public.competition_player_injuries i
              LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id::text
              LEFT JOIN public.competition_injury_catalogue cat ON cat.id = i.catalogue_id
              WHERE i.source_fixture_id = f.id
                AND i.club_short_name = v_club
            )
            ELSE '[]'::jsonb
          END AS match_injuries
        FROM public.competition_fixtures f
        JOIN public.competition_seasons s ON s.id = f.season_id
        JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
        JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
        LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
        WHERE s.is_current = true
          AND (
            f.home_club_short_name = v_club
            OR f.away_club_short_name = v_club
          )
      ) t
    ),
    '[]'::jsonb
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_fixtures_my_club() TO authenticated;

COMMENT ON FUNCTION public.club_fixtures_my_club() IS
  'Current-season fixtures for the logged-in club, including scorers, cards, and injuries.';

NOTIFY pgrst, 'reload schema';
