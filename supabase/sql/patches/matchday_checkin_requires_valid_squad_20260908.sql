-- =============================================================================
-- Check-in requires a valid saved matchday squad for that fixture
--
-- Blocks check-in when the saved squad is missing, incomplete, or still contains
-- players unavailable for the upcoming fixture due to suspension or injury.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_matchday_checkin_ready(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures%rowtype;
  v_total int := 0;
  v_pitch int := 0;
  v_bench int := 0;
  v_reserve int := 0;
  v_gk int := 0;
  v_u21 int := 0;
  v_hg_xi int := 0;
  v_hg_total int := 0;
  v_issues text[] := ARRAY[]::text[];
  v_unavailable text[] := ARRAY[]::text[];
  r record;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  FOR r IN
    SELECT
      sp.player_id,
      sp.slot_kind,
      p."Name" AS player_name,
      p."Age" AS age,
      upper(btrim(coalesce(p."Position", ''))) AS pos,
      coalesce(public.is_player_homegrown(sp.player_id, v_club), false) AS is_hg,
      public.competition_player_unavailable_for_fixture(p_fixture_id, sp.player_id) AS unavailable_detail
    FROM public.club_matchday_squad_player sp
    JOIN public."Players" p
      ON p."Konami_ID"::text = sp.player_id
    WHERE sp.club_short_name = v_club
  LOOP
    v_total := v_total + 1;
    IF r.slot_kind = 'pitch' THEN
      v_pitch := v_pitch + 1;
    ELSIF r.slot_kind = 'bench' THEN
      v_bench := v_bench + 1;
    ELSE
      v_reserve := v_reserve + 1;
    END IF;

    IF r.pos IN ('GK', 'GOALKEEPER') THEN
      v_gk := v_gk + 1;
    END IF;
    IF r.age IS NOT NULL AND r.age <= 21 THEN
      v_u21 := v_u21 + 1;
    END IF;
    IF r.is_hg THEN
      v_hg_total := v_hg_total + 1;
      IF r.slot_kind = 'pitch' THEN
        v_hg_xi := v_hg_xi + 1;
      END IF;
    END IF;

    IF r.unavailable_detail IS NOT NULL AND btrim(r.unavailable_detail) <> '' THEN
      v_unavailable := array_append(
        v_unavailable,
        coalesce(nullif(btrim(r.player_name), ''), r.player_id) || ' (' || r.unavailable_detail || ')'
      );
    END IF;
  END LOOP;

  IF v_total = 0 THEN
    v_issues := array_append(v_issues, 'Save your matchday squad before check-in.');
  END IF;
  IF v_pitch <> 11 THEN
    v_issues := array_append(v_issues, format('Your saved matchday XI must have exactly 11 starters (currently %s).', v_pitch));
  END IF;
  IF v_bench > 12 THEN
    v_issues := array_append(v_issues, format('Your saved matchday bench can have at most 12 players (currently %s).', v_bench));
  END IF;
  IF v_reserve > 0 THEN
    v_issues := array_append(v_issues, 'Reserves are not allowed in the saved matchday squad.');
  END IF;
  IF v_gk < 1 THEN
    v_issues := array_append(v_issues, 'Your saved matchday squad needs at least 1 goalkeeper.');
  END IF;
  IF v_u21 < 2 THEN
    v_issues := array_append(v_issues, 'Your saved matchday squad needs at least 2 under-21 players.');
  END IF;
  IF v_hg_xi < 2 THEN
    v_issues := array_append(v_issues, 'Your saved starting XI needs at least 2 home-grown players.');
  END IF;
  IF v_hg_total < 5 THEN
    v_issues := array_append(v_issues, 'Your saved matchday squad needs at least 5 home-grown players.');
  END IF;
  IF coalesce(array_length(v_unavailable, 1), 0) > 0 THEN
    v_issues := array_append(
      v_issues,
      'Remove injured or suspended players from your saved matchday squad: ' || array_to_string(v_unavailable, ', ')
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', coalesce(array_length(v_issues, 1), 0) = 0,
    'club_short_name', v_club,
    'fixture_id', p_fixture_id,
    'issues', to_jsonb(v_issues),
    'counts', jsonb_build_object(
      'total', v_total,
      'pitch', v_pitch,
      'bench', v_bench,
      'reserve', v_reserve,
      'gk', v_gk,
      'u21', v_u21,
      'hg_xi', v_hg_xi,
      'hg_total', v_hg_total
    )
  );
END;
$function$;

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

  v_ready := public.club_matchday_checkin_ready(p_fixture_id);
  IF coalesce((v_ready->>'ok')::boolean, false) = false THEN
    SELECT value::text
    INTO v_issue
    FROM jsonb_array_elements_text(coalesce(v_ready->'issues', '[]'::jsonb))
    LIMIT 1;
    RAISE EXCEPTION '%', coalesce(v_issue, 'Saved matchday squad is not ready for this fixture.');
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time is not agreed yet';
  END IF;

  v_window_open := public.match_schedule_checkin_opens_at(v_kickoff);
  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;

  IF now() < v_window_open THEN
    RAISE EXCEPTION 'Check-in opens at %', public.match_schedule_format_kickoff_uk(v_window_open);
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

GRANT EXECUTE ON FUNCTION public.fixture_check_in(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
