-- =============================================================================
-- Agreed on Discord: any day, any 30-minute kick-off (2026-11-08)
--
-- The Discord tab is for a time already agreed off-site, so it must not be
-- limited to weekly availability overlap. This check still requires:
--   • a UK 30-minute boundary
--   • a future kick-off inside the fixture’s GPSL month window
--   • no double-book for either club
-- GPSL propose / accept / poke still use the availability rules.
--
-- Safe re-run. Run in the Supabase SQL editor. Does not lock a fixture.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_assert_discord_kickoff_ok(
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
  v_unlock timestamptz;
  v_lock timestamptz;
  v_window_month text;
  v_is_catch_up boolean;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
      AND f.status = 'scheduled'
  ) THEN
    RAISE EXCEPTION 'Fixture is not open for scheduling';
  END IF;

  IF p_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time is required';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff) THEN
    RAISE EXCEPTION 'Kick-off must be on a 30-minute boundary (UK time)';
  END IF;

  IF p_kickoff <= now() THEN
    RAISE EXCEPTION 'That kick-off time has already passed';
  END IF;

  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up
  INTO v_unlock, v_lock, v_window_month, v_is_catch_up
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
      RAISE EXCEPTION 'Catch-up scheduling opens when the current GPSL month is active';
    END IF;
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF p_kickoff < v_unlock OR p_kickoff + interval '30 minutes' > v_lock THEN
    IF coalesce(v_is_catch_up, false) THEN
      RAISE EXCEPTION 'Catch-up kick-off must fall within GPSL % (% – % UK)',
        public.competition_gpsl_month_label(v_window_month),
        public.match_schedule_format_kickoff_uk(v_unlock),
        public.match_schedule_format_kickoff_uk(v_lock);
    END IF;
    RAISE EXCEPTION 'Kick-off must fall within the GPSL month window (% – % UK)',
      public.match_schedule_format_kickoff_uk(v_unlock),
      public.match_schedule_format_kickoff_uk(v_lock);
  END IF;

  IF to_regprocedure('public.match_schedule_assert_kickoff_not_double_booked(bigint,timestamptz)') IS NOT NULL THEN
    PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff);
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_assert_discord_kickoff_ok(bigint, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_assert_discord_kickoff_ok(bigint, timestamptz)
  TO authenticated, service_role;

-- Point the pre-agree Discord lock at the new check. Leave post-agree
-- mutual "new time" on the availability check.
DO $discord_req$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure(
    'public.fixture_mutual_override_request(bigint,text,timestamp with time zone)'
  );
  IF v_oid IS NULL THEN
    v_oid := to_regprocedure(
      'public.fixture_mutual_override_request(bigint,text,timestamptz)'
    );
  END IF;
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'fixture_mutual_override_request missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('match_schedule_assert_discord_kickoff_ok' IN v_def) > 0 THEN
    RAISE NOTICE 'Discord lock already skips weekly availability';
    RETURN;
  END IF;

  v_old :=
    'PERFORM public.match_schedule_assert_mutual_kickoff_ok(p_fixture_id, p_kickoff_at);'
    || E'\n    v_kickoff := p_kickoff_at;';
  v_new :=
    'PERFORM public.match_schedule_assert_discord_kickoff_ok(p_fixture_id, p_kickoff_at);'
    || E'\n    v_kickoff := p_kickoff_at;';

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Could not find the Discord lock kickoff check in fixture_mutual_override_request';
  END IF;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
  RAISE NOTICE 'Discord lock now accepts any 30-minute kick-off in the month window';
END;
$discord_req$;

NOTIFY pgrst, 'reload schema';

SELECT
  (to_regprocedure('public.match_schedule_assert_discord_kickoff_ok(bigint,timestamptz)') IS NOT NULL)
    AS discord_assert,
  (position(
    'match_schedule_assert_discord_kickoff_ok'
    IN pg_get_functiondef(
      'public.fixture_mutual_override_request(bigint,text,timestamptz)'::regprocedure
    )
  ) > 0) AS request_uses_discord_assert;
