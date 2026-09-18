-- =============================================================================
-- Match Centre / match report — full box score for a fixture
-- Used by match_report.html (line-ups, scorers, cards, injuries, attendance).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_match_report(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fx record;
  v_home_players jsonb;
  v_away_players jsonb;
  v_injuries jsonb;
  v_attendance int;
  v_capacity int;
BEGIN
  IF p_fixture_id IS NULL THEN
    RAISE EXCEPTION 'fixture_id required';
  END IF;

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
    f.home_club_short_name,
    hc."Club" AS home_club_name,
    hc."Stadium" AS home_stadium,
    f.away_club_short_name,
    ac."Club" AS away_club_name,
    f.home_goals,
    f.away_goals,
    f.status,
    f.is_forfeit,
    f.weather,
    f.pitch_condition,
    sch.agreed_kickoff_at,
    sch.status AS schedule_status
  INTO v_fx
  FROM public.competition_fixtures f
  JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
  JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
  LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
  WHERE f.id = p_fixture_id;

  IF v_fx IS NULL THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT coalesce(
    jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_key, x.player_name),
    '[]'::jsonb
  )
  INTO v_home_players
  FROM (
    SELECT
      m.player_id,
      coalesce(p."Name", m.player_id) AS player_name,
      coalesce(m.appeared, false) AS appeared,
      coalesce(m.started, false) AS started,
      coalesce(m.subbed_on, false) AS subbed_on,
      coalesce(m.goals, 0) AS goals,
      coalesce(m.own_goals, 0) AS own_goals,
      coalesce(m.assists, 0) AS assists,
      m.rating,
      coalesce(m.is_player_of_match, false) AS is_player_of_match,
      coalesce(m.yellow_card, false) AS yellow_card,
      coalesce(m.red_card, false) AS red_card,
      CASE
        WHEN coalesce(m.started, false) THEN 0
        WHEN coalesce(m.subbed_on, false) THEN 1
        ELSE 2
      END AS sort_key
    FROM public.competition_match_player_stats m
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = v_fx.home_club_short_name
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
        OR coalesce(m.goals, 0) > 0
        OR coalesce(m.assists, 0) > 0
        OR coalesce(m.yellow_card, false)
        OR coalesce(m.red_card, false)
        OR coalesce(m.is_player_of_match, false)
      )
  ) x;

  SELECT coalesce(
    jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_key, x.player_name),
    '[]'::jsonb
  )
  INTO v_away_players
  FROM (
    SELECT
      m.player_id,
      coalesce(p."Name", m.player_id) AS player_name,
      coalesce(m.appeared, false) AS appeared,
      coalesce(m.started, false) AS started,
      coalesce(m.subbed_on, false) AS subbed_on,
      coalesce(m.goals, 0) AS goals,
      coalesce(m.own_goals, 0) AS own_goals,
      coalesce(m.assists, 0) AS assists,
      m.rating,
      coalesce(m.is_player_of_match, false) AS is_player_of_match,
      coalesce(m.yellow_card, false) AS yellow_card,
      coalesce(m.red_card, false) AS red_card,
      CASE
        WHEN coalesce(m.started, false) THEN 0
        WHEN coalesce(m.subbed_on, false) THEN 1
        ELSE 2
      END AS sort_key
    FROM public.competition_match_player_stats m
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = v_fx.away_club_short_name
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
        OR coalesce(m.goals, 0) > 0
        OR coalesce(m.assists, 0) > 0
        OR coalesce(m.yellow_card, false)
        OR coalesce(m.red_card, false)
        OR coalesce(m.is_player_of_match, false)
      )
  ) x;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', i.player_id,
        'player_name', coalesce(p."Name", i.player_id::text),
        'club_short_name', i.club_short_name,
        'label', coalesce(nullif(btrim(i.label), ''), cat.name, 'Injury'),
        'severity', coalesce(i.severity, cat.severity)
      )
      ORDER BY i.club_short_name, p."Name"
    ),
    '[]'::jsonb
  )
  INTO v_injuries
  FROM public.competition_player_injuries i
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id::text
  LEFT JOIN public.competition_injury_catalogue cat ON cat.id = i.catalogue_id
  WHERE i.source_fixture_id = p_fixture_id;

  SELECT
    round(
      (l.metadata ->> 'capacity')::numeric
      * (l.metadata ->> 'attendance_rate')::numeric
    )::int,
    nullif(l.metadata ->> 'capacity', '')::int
  INTO v_attendance, v_capacity
  FROM public.competition_finance_ledger l
  WHERE l.fixture_id = p_fixture_id
    AND l.entry_type = 'gate_league_home'
  LIMIT 1;

  RETURN jsonb_build_object(
    'fixture', jsonb_build_object(
      'id', v_fx.id,
      'season_id', v_fx.season_id,
      'division', v_fx.division,
      'competition_type', v_fx.competition_type,
      'cup_code', v_fx.cup_code,
      'cup_round', v_fx.cup_round,
      'cup_match', v_fx.cup_match,
      'matchday', v_fx.matchday,
      'gpsl_month', v_fx.gpsl_month,
      'home_club_short_name', v_fx.home_club_short_name,
      'home_club_name', v_fx.home_club_name,
      'home_stadium', v_fx.home_stadium,
      'away_club_short_name', v_fx.away_club_short_name,
      'away_club_name', v_fx.away_club_name,
      'home_goals', v_fx.home_goals,
      'away_goals', v_fx.away_goals,
      'status', v_fx.status,
      'is_forfeit', v_fx.is_forfeit,
      'weather', v_fx.weather,
      'pitch_condition', v_fx.pitch_condition,
      'agreed_kickoff_at', v_fx.agreed_kickoff_at,
      'schedule_status', v_fx.schedule_status
    ),
    'home_players', coalesce(v_home_players, '[]'::jsonb),
    'away_players', coalesce(v_away_players, '[]'::jsonb),
    'injuries', coalesce(v_injuries, '[]'::jsonb),
    'attendance', v_attendance,
    'capacity', v_capacity,
    'has_stats', (
      jsonb_array_length(coalesce(v_home_players, '[]'::jsonb))
      + jsonb_array_length(coalesce(v_away_players, '[]'::jsonb))
    ) > 0
  );
END;
$function$;

COMMENT ON FUNCTION public.competition_match_report(bigint) IS
  'Full match centre payload: both clubs'' line-ups/stats, injuries, attendance.';

GRANT EXECUTE ON FUNCTION public.competition_match_report(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_report(bigint) TO anon;

NOTIFY pgrst, 'reload schema';
