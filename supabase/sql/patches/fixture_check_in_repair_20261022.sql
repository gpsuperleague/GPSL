-- =============================================================================
-- Repair: fixture_check_in RPC missing (PostgREST 404) — 2026-10-22
-- =============================================================================
-- Console: POST .../rpc/fixture_check_in → 404 Not Found
-- That is NOT a July calendar block. Ready-for-August only starts at August unlock.
-- This recreates check-in + readiness helper, grants execute, reloads PostgREST.
-- Safe re-run. Prefer after match_scheduling / matchday squad patches exist.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_fixture_checkin (
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName"),
  checked_in_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fixture_id, club_short_name)
);

-- Helpers used by check-in (no-ops / safe defaults if older defs already exist)
CREATE OR REPLACE FUNCTION public.match_schedule_checkin_minutes()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 10; $$;

CREATE OR REPLACE FUNCTION public.match_schedule_checkin_open_before_minutes()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 10; $$;

CREATE OR REPLACE FUNCTION public.match_schedule_checkin_opens_at(p_kickoff timestamptz)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_kickoff IS NULL THEN NULL
    ELSE p_kickoff
      - (public.match_schedule_checkin_open_before_minutes() || ' minutes')::interval
  END;
$$;

GRANT EXECUTE ON FUNCTION public.match_schedule_checkin_minutes() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_checkin_open_before_minutes() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_checkin_opens_at(timestamptz) TO authenticated, anon, service_role;

-- Minimal readiness if the full helper is missing (squad patch preferred)
DO $ready$
BEGIN
  IF to_regprocedure('public.club_matchday_checkin_ready(bigint)') IS NOT NULL THEN
    RETURN;
  END IF;

  EXECUTE $fn$
CREATE FUNCTION public.club_matchday_checkin_ready(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $body$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures%rowtype;
  v_total int := 0;
  v_pitch int := 0;
  v_bench int := 0;
  v_gk int := 0;
  v_issues text[] := ARRAY[]::text[];
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF to_regclass('public.club_matchday_squad_player') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'issues', '[]'::jsonb);
  END IF;

  SELECT
    count(*)::int,
    count(*) FILTER (WHERE sp.slot_kind = 'pitch')::int,
    count(*) FILTER (WHERE sp.slot_kind = 'bench')::int,
    count(*) FILTER (
      WHERE upper(btrim(coalesce(p."Position", ''))) IN ('GK', 'GOALKEEPER')
    )::int
  INTO v_total, v_pitch, v_bench, v_gk
  FROM public.club_matchday_squad_player sp
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
  WHERE sp.club_short_name = v_club;

  IF v_total = 0 THEN
    v_issues := array_append(v_issues, 'Save your matchday squad before check-in.');
  END IF;
  IF v_pitch <> 11 THEN
    v_issues := array_append(
      v_issues,
      format('Your saved matchday XI must have exactly 11 starters (currently %s).', v_pitch)
    );
  END IF;
  IF v_bench > 12 THEN
    v_issues := array_append(
      v_issues,
      format('Your saved matchday bench can have at most 12 players (currently %s).', v_bench)
    );
  END IF;
  IF v_gk < 1 THEN
    v_issues := array_append(v_issues, 'Your saved matchday squad needs at least 1 goalkeeper.');
  END IF;

  RETURN jsonb_build_object(
    'ok', coalesce(array_length(v_issues, 1), 0) = 0,
    'club_short_name', v_club,
    'fixture_id', p_fixture_id,
    'issues', to_jsonb(v_issues)
  );
END;
$body$;
  $fn$;
END
$ready$;

GRANT EXECUTE ON FUNCTION public.club_matchday_checkin_ready(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.fixture_check_in(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_open timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_ready jsonb;
  v_issue text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  -- Ready-for-August only applies once August unlocks (no-op in July)
  IF to_regprocedure('public.gpsl_owner_ready_lock_reason(text)') IS NOT NULL THEN
    v_issue := public.gpsl_owner_ready_lock_reason(v_club);
    IF v_issue IS NOT NULL AND btrim(v_issue) <> '' THEN
      RAISE EXCEPTION '%', v_issue;
    END IF;
  END IF;

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for check-in';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF to_regprocedure('public.club_matchday_checkin_ready(bigint)') IS NOT NULL THEN
    v_ready := public.club_matchday_checkin_ready(p_fixture_id);
    IF coalesce((v_ready->>'ok')::boolean, false) = false THEN
      SELECT value::text
      INTO v_issue
      FROM jsonb_array_elements_text(coalesce(v_ready->'issues', '[]'::jsonb))
      LIMIT 1;
      RAISE EXCEPTION '%', coalesce(v_issue, 'Saved matchday squad is not ready for this fixture.');
    END IF;
  END IF;

  IF to_regprocedure('public.match_schedule_agreed_kickoff(bigint)') IS NULL THEN
    RAISE EXCEPTION 'Match scheduling helpers missing — run match scheduling SQL patches';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time is not agreed yet';
  END IF;

  v_window_open := public.match_schedule_checkin_opens_at(v_kickoff);
  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;

  IF now() < v_window_open THEN
    IF to_regprocedure('public.match_schedule_format_kickoff_uk(timestamptz)') IS NOT NULL THEN
      RAISE EXCEPTION 'Check-in opens at %', public.match_schedule_format_kickoff_uk(v_window_open);
    END IF;
    RAISE EXCEPTION 'Check-in is not open yet';
  END IF;

  IF now() >= v_window_end THEN
    IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
      PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
    END IF;
    RAISE EXCEPTION 'Check-in window has closed';
  END IF;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES (p_fixture_id, v_club)
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in
     AND to_regprocedure('public.match_schedule_clear_no_show(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'checked_in_at', now());
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_check_in(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fixture_check_in(bigint) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE 'fixture_check_in(bigint) ready — try check-in again (July does not block Ready-for-August).';
END $$;
