-- =============================================================================
-- Championship A: start with a partly-owned division, swap in new owners
-- until Championship A fixtures are drawn (2026-10-05)
--
-- Flow:
--   1) Assign from owners: priority 1–20 → Super League, 21–40 → Championship A
--      (any number, no 10-minimum), 41+ → standby. Fill Championship A up to 20
--      with unowned clubs by hand (division editor or swap tool).
--   2) Start the season (SL 20, Championship A 20 incl. unowned placeholders).
--   3) Draw Super League fixtures.
--   4) As new members win clubs: swap an owned club into Championship A in place
--      of an unowned one (keeps its table slot). Allowed until Championship A
--      league fixtures exist.
--   5) Draw Championship A fixtures before August → swaps lock.
--   Unowned Championship A clubs then lose 3–0 by walkover at each month lock
--   (vacant v vacant = void). Walkovers now pay gate + TV money like a played match.
--
-- Also: no arrangement fines / reminders / checklist items for fixtures that
-- involve an unowned club (they cannot be arranged).
--
-- Needs vacant_club_walkovers_20260930.sql. Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Assign from owners: 21–40 always → Championship A
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_assign_divisions_from_owners(
  p_season_id bigint,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owned int;
  v_tier2 int;
  v_tier3 int;
  v_use_b boolean;
  v_rows jsonb;
  v_counts jsonb;
  v_warnings text[] := ARRAY[]::text[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.competition_assert_setup_season(p_season_id);

  IF NOT p_dry_run THEN
    PERFORM public.competition_register_missing_clubs(p_season_id);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _owner_div_plan (
    club_short_name text PRIMARY KEY,
    club_name text,
    owner_id uuid,
    owner_tag text,
    owner_priority int,
    owner_source text,
    seq int,
    division text
  ) ON COMMIT DROP;
  TRUNCATE _owner_div_plan;

  INSERT INTO _owner_div_plan (club_short_name, club_name, owner_id, owner_tag, owner_priority, owner_source, seq, division)
  SELECT
    cs.club_short_name,
    coalesce(c."Club", cs.club_short_name),
    c.owner_id,
    coalesce(p.owner_tag, nullif(btrim(c.owner), ''), '—'),
    p.priority,
    p.source,
    CASE
      WHEN c.owner_id IS NULL THEN NULL
      ELSE row_number() OVER (
        PARTITION BY (c.owner_id IS NULL)
        ORDER BY p.priority NULLS LAST, cs.club_short_name
      )
    END::int,
    'unassigned'
  FROM public.competition_club_seasons cs
  JOIN public."Clubs" c ON c."ShortName" = cs.club_short_name
  LEFT JOIN public.competition_owner_league_priority() p ON p.owner_id = c.owner_id
  WHERE cs.season_id = p_season_id;

  SELECT count(*) INTO v_owned FROM _owner_div_plan WHERE owner_id IS NOT NULL;
  SELECT count(*) INTO v_tier2 FROM _owner_div_plan WHERE seq BETWEEN 21 AND 40;
  SELECT count(*) INTO v_tier3 FROM _owner_div_plan WHERE seq BETWEEN 41 AND 60;

  v_use_b := v_tier2 = 20 AND v_tier3 >= 10;

  UPDATE _owner_div_plan
  SET division = CASE
    WHEN seq IS NULL THEN 'unassigned'
    WHEN seq <= 20 THEN 'superleague'
    WHEN seq <= 40 THEN 'championship_a'
    WHEN seq BETWEEN 41 AND 60 AND v_use_b THEN 'championship_b'
    ELSE 'standby'
  END
  WHERE true;

  IF v_owned < 20 THEN
    v_warnings := array_append(v_warnings,
      format('Only %s owned clubs — the Super League needs 20. Run the club auction first.', v_owned));
  END IF;
  IF v_tier2 BETWEEN 1 AND 19 THEN
    v_warnings := array_append(v_warnings,
      format('Championship A has %s owned club(s) — add %s unowned club(s) to make 20 before starting / drawing fixtures. Swap owned clubs in later until Championship A fixtures are drawn.',
             v_tier2, 20 - v_tier2));
  END IF;
  IF v_use_b AND v_tier3 < 20 THEN
    v_warnings := array_append(v_warnings,
      format('Championship B has %s owned club(s) — fill to 20 with unowned clubs.', v_tier3));
  END IF;

  SELECT jsonb_build_object(
    'superleague', count(*) FILTER (WHERE division = 'superleague'),
    'championship_a', count(*) FILTER (WHERE division = 'championship_a'),
    'championship_b', count(*) FILTER (WHERE division = 'championship_b'),
    'standby', count(*) FILTER (WHERE division = 'standby'),
    'unassigned', count(*) FILTER (WHERE division = 'unassigned'),
    'owned', v_owned
  )
  INTO v_counts
  FROM _owner_div_plan;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'club', club_short_name,
    'club_name', club_name,
    'owner_tag', owner_tag,
    'owner_priority', owner_priority,
    'owner_source', owner_source,
    'seq', seq,
    'division', division
  ) ORDER BY seq NULLS LAST, club_short_name), '[]'::jsonb)
  INTO v_rows
  FROM _owner_div_plan
  WHERE owner_id IS NOT NULL;

  IF NOT p_dry_run THEN
    IF v_owned < 20 THEN
      RAISE EXCEPTION 'Only % owned clubs — the Super League needs 20', v_owned;
    END IF;

    UPDATE public.competition_club_seasons cs
    SET division = p.division,
        league_position = NULL
    FROM _owner_div_plan p
    WHERE cs.season_id = p_season_id
      AND cs.club_short_name = p.club_short_name;
  END IF;

  RETURN jsonb_build_object(
    'ok', v_owned >= 20,
    'dry_run', p_dry_run,
    'season_id', p_season_id,
    'counts', v_counts,
    'warnings', to_jsonb(v_warnings),
    'owned_clubs', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_assign_divisions_from_owners(bigint, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Championship status (for the admin swap panel)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_championship_status(
  p_season_id bigint,
  p_division text DEFAULT 'championship_a'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_div text := coalesce(nullif(btrim(p_division), ''), 'championship_a');
  v_status text;
  v_fixtures int;
  v_members jsonb;
  v_candidates jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.status INTO v_status FROM public.competition_seasons s WHERE s.id = p_season_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  SELECT count(*) INTO v_fixtures
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.division = v_div
    AND f.competition_type = 'league';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'club', cs.club_short_name,
    'club_name', coalesce(c."Club", cs.club_short_name),
    'owned', c.owner_id IS NOT NULL,
    'owner_tag', nullif(btrim(c.owner), ''),
    'slot', cs.league_position
  ) ORDER BY (c.owner_id IS NULL), coalesce(c."Club", cs.club_short_name)), '[]'::jsonb)
  INTO v_members
  FROM public.competition_club_seasons cs
  JOIN public."Clubs" c ON c."ShortName" = cs.club_short_name
  WHERE cs.season_id = p_season_id
    AND cs.division = v_div;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'club', c."ShortName",
    'club_name', coalesce(c."Club", c."ShortName"),
    'owner_tag', nullif(btrim(c.owner), ''),
    'division', coalesce(cs.division, 'not registered')
  ) ORDER BY coalesce(c."Club", c."ShortName")), '[]'::jsonb)
  INTO v_candidates
  FROM public."Clubs" c
  LEFT JOIN public.competition_club_seasons cs
    ON cs.season_id = p_season_id AND cs.club_short_name = c."ShortName"
  WHERE c.owner_id IS NOT NULL
    AND c."ShortName" <> 'FOREIGN'
    AND NOT coalesce(c.is_archived, false)
    AND coalesce(cs.division, 'unassigned') IN ('unassigned', 'standby');

  RETURN jsonb_build_object(
    'season_id', p_season_id,
    'season_status', v_status,
    'division', v_div,
    'fixtures_drawn', v_fixtures > 0,
    'fixture_count', v_fixtures,
    'club_count', jsonb_array_length(v_members),
    'owned_count', (SELECT count(*) FROM jsonb_array_elements(v_members) m WHERE (m->>'owned')::boolean),
    'members', v_members,
    'candidates', v_candidates
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_championship_status(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Swap: owned (or any non-league) club takes an unowned club's place
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_swap_championship_club(
  p_season_id bigint,
  p_out_club text,
  p_in_club text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
  v_out text := upper(btrim(coalesce(p_out_club, '')));
  v_in text := upper(btrim(coalesce(p_in_club, '')));
  v_out_div text;
  v_out_slot smallint;
  v_in_div text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.status INTO v_status FROM public.competition_seasons s WHERE s.id = p_season_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Season not found';
  END IF;
  IF v_status NOT IN ('setup', 'preseason', 'active') THEN
    RAISE EXCEPTION 'Season is % — swaps only before or during an active season', v_status;
  END IF;

  IF v_out = '' OR v_in = '' OR v_out = v_in THEN
    RAISE EXCEPTION 'Pick one club to take out and a different club to bring in';
  END IF;

  SELECT cs.division, cs.league_position INTO v_out_div, v_out_slot
  FROM public.competition_club_seasons cs
  WHERE cs.season_id = p_season_id AND upper(cs.club_short_name) = v_out;

  IF v_out_div IS NULL OR v_out_div NOT IN ('championship_a', 'championship_b') THEN
    RAISE EXCEPTION '% is not in Championship A or B this season', v_out;
  END IF;

  IF NOT public.competition_club_is_vacant(v_out) THEN
    RAISE EXCEPTION '% has an owner — only unowned clubs can be swapped out', v_out;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.division = v_out_div
      AND f.competition_type = 'league'
  ) THEN
    RAISE EXCEPTION '% fixtures are already drawn — swaps are locked',
      CASE v_out_div WHEN 'championship_a' THEN 'Championship A' ELSE 'Championship B' END;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_in
      AND c."ShortName" <> 'FOREIGN'
      AND NOT coalesce(c.is_archived, false)
  ) THEN
    RAISE EXCEPTION 'Club % not found (or archived)', v_in;
  END IF;

  SELECT cs.division INTO v_in_div
  FROM public.competition_club_seasons cs
  WHERE cs.season_id = p_season_id AND upper(cs.club_short_name) = v_in;

  IF v_in_div IS NULL THEN
    INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
    SELECT p_season_id, c."ShortName", 'unassigned'
    FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_in;
    v_in_div := 'unassigned';
  END IF;

  IF v_in_div NOT IN ('unassigned', 'standby') THEN
    RAISE EXCEPTION '% is already in a league division (%)', v_in, v_in_div;
  END IF;

  UPDATE public.competition_club_seasons
  SET division = 'unassigned', league_position = NULL
  WHERE season_id = p_season_id AND upper(club_short_name) = v_out;

  UPDATE public.competition_club_seasons
  SET division = v_out_div, league_position = v_out_slot
  WHERE season_id = p_season_id AND upper(club_short_name) = v_in;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'division', v_out_div,
    'out', v_out,
    'in', v_in,
    'slot', v_out_slot
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_swap_championship_club(bigint, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) Walkovers pay gate + TV like a played match
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_apply_vacant_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_home_vacant boolean;
  v_away_vacant boolean;
  v_loser text;
  v_winner text;
  v_low text;
  v_high text;
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled'
     OR v_f.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'not_applicable');
  END IF;

  v_home_vacant := public.competition_club_is_vacant(v_f.home_club_short_name);
  v_away_vacant := public.competition_club_is_vacant(v_f.away_club_short_name);

  IF NOT v_home_vacant AND NOT v_away_vacant THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'both_owned');
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by vacant-club walkover',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  IF v_home_vacant AND v_away_vacant AND v_f.competition_type = 'league' THEN
    UPDATE public.competition_fixtures
    SET status = 'played',
        is_void = true,
        home_goals = NULL,
        away_goals = NULL
    WHERE id = p_fixture_id;

    PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);

    RETURN jsonb_build_object('ok', true, 'fixture_id', p_fixture_id, 'result', 'void');
  END IF;

  IF v_home_vacant AND v_away_vacant THEN
    v_low := least(v_f.home_club_short_name, v_f.away_club_short_name);
    v_high := greatest(v_f.home_club_short_name, v_f.away_club_short_name);
    v_loser := CASE
      WHEN substr(md5(concat_ws(':', v_f.season_id, v_f.cup_code, v_low, v_high)), 1, 1) < '8'
      THEN v_low ELSE v_high
    END;
  ELSIF v_home_vacant THEN
    v_loser := v_f.home_club_short_name;
  ELSE
    v_loser := v_f.away_club_short_name;
  END IF;

  v_winner := CASE
    WHEN v_loser = v_f.home_club_short_name THEN v_f.away_club_short_name
    ELSE v_f.home_club_short_name
  END;

  UPDATE public.competition_fixtures
  SET home_goals = CASE WHEN v_winner = v_f.home_club_short_name THEN 3 ELSE 0 END,
      away_goals = CASE WHEN v_winner = v_f.away_club_short_name THEN 3 ELSE 0 END,
      status = 'played',
      is_forfeit = true,
      forfeit_loser_club = v_loser
  WHERE id = p_fixture_id;

  BEGIN
    PERFORM public.competition_settle_fixture_gates(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  IF to_regprocedure('public.competition_tv_settle_fixture(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_tv_settle_fixture(p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  IF v_f.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  ELSE
    PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);
  END IF;

  IF NOT public.competition_club_is_vacant(v_winner) THEN
    BEGIN
      v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Walkover win');
      v_body := public.competition_fixture_inbox_body(
        p_fixture_id,
        format('%s has no owner, so you win 3–0 by walkover.', public.club_display_name(v_loser))
      );
      PERFORM public.owner_inbox_send(
        'match_forfeit_applied', v_title, v_body,
        v_winner, NULL, p_fixture_id,
        NULL, NULL, NULL,
        'fixture_schedule.html?fixture=' || p_fixture_id::text,
        'vacant_walkover:' || p_fixture_id::text,
        v_f.gpsl_month, v_f.season_id, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'fixture_id', p_fixture_id, 'result', 'walkover',
    'winner', v_winner, 'loser', v_loser
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_apply_vacant_fixture_result(bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5) No arrangement fines for fixtures involving an unowned club
-- ---------------------------------------------------------------------------
DO $inject_fines$
DECLARE
  v_def text;
  v_marker text := '-- Suppress while home is on holiday overlapping the closed month';
  v_guard text := E'IF public.competition_fixture_involves_vacant_club(v_f.id) THEN\n'
    || E'      v_skipped := v_skipped + 1;\n'
    || E'      CONTINUE;\n'
    || E'    END IF;\n\n    ';
BEGIN
  SELECT pg_get_functiondef(
    'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
  ) INTO v_def;
  IF position('competition_fixture_involves_vacant_club' IN v_def) > 0 THEN
    RAISE NOTICE 'arrangement fines already skip vacant fixtures';
  ELSIF position(v_marker IN v_def) = 0 THEN
    RAISE WARNING 'arrangement fines: marker not found — vacant skip NOT applied';
  ELSE
    EXECUTE replace(v_def, v_marker, v_guard || v_marker);
  END IF;
END;
$inject_fines$;

-- ---------------------------------------------------------------------------
-- 6) Dashboard checklist ignores fixtures involving an unowned club
-- ---------------------------------------------------------------------------
DO $inject_checklist$
DECLARE
  v_def text;
  v_old text := 'AND f.status <> ''cancelled''';
  v_new text := 'AND f.status <> ''cancelled''' || E'\n      AND NOT public.competition_fixture_involves_vacant_club(f.id)';
BEGIN
  IF to_regprocedure('public.matchday_checklist_for_club(text,boolean)') IS NULL THEN
    RAISE NOTICE 'matchday_checklist_for_club not installed — skip';
    RETURN;
  END IF;
  SELECT pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure) INTO v_def;
  IF position('competition_fixture_involves_vacant_club' IN v_def) > 0 THEN
    RAISE NOTICE 'dashboard checklist already skips vacant fixtures';
  ELSIF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'dashboard checklist: filter line not found — vacant skip NOT applied';
  ELSE
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$inject_checklist$;

NOTIFY pgrst, 'reload schema';
