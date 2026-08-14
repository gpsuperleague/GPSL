-- =============================================================================
-- My Club Fixtures — "Added to calendar" manual tick (per club, per fixture)
--
-- Persists for the season (rows CASCADE when fixtures/season are wiped).
-- Only the logged-in owner of a club in the fixture can set their own tick.
--
-- Run after club_fixtures_discipline_injuries.sql (or latest club_fixtures_my_club).
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_fixture_calendar_mark (
  fixture_id bigint NOT NULL
    REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName"),
  season_id bigint NOT NULL
    REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  marked_at timestamptz NOT NULL DEFAULT now(),
  marked_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  PRIMARY KEY (fixture_id, club_short_name)
);

CREATE INDEX IF NOT EXISTS competition_fixture_calendar_mark_club_idx
  ON public.competition_fixture_calendar_mark (club_short_name, season_id);

ALTER TABLE public.competition_fixture_calendar_mark ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_fixture_calendar_mark_select
  ON public.competition_fixture_calendar_mark;
CREATE POLICY competition_fixture_calendar_mark_select
  ON public.competition_fixture_calendar_mark
  FOR SELECT TO authenticated
  USING (
    club_short_name = public.my_club_shortname()
    OR public.is_gpsl_admin()
  );

GRANT SELECT ON public.competition_fixture_calendar_mark TO authenticated;

CREATE OR REPLACE FUNCTION public.club_fixture_calendar_mark_set(
  p_fixture_id bigint,
  p_added boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures;
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF coalesce(p_added, false) THEN
    INSERT INTO public.competition_fixture_calendar_mark (
      fixture_id, club_short_name, season_id, marked_at, marked_by
    )
    VALUES (
      p_fixture_id, v_club, v_fixture.season_id, now(), auth.uid()
    )
    ON CONFLICT (fixture_id, club_short_name) DO UPDATE
    SET marked_at = now(),
        marked_by = excluded.marked_by;
  ELSE
    DELETE FROM public.competition_fixture_calendar_mark
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_club;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'club_short_name', v_club,
    'calendar_added', coalesce(p_added, false)
  );
END;
$function$;

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
          EXISTS (
            SELECT 1
            FROM public.competition_fixture_calendar_mark m
            WHERE m.fixture_id = f.id
              AND m.club_short_name = v_club
          ) AS calendar_added,
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

GRANT EXECUTE ON FUNCTION public.club_fixture_calendar_mark_set(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_fixtures_my_club() TO authenticated;

COMMENT ON FUNCTION public.club_fixture_calendar_mark_set(bigint, boolean) IS
  'Owner-only: tick/untick Added to calendar for your club on a fixture (season-scoped).';

NOTIFY pgrst, 'reload schema';
