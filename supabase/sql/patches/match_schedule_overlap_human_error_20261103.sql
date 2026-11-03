-- =============================================================================
-- Human-friendly double-book overlap errors (2026-11-03)
-- =============================================================================
-- Old: "Tigres UANL already has a match overlapping that kick-off"
-- New: names the other fixture, kick-off (UK), and whether it's agreed or a
-- pending proposal (you proposed / waiting on them, or they proposed / your turn).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_club_busy_clash(
  p_club_short_name text,
  p_kickoff timestamptz,
  p_except_fixture_id bigint DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club_short_name), '');
  v_block integer := coalesce(public.match_schedule_block_minutes(), 30);
  r record;
  v_opp text;
  v_vs text;
  v_ko text;
  v_why text;
  v_awaiting text;
BEGIN
  IF v_club IS NULL OR p_kickoff IS NULL THEN
    RETURN jsonb_build_object('busy', false);
  END IF;

  -- Prefer an agreed KO clash first (harder booking)
  SELECT
    f.id AS fixture_id,
    f.home_club_short_name AS home,
    f.away_club_short_name AS away,
    f.competition_type,
    f.cup_code,
    f.matchday,
    s.agreed_kickoff_at AS kickoff_at
  INTO r
  FROM public.competition_fixture_schedule s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE s.status = 'agreed'
    AND s.agreed_kickoff_at IS NOT NULL
    AND f.status = 'scheduled'
    AND (p_except_fixture_id IS NULL OR f.id <> p_except_fixture_id)
    AND (p_season_id IS NULL OR f.season_id = p_season_id)
    AND v_club IN (f.home_club_short_name, f.away_club_short_name)
    AND public.match_schedule_intervals_overlap(
          s.agreed_kickoff_at, p_kickoff, v_block
        )
  ORDER BY s.agreed_kickoff_at
  LIMIT 1;

  IF FOUND THEN
    v_opp := CASE
      WHEN upper(r.home) = upper(v_club) THEN r.away
      ELSE r.home
    END;
    v_vs := CASE
      WHEN upper(r.home) = upper(v_club) THEN
        'vs ' || coalesce(public.club_display_name(v_opp), v_opp)
      ELSE
        '@ ' || coalesce(public.club_display_name(v_opp), v_opp)
    END;
    IF to_regprocedure('public.match_schedule_format_kickoff_uk(timestamptz)') IS NOT NULL THEN
      v_ko := public.match_schedule_format_kickoff_uk(r.kickoff_at);
    ELSE
      v_ko := to_char(r.kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon · HH24:MI') || ' UK';
    END IF;

    RETURN jsonb_build_object(
      'busy', true,
      'kind', 'agreed',
      'fixture_id', r.fixture_id,
      'vs', v_vs,
      'kickoff_uk', v_ko,
      'message', format(
        '%s already has a kick-off overlapping that time: %s (%s) — agreed kick-off.',
        coalesce(public.club_display_name(v_club), v_club),
        v_vs,
        v_ko
      )
    );
  END IF;

  -- Pending proposal clash
  SELECT
    f.id AS fixture_id,
    f.home_club_short_name AS home,
    f.away_club_short_name AS away,
    p.kickoff_at,
    p.proposed_by_club_short_name AS by_club
  INTO r
  FROM public.competition_fixture_schedule_proposal p
  JOIN public.competition_fixtures f ON f.id = p.fixture_id
  WHERE p.status = 'pending'
    AND p.kickoff_at IS NOT NULL
    AND f.status = 'scheduled'
    AND (p_except_fixture_id IS NULL OR f.id <> p_except_fixture_id)
    AND (p_season_id IS NULL OR f.season_id = p_season_id)
    AND v_club IN (f.home_club_short_name, f.away_club_short_name)
    AND public.match_schedule_intervals_overlap(
          p.kickoff_at, p_kickoff, v_block
        )
  ORDER BY p.created_at
  LIMIT 1;

  IF FOUND THEN
    v_opp := CASE
      WHEN upper(r.home) = upper(v_club) THEN r.away
      ELSE r.home
    END;
    v_vs := CASE
      WHEN upper(r.home) = upper(v_club) THEN
        'vs ' || coalesce(public.club_display_name(v_opp), v_opp)
      ELSE
        '@ ' || coalesce(public.club_display_name(v_opp), v_opp)
    END;
    IF to_regprocedure('public.match_schedule_format_kickoff_uk(timestamptz)') IS NOT NULL THEN
      v_ko := public.match_schedule_format_kickoff_uk(r.kickoff_at);
    ELSE
      v_ko := to_char(r.kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon · HH24:MI') || ' UK';
    END IF;

    IF upper(coalesce(r.by_club, '')) = upper(v_club) THEN
      v_awaiting := coalesce(public.club_display_name(v_opp), v_opp);
      v_why := format('you proposed; waiting for %s to accept', v_awaiting);
    ELSE
      v_awaiting := coalesce(public.club_display_name(r.by_club), r.by_club);
      v_why := format(
        '%s proposed; waiting for your acceptance',
        v_awaiting
      );
    END IF;

    RETURN jsonb_build_object(
      'busy', true,
      'kind', 'pending',
      'fixture_id', r.fixture_id,
      'vs', v_vs,
      'kickoff_uk', v_ko,
      'proposed_by', r.by_club,
      'message', format(
        '%s already has a kick-off overlapping that time: %s (%s) — pending proposal (%s).',
        coalesce(public.club_display_name(v_club), v_club),
        v_vs,
        v_ko,
        v_why
      )
    );
  END IF;

  RETURN jsonb_build_object('busy', false);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_club_busy_clash(text, timestamptz, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_club_busy_clash(text, timestamptz, bigint, bigint)
  TO authenticated, service_role;

-- Keep boolean helper in sync (used by slot filters)
CREATE OR REPLACE FUNCTION public.match_schedule_club_busy_at(
  p_club_short_name text,
  p_kickoff timestamptz,
  p_except_fixture_id bigint DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (public.match_schedule_club_busy_clash(
      p_club_short_name, p_kickoff, p_except_fixture_id, p_season_id
    ) ->> 'busy')::boolean,
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_kickoff_not_double_booked(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home jsonb;
  v_away jsonb;
  v_home_busy boolean;
  v_away_busy boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  v_home := public.match_schedule_club_busy_clash(
    v_fixture.home_club_short_name,
    p_kickoff,
    p_fixture_id,
    v_fixture.season_id
  );
  v_away := public.match_schedule_club_busy_clash(
    v_fixture.away_club_short_name,
    p_kickoff,
    p_fixture_id,
    v_fixture.season_id
  );

  v_home_busy := coalesce((v_home ->> 'busy')::boolean, false);
  v_away_busy := coalesce((v_away ->> 'busy')::boolean, false);

  IF v_home_busy AND v_away_busy THEN
    RAISE EXCEPTION '% · %',
      coalesce(v_home ->> 'message', 'Home club already has a match overlapping that kick-off'),
      coalesce(v_away ->> 'message', 'Away club already has a match overlapping that kick-off');
  END IF;
  IF v_home_busy THEN
    RAISE EXCEPTION '%',
      coalesce(
        v_home ->> 'message',
        format(
          '%s already has a match overlapping that kick-off',
          public.club_display_name(v_fixture.home_club_short_name)
        )
      );
  END IF;
  IF v_away_busy THEN
    RAISE EXCEPTION '%',
      coalesce(
        v_away ->> 'message',
        format(
          '%s already has a match overlapping that kick-off',
          public.club_display_name(v_fixture.away_club_short_name)
        )
      );
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_assert_kickoff_not_double_booked(bigint, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_assert_kickoff_not_double_booked(bigint, timestamptz)
  TO authenticated, service_role;
