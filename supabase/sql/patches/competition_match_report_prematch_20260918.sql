-- =============================================================================
-- Match Centre pre-match preview (squads / formation / manager / playstyle)
--
-- Adds home_preview + away_preview to competition_match_report.
-- Safe re-run (includes own_goals ensure + full RPC refresh).
-- =============================================================================

SET lock_timeout = '15s';

ALTER TABLE public.competition_match_player_stats
  ADD COLUMN IF NOT EXISTS own_goals smallint NOT NULL DEFAULT 0;

DO $chk$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'competition_match_player_stats'
      AND c.conname = 'competition_match_player_stats_own_goals_check'
  ) THEN
    ALTER TABLE public.competition_match_player_stats
      ADD CONSTRAINT competition_match_player_stats_own_goals_check
      CHECK (own_goals >= 0);
  END IF;
END;
$chk$;

COMMENT ON COLUMN public.competition_match_player_stats.own_goals IS
  'Own goals by this player (against their club / for the opponent). Not counted in this club''s goals total.';

CREATE OR REPLACE FUNCTION public.manager_strongest_playstyle(p_manager public."Managers")
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_best record;
BEGIN
  IF p_manager IS NULL OR p_manager.id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT key, label, val
  INTO v_best
  FROM (
    VALUES
      ('possession', 'Possession', coalesce(p_manager.possession, 0)::int),
      ('quick_counter', 'Quick Counter', coalesce(p_manager.quick_counter, 0)::int),
      ('long_ball_counter', 'Long Ball Counter', coalesce(p_manager.long_ball_counter, 0)::int),
      ('out_wide', 'Out Wide', coalesce(p_manager.out_wide, 0)::int),
      ('long_ball', 'Long Ball', coalesce(p_manager.long_ball, 0)::int),
      ('overload', 'Overload', coalesce(p_manager.overload, 0)::int)
  ) AS t(key, label, val)
  ORDER BY val DESC, label ASC
  LIMIT 1;

  IF v_best IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'key', v_best.key,
    'label', v_best.label,
    'value', v_best.val
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_match_club_preview(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club, '')), '');
  v_layout jsonb;
  v_updated timestamptz;
  v_formation_id text;
  v_formation_name text;
  v_mgr public."Managers"%rowtype;
  v_xi jsonb := '[]'::jsonb;
  v_bench jsonb := '[]'::jsonb;
  v_has_squad boolean := false;
