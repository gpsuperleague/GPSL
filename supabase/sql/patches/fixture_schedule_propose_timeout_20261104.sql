-- =============================================================================
-- FIX: fixture_schedule_propose → "canceling statement due to statement timeout"
--
-- Authenticated PostgREST statement_timeout = 8s. On long proposal windows
-- (e.g. DOR–COR Dec MD18 / fixture 9137: ~1000 club slots, ~900 mutuals):
--   • match_schedule_allow_free_propose walked the full intersection SRF (~3s+)
--     and was invoked multiple times from propose
--   • match_schedule_kickoff_is_compromise_midpoint CROSS JOINed window slots
--     and re-invoked the SRF inside NOT EXISTS (~10s), twice from propose
--
-- Fix:
--   1) allow_free_propose: early-exit loop (stop at first mutual)
--   2) compromise midpoint: materialize home/away slots once; exclusive×exclusive
--   3) fixture_schedule_propose: compute free/compromise once into locals
--   4) SET statement_timeout = 60s on propose (belt-and-suspenders)
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_allow_free_propose(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_cursor timestamptz;
  v_now timestamptz := now();
BEGIN
  -- Free propose / poke only when there is no future mutual slot.
  -- Early-exit false as soon as one mutual is found (do not materialize all).
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN true;
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL OR v_lock IS NULL THEN
    RETURN true;
  END IF;

  v_cursor := public.match_schedule_align_kickoff_up(greatest(v_unlock, v_now));

  WHILE v_cursor IS NOT NULL
    AND v_cursor + interval '30 minutes' <= v_lock
  LOOP
    IF v_cursor > v_now
       AND public.match_schedule_kickoff_is_slot(v_cursor)
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_fixture.home_club_short_name, v_cursor
           )
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_fixture.away_club_short_name, v_cursor
           )
       AND NOT public.match_schedule_club_busy_at(
             v_fixture.home_club_short_name, v_cursor, p_fixture_id, v_fixture.season_id
           )
       AND NOT public.match_schedule_club_busy_at(
             v_fixture.away_club_short_name, v_cursor, p_fixture_id, v_fixture.season_id
           )
    THEN
      RETURN false;
    END IF;
    v_cursor := v_cursor + interval '30 minutes';
  END LOOP;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_allow_free_propose(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_allow_free_propose(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_allow_free_propose(bigint) IS
  'True when fixture has no future mutual availability slots — propose may use a free poke time. Early-exits on first mutual.';

CREATE OR REPLACE FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_home text;
  v_away text;
  v_target timestamptz := public.match_schedule_snap_uk_half_hour(p_kickoff_at);
  v_home_slots timestamptz[];
  v_away_slots timestamptz[];
  v_home_only timestamptz[];
  v_away_only timestamptz[];
  h timestamptz;
  a timestamptz;
  v_gap double precision;
BEGIN
  IF p_fixture_id IS NULL OR v_target IS NULL THEN
    RETURN false;
  END IF;

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF v_home IS NULL OR v_away IS NULL THEN
    RETURN false;
  END IF;

  -- Materialize each club's window once (do NOT re-call SRF in nested EXISTS).
  SELECT coalesce(array_agg(s.kickoff_at ORDER BY s.kickoff_at), ARRAY[]::timestamptz[])
  INTO v_home_slots
  FROM public.match_schedule_club_window_slots(p_fixture_id, v_home) s;

  SELECT coalesce(array_agg(s.kickoff_at ORDER BY s.kickoff_at), ARRAY[]::timestamptz[])
  INTO v_away_slots
  FROM public.match_schedule_club_window_slots(p_fixture_id, v_away) s;

  -- Mutual exact times are never "compromise"
  IF v_target = ANY (v_home_slots) AND v_target = ANY (v_away_slots) THEN
    RETURN false;
  END IF;

  SELECT coalesce(array_agg(x), ARRAY[]::timestamptz[])
  INTO v_home_only
  FROM unnest(v_home_slots) AS x
  WHERE NOT (x = ANY (v_away_slots));

  SELECT coalesce(array_agg(x), ARRAY[]::timestamptz[])
  INTO v_away_only
  FROM unnest(v_away_slots) AS x
  WHERE NOT (x = ANY (v_home_slots));

  IF cardinality(v_home_only) = 0 OR cardinality(v_away_only) = 0 THEN
    RETURN false;
  END IF;

  -- Home-only × away-only pair under 2h: allow either endpoint OR novel midpoint
  FOREACH h IN ARRAY v_home_only LOOP
    FOREACH a IN ARRAY v_away_only LOOP
      v_gap := abs(extract(epoch FROM (h - a)));
      IF v_gap > 0 AND v_gap < 7200 THEN
        IF v_target = h OR v_target = a THEN
          RETURN true;
        END IF;
        IF public.match_schedule_snap_uk_half_hour(h + ((a - h) / 2)) = v_target
           AND NOT (v_target = ANY (v_home_slots))
           AND NOT (v_target = ANY (v_away_slots))
        THEN
          RETURN true;
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(bigint, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(bigint, timestamptz)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(bigint, timestamptz) IS
  'True when kick-off is a UI compromise chip (exclusive endpoints under 2h or novel UK half-hour midpoint). Materializes window slots once.';

-- ---------------------------------------------------------------------------
-- fixture_schedule_propose: cache free/compromise; raise statement_timeout
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fixture_schedule_propose(
  p_fixture_id bigint,
  p_kickoff_at timestamp with time zone
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '60s'
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_opponent text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_proposal_id bigint;
  v_title text;
  v_body text;
  v_fmt text;
  v_is_counter boolean;
  v_free_propose boolean;
  v_is_compromise boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RAISE EXCEPTION 'Both clubs have GPSL match system OFF — arrange this fixture off-site (no in-app propose).';
  END IF;

  v_club_name := public.club_display_name(v_club);

  v_fixture := public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);

  IF public.match_schedule_kickoff_already_proposed(p_fixture_id, p_kickoff_at) THEN
    RAISE EXCEPTION 'That kick-off was already suggested in this arrangement — pick a different time';
  END IF;

  -- Compute once — these were the timeout hot path on long windows
  v_free_propose := public.match_schedule_allow_free_propose(p_fixture_id);
  v_is_compromise := (NOT v_free_propose)
    AND public.match_schedule_kickoff_is_compromise_midpoint(p_fixture_id, p_kickoff_at);

  IF NOT v_free_propose
     AND NOT v_is_compromise
     AND NOT public.match_schedule_club_available_at(
           v_fixture.season_id, v_club, p_kickoff_at
         )
  THEN
    RAISE EXCEPTION 'You are not available at that time — set weekly availability on Owner Details first';
  END IF;

  IF NOT v_free_propose
     AND NOT v_is_compromise
     AND (to_regprocedure('public.competition_club_is_vacant(text)') IS NULL
      OR NOT public.competition_club_is_vacant(
           CASE
             WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
             ELSE v_fixture.home_club_short_name
           END
         ))
     AND NOT public.match_schedule_club_available_at(
           v_fixture.season_id,
           CASE
             WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
             ELSE v_fixture.home_club_short_name
           END,
           p_kickoff_at
         )
  THEN
    RAISE EXCEPTION
      'That time is not free for both clubs — pick a compatible slot from times that overlap both owners'' local availability';
  END IF;

  PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff_at);

  v_schedule := public.match_schedule_ensure_row(p_fixture_id);
  v_is_counter := v_schedule.status <> 'unscheduled';

  IF v_schedule.status = 'agreed' THEN
    RAISE EXCEPTION 'Kick-off is already agreed for this fixture';
  END IF;

  IF v_schedule.status = 'unscheduled' THEN
    IF v_club <> v_fixture.home_club_short_name
       AND NOT public.match_schedule_club_opened_reschedule(p_fixture_id, v_club)
    THEN
      RAISE EXCEPTION 'Home club must propose the first kick-off time (or the club that dropped the previous agreed time)';
    END IF;
  ELSE
    IF v_schedule.pending_proposal_id IS NULL THEN
      RAISE EXCEPTION 'No pending proposal to respond to';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.competition_fixture_schedule_proposal p
      WHERE p.id = v_schedule.pending_proposal_id
        AND p.proposed_by_club_short_name = v_club
    ) THEN
      RAISE EXCEPTION 'Wait for your opponent to respond to your proposal';
    END IF;
  END IF;

  IF v_schedule.pending_proposal_id IS NOT NULL THEN
    UPDATE public.competition_fixture_schedule_proposal
    SET status = 'superseded'
    WHERE id = v_schedule.pending_proposal_id
      AND status = 'pending';
  END IF;

  INSERT INTO public.competition_fixture_schedule_proposal (
    fixture_id, proposed_by_club_short_name, kickoff_at, status
  )
  VALUES (p_fixture_id, v_club, p_kickoff_at, 'pending')
  RETURNING id INTO v_proposal_id;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'negotiating',
    pending_proposal_id = v_proposal_id,
    home_proposal_count = home_proposal_count + CASE WHEN v_club = v_fixture.home_club_short_name THEN 1 ELSE 0 END,
    away_proposal_count = away_proposal_count + CASE WHEN v_club = v_fixture.away_club_short_name THEN 1 ELSE 0 END,
    discord_hint_shown = (
      (home_proposal_count + CASE WHEN v_club = v_fixture.home_club_short_name THEN 1 ELSE 0 END) >= 2
      AND (away_proposal_count + CASE WHEN v_club = v_fixture.away_club_short_name THEN 1 ELSE 0 END) >= 2
    ),
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  IF to_regprocedure('public.match_schedule_set_response_deadline(bigint, bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_set_response_deadline(p_fixture_id, v_proposal_id);
  END IF;

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);
  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff_at);
  v_title := CASE
    WHEN NOT v_is_counter AND v_free_propose
      THEN 'Availability poke'
    WHEN NOT v_is_counter THEN 'Match time proposed'
    WHEN v_free_propose
      THEN 'Availability poke (counter)'
    ELSE 'Counter-proposal received'
  END;
  v_body := v_club_name || CASE
    WHEN v_free_propose
      THEN ' poked a kick-off outside mutual availability: '
    ELSE ' proposed '
  END || v_fmt || E'.\nOpen Schedule to accept, counter, or update your weekly availability.';

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    CASE WHEN NOT v_is_counter THEN 'match_time_proposed' ELSE 'match_time_countered' END,
    v_title,
    v_body,
    v_opponent,
    'prop:' || v_proposal_id::text || ':' || v_opponent,
    v_proposal_id
  );

  IF to_regprocedure(
       'public.match_schedule_notify_proposer_sent(public.competition_fixtures, text, text, timestamptz, bigint, boolean)'
     ) IS NOT NULL
  THEN
    PERFORM public.match_schedule_notify_proposer_sent(
      v_fixture,
      v_club,
      v_opponent,
      p_kickoff_at,
      v_proposal_id,
      v_is_counter
    );
  END IF;

  RETURN v_proposal_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_schedule_propose(bigint, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_schedule_propose(bigint, timestamptz)
  TO authenticated, service_role;

-- Verify
SELECT
  (SELECT proconfig
     FROM pg_proc
    WHERE oid = 'public.fixture_schedule_propose(bigint,timestamptz)'::regprocedure
  ) AS propose_config,
  (position('v_free_propose' IN pg_get_functiondef(
     'public.fixture_schedule_propose(bigint,timestamptz)'::regprocedure
   )) > 0) AS propose_caches_free,
  (position('Materialize' IN pg_get_functiondef(
     'public.match_schedule_kickoff_is_compromise_midpoint(bigint,timestamptz)'::regprocedure
   )) > 0) AS compromise_materializes,
  (position('Early-exit' IN pg_get_functiondef(
     'public.match_schedule_allow_free_propose(bigint)'::regprocedure
   )) > 0
   OR position('Early-exits' IN
        (SELECT obj_description(
           'public.match_schedule_allow_free_propose(bigint)'::regprocedure, 'pg_proc'))
      ) > 0) AS free_early_exit_comment;