BEGIN
  IF v_club IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.pitch_layout, s.updated_at
  INTO v_layout, v_updated
  FROM public.club_matchday_squad s
  WHERE s.club_short_name = v_club;

  v_formation_id := nullif(btrim(coalesce(v_layout->>'formation_id', '')), '');

  IF v_layout IS NOT NULL THEN
    SELECT f.name
    INTO v_formation_name
    FROM public.club_matchday_saved_formation f
    WHERE f.club_short_name = v_club
      AND f.pitch_layout = v_layout
      AND nullif(btrim(coalesce(f.name, '')), '') IS NOT NULL
    ORDER BY f.slot_no
    LIMIT 1;
  END IF;

  IF v_formation_name IS NULL THEN
    v_formation_name := v_formation_id;
  END IF;

  SELECT m.*
  INTO v_mgr
  FROM public."Managers" m
  WHERE m.contracted_club = v_club
  LIMIT 1;

  IF NOT FOUND OR v_mgr.id IS NULL THEN
    SELECT m.*
    INTO v_mgr
    FROM public."Clubs" c
    JOIN public."Managers" m ON m.id = c.manager_id
    WHERE c."ShortName" = v_club
    LIMIT 1;
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', x.player_id,
        'player_name', x.player_name,
        'player_position', x.player_position,
        'pitch_slot', x.pitch_slot,
        'role_label', x.role_label
      )
      ORDER BY x.sort_key, x.sort_order, x.player_name
    ),
    '[]'::jsonb
  )
  INTO v_xi
  FROM (
    SELECT
      sp.player_id,
      coalesce(p."Name", sp.player_id) AS player_name,
      coalesce(p."Position", '') AS player_position,
      sp.pitch_slot,
      coalesce(
        nullif(btrim(v_layout -> sp.pitch_slot ->> 'label'), ''),
        sp.pitch_slot,
        p."Position",
        ''
      ) AS role_label,
      CASE sp.pitch_slot
        WHEN 'GK' THEN 0
        WHEN 'LB' THEN 1
        WHEN 'CB1' THEN 2
        WHEN 'CB2' THEN 3
        WHEN 'RB' THEN 4
        WHEN 'LMF' THEN 5
        WHEN 'CMF' THEN 6
        WHEN 'RMF' THEN 7
        WHEN 'LWF' THEN 8
        WHEN 'CF' THEN 9
        WHEN 'RWF' THEN 10
        ELSE 50
      END AS sort_key,
      sp.sort_order
    FROM public.club_matchday_squad_player sp
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id::text
    WHERE sp.club_short_name = v_club
      AND sp.slot_kind = 'pitch'
  ) x;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', x.player_id,
        'player_name', x.player_name,
        'player_position', x.player_position,
        'sort_order', x.sort_order,
        'role_label', x.role_label
      )
      ORDER BY x.sort_order, x.player_name
    ),
    '[]'::jsonb
  )
  INTO v_bench
  FROM (
    SELECT
      sp.player_id,
      coalesce(p."Name", sp.player_id) AS player_name,
      coalesce(p."Position", '') AS player_position,
      sp.sort_order,
      CASE
        WHEN sp.sort_order < 5 THEN 'Sub'
        ELSE 'Squad'
      END AS role_label
    FROM public.club_matchday_squad_player sp
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id::text
    WHERE sp.club_short_name = v_club
      AND sp.slot_kind IN ('bench', 'reserve')
  ) x;

  v_has_squad :=
    jsonb_array_length(coalesce(v_xi, '[]'::jsonb)) > 0
    OR jsonb_array_length(coalesce(v_bench, '[]'::jsonb)) > 0;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'has_squad', v_has_squad,
    'squad_updated_at', v_updated,
    'formation_id', v_formation_id,
    'formation_name', v_formation_name,
    'manager_id', v_mgr.id,
    'manager_name', v_mgr.name,
    'manager_rating', v_mgr.rating,
    'strongest_playstyle', public.manager_strongest_playstyle(v_mgr),
    'xi', coalesce(v_xi, '[]'::jsonb),
    'bench', coalesce(v_bench, '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.competition_match_club_preview(text) IS
  'Match Centre pre-match: Match Day XI/bench, formation, manager + strongest playstyle.';

GRANT EXECUTE ON FUNCTION public.manager_strongest_playstyle(public."Managers") TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_strongest_playstyle(public."Managers") TO anon;
GRANT EXECUTE ON FUNCTION public.competition_match_club_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_club_preview(text) TO anon;


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
  v_home_player_goals int := 0;
  v_away_player_goals int := 0;
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
        OR coalesce(m.own_goals, 0) > 0
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
        OR coalesce(m.own_goals, 0) > 0
        OR coalesce(m.assists, 0) > 0
        OR coalesce(m.yellow_card, false)
        OR coalesce(m.red_card, false)
        OR coalesce(m.is_player_of_match, false)
      )
  ) x;

  SELECT coalesce(sum((p ->> 'goals')::int), 0)
  INTO v_home_player_goals
  FROM jsonb_array_elements(coalesce(v_home_players, '[]'::jsonb)) p;

  SELECT coalesce(sum((p ->> 'goals')::int), 0)
  INTO v_away_player_goals
  FROM jsonb_array_elements(coalesce(v_away_players, '[]'::jsonb)) p;

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
    -- Opponent own goals credited on the scoreline (team score − goals by this club's players)
    'home_og_for', greatest(coalesce(v_fx.home_goals, 0) - v_home_player_goals, 0),
    'away_og_for', greatest(coalesce(v_fx.away_goals, 0) - v_away_player_goals, 0),
    'has_stats', (
      jsonb_array_length(coalesce(v_home_players, '[]'::jsonb))
      + jsonb_array_length(coalesce(v_away_players, '[]'::jsonb))
    ) > 0,
    'home_preview', public.competition_match_club_preview(v_fx.home_club_short_name),
    'away_preview', public.competition_match_club_preview(v_fx.away_club_short_name)
  );
END;
$function$;

COMMENT ON FUNCTION public.competition_match_report(bigint) IS
  'Full match centre payload: line-ups/stats, OG for/against, pre-match squad preview, injuries, attendance.';

GRANT EXECUTE ON FUNCTION public.competition_match_report(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_report(bigint) TO anon;

NOTIFY pgrst, 'reload schema';
