-- =============================================================================
-- Protect owned clubs vs vacant / mid–play-month new-owner opponents
--
-- When your opponent is vacant (or season-absent), or receives a new owner
-- during this fixture's play month, scheduling deadlines for that fixture do
-- not apply to you: arrangement / reply fines & warnings, Club Wire cutoffs,
-- board F forecast, and no-show ladder bites.
--
-- Requires: vacant/absence helpers, new_owner_scheduling_fine_grace (owner_assigned_at),
--           arrangement + response fine enforcers, club_wire_cutoffs.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(
  p_fixture_id bigint,
  p_club text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_home text;
  v_away text;
  v_season bigint;
  v_play_month text;
  v_opp text;
  v_assigned timestamptz;
  v_unlock timestamptz;
  v_lock timestamptz;
BEGIN
  IF v_club = '' OR p_fixture_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    upper(btrim(f.home_club_short_name)),
    upper(btrim(f.away_club_short_name)),
    f.season_id,
    f.gpsl_month
  INTO v_home, v_away, v_season, v_play_month
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF v_home IS NULL THEN
    RETURN false;
  END IF;

  IF v_club = v_home THEN
    v_opp := v_away;
  ELSIF v_club = v_away THEN
    v_opp := v_home;
  ELSE
    RETURN false;
  END IF;

  -- Opponent vacant / season-absent (walkover path)
  IF to_regprocedure('public.competition_club_is_fixture_inactive(text,bigint)') IS NOT NULL THEN
    IF public.competition_club_is_fixture_inactive(v_opp, v_season) THEN
      RETURN true;
    END IF;
  ELSIF to_regprocedure('public.competition_club_is_vacant(text)') IS NOT NULL THEN
    IF public.competition_club_is_vacant(v_opp) THEN
      RETURN true;
    END IF;
  END IF;

  -- Opponent newly appointed during this fixture's play month
  SELECT c.owner_assigned_at
  INTO v_assigned
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = v_opp
  LIMIT 1;

  IF v_assigned IS NULL OR nullif(btrim(coalesce(v_play_month, '')), '') IS NULL OR v_season IS NULL THEN
    RETURN false;
  END IF;

  SELECT cal.unlock_at, cal.lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_season
    AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_play_month))
  LIMIT 1;

  IF v_unlock IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_assigned >= v_unlock
    AND (v_lock IS NULL OR v_assigned <= v_lock);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(bigint, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(bigint, text)
  TO authenticated, service_role, anon;

COMMENT ON FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(bigint, text) IS
  'True when deadlines/fines for this fixture should not apply to p_club because the opponent is vacant/absent or was newly appointed during the fixture play month.';

-- ---------------------------------------------------------------------------
-- Arrangement fines — skip when opponent vacant / new owner in play month
-- ---------------------------------------------------------------------------
DO $inj_arr$
DECLARE
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  IF to_regprocedure('public.competition_enforce_scheduling_arrangement_fines(bigint,text)') IS NULL THEN
    RAISE NOTICE 'arrangement fines missing — skip inject';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef(
      'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
    ),
    E'\r\n', E'\n'
  ) INTO v_def;

  IF position('match_schedule_fixture_deadlines_suppressed_for_club(v_f.id' IN v_def) > 0 THEN
    RAISE NOTICE 'arrangement fines already suppress vacant/new-opp';
    RETURN;
  END IF;

  v_needle := replace($n$    IF public.club_scheduling_fines_in_new_owner_grace(
      p_season_id, v_f.home_club_short_name, p_closed_gpsl_month
    ) THEN
      v_grace := v_grace + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');

  v_insert := replace($n$    IF public.club_scheduling_fines_in_new_owner_grace(
      p_season_id, v_f.home_club_short_name, p_closed_gpsl_month
    ) THEN
      v_grace := v_grace + 1;
      CONTINUE;
    END IF;

    IF to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
       AND public.match_schedule_fixture_deadlines_suppressed_for_club(
         v_f.id, v_f.home_club_short_name
       ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');

  IF position(v_needle IN v_def) = 0 THEN
    -- Fallback: after holiday suppress (pre–new-owner-grace deploys)
    v_needle := replace($n$    IF public.match_schedule_club_on_holiday_for_month(
      p_season_id, v_f.home_club_short_name, p_closed_gpsl_month
    ) THEN
      v_holiday := v_holiday + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');
    v_insert := replace($n$    IF public.match_schedule_club_on_holiday_for_month(
      p_season_id, v_f.home_club_short_name, p_closed_gpsl_month
    ) THEN
      v_holiday := v_holiday + 1;
      CONTINUE;
    END IF;

    IF to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
       AND public.match_schedule_fixture_deadlines_suppressed_for_club(
         v_f.id, v_f.home_club_short_name
       ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');
  END IF;

  IF position(v_needle IN v_def) = 0 THEN
    RAISE WARNING 'arrangement fines: inject needle not found — vacant/new-opp skip NOT applied';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_needle, v_insert);
  RAISE NOTICE 'arrangement fines: vacant/new-opp suppress injected';
END;
$inj_arr$;

-- ---------------------------------------------------------------------------
-- Response fines — skip warnings + fines for same cases
-- ---------------------------------------------------------------------------
DO $inj_resp$
DECLARE
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  IF to_regprocedure('public.competition_enforce_scheduling_response_fines(bigint,text)') IS NULL THEN
    RAISE NOTICE 'response fines missing — skip inject';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef(
      'public.competition_enforce_scheduling_response_fines(bigint,text)'::regprocedure
    ),
    E'\r\n', E'\n'
  ) INTO v_def;

  IF position(
    'match_schedule_fixture_deadlines_suppressed_for_club(v_row.fixture_id' IN v_def
  ) > 0 THEN
    RAISE NOTICE 'response fines already suppress vacant/new-opp';
    RETURN;
  END IF;

  v_needle := replace($n$    IF public.club_scheduling_fines_in_new_owner_grace(
      p_season_id, v_row.response_required_club_short_name, p_closed_gpsl_month
    ) THEN
      v_grace := v_grace + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');

  v_insert := replace($n$    IF public.club_scheduling_fines_in_new_owner_grace(
      p_season_id, v_row.response_required_club_short_name, p_closed_gpsl_month
    ) THEN
      v_grace := v_grace + 1;
      CONTINUE;
    END IF;

    IF to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
       AND public.match_schedule_fixture_deadlines_suppressed_for_club(
         v_row.fixture_id, v_row.response_required_club_short_name
       ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');

  IF position(v_needle IN v_def) = 0 THEN
    RAISE WARNING 'response fines: grace needle not found — vacant/new-opp skip NOT applied';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_needle, v_insert);
  RAISE NOTICE 'response fines: vacant/new-opp suppress injected';
END;
$inj_resp$;

-- ---------------------------------------------------------------------------
-- Response miss counter — do not bump when suppressed
-- ---------------------------------------------------------------------------
DO $inj_miss$
DECLARE
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  IF to_regprocedure('public.competition_process_scheduling_response_deadlines(bigint)') IS NULL THEN
    RAISE NOTICE 'response deadline processor missing — skip';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef(
      'public.competition_process_scheduling_response_deadlines(bigint)'::regprocedure
    ),
    E'\r\n', E'\n'
  ) INTO v_def;

  IF position('match_schedule_fixture_deadlines_suppressed_for_club' IN v_def) > 0 THEN
    RAISE NOTICE 'response deadline processor already suppresses';
    RETURN;
  END IF;

  -- Prefer filtering in the SELECT when response_required column is selected
  IF position('s.response_required_club_short_name' IN v_def) > 0
     AND position('FOR v_row IN' IN v_def) > 0 THEN
    v_needle := 'FOR v_row IN';
    -- Fall through to loop-body inject below if we cannot reshape SELECT easily
    NULL;
  END IF;

  IF position(
    E'LOOP\n    UPDATE public.competition_fixture_schedule\n    SET\n      response_miss_count'
    IN v_def
  ) > 0 THEN
    v_needle := replace($n$  LOOP
    UPDATE public.competition_fixture_schedule
    SET
      response_miss_count = coalesce(response_miss_count, 0) + 1,
      updated_at = now()
    WHERE fixture_id = v_row.fixture_id
$n$, E'\r\n', E'\n');

    v_insert := replace($n$  LOOP
    IF to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
       AND EXISTS (
         SELECT 1
         FROM public.competition_fixture_schedule s2
         WHERE s2.fixture_id = v_row.fixture_id
           AND public.match_schedule_fixture_deadlines_suppressed_for_club(
             v_row.fixture_id, s2.response_required_club_short_name
           )
       ) THEN
      CONTINUE;
    END IF;

    UPDATE public.competition_fixture_schedule
    SET
      response_miss_count = coalesce(response_miss_count, 0) + 1,
      updated_at = now()
    WHERE fixture_id = v_row.fixture_id
$n$, E'\r\n', E'\n');

    IF position(v_needle IN v_def) = 0 THEN
      RAISE WARNING 'response miss counter: loop needle not found';
      RETURN;
    END IF;

    EXECUTE replace(v_def, v_needle, v_insert);
    RAISE NOTICE 'response miss counter: vacant/new-opp suppress injected';
    RETURN;
  END IF;

  RAISE WARNING 'response miss counter: unexpected body — suppress NOT applied';
END;
$inj_miss$;

-- ---------------------------------------------------------------------------
-- No-show ladder — do not fine when suppressed for that club
-- ---------------------------------------------------------------------------
DO $inj_noshow$
DECLARE
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  IF to_regprocedure(
    'public.match_schedule_apply_club_noshow(bigint,text,timestamptz,integer,boolean)'
  ) IS NULL THEN
    RAISE NOTICE 'noshow apply missing — skip';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef(
      'public.match_schedule_apply_club_noshow(bigint,text,timestamptz,integer,boolean)'::regprocedure
    ),
    E'\r\n', E'\n'
  ) INTO v_def;

  IF position('match_schedule_fixture_deadlines_suppressed_for_club(p_fixture_id' IN v_def) > 0 THEN
    RAISE NOTICE 'noshow apply already suppresses';
    RETURN;
  END IF;

  v_needle := replace($n$  -- Manual black-box: do not use GPSL no-show ladder
  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manual_black_box');
  END IF;
$n$, E'\r\n', E'\n');

  v_insert := replace($n$  -- Manual black-box: do not use GPSL no-show ladder
  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manual_black_box');
  END IF;

  IF to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
     AND public.match_schedule_fixture_deadlines_suppressed_for_club(p_fixture_id, p_club) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'opp_vacant_or_new_owner');
  END IF;
$n$, E'\r\n', E'\n');

  IF position(v_needle IN v_def) = 0 THEN
    RAISE WARNING 'noshow apply: BB needle not found — suppress NOT applied';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_needle, v_insert);
  RAISE NOTICE 'noshow apply: vacant/new-opp suppress injected';
END;
$inj_noshow$;

-- ---------------------------------------------------------------------------
-- Board F forecast — mirror suppress
-- ---------------------------------------------------------------------------
DO $inj_fc$
DECLARE
  v_def text;
  v_needle text;
  v_insert text;
BEGIN
  IF to_regprocedure('public.admin_owner_board_fine_forecast()') IS NULL THEN
    RAISE NOTICE 'board forecast missing — skip';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef('public.admin_owner_board_fine_forecast()'::regprocedure),
    E'\r\n', E'\n'
  ) INTO v_def;

  IF position('match_schedule_fixture_deadlines_suppressed_for_club' IN v_def) > 0 THEN
    RAISE NOTICE 'board forecast already suppresses';
    RETURN;
  END IF;

  v_needle := replace($n$          WHEN public.club_scheduling_fines_in_new_owner_grace(
                 v_season, f.home_club_short_name, v_lock_month
               )
            THEN NULL
$n$, E'\r\n', E'\n');

  v_insert := replace($n$          WHEN public.club_scheduling_fines_in_new_owner_grace(
                 v_season, f.home_club_short_name, v_lock_month
               )
            THEN NULL
          WHEN to_regprocedure(
                 'public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)'
               ) IS NOT NULL
            AND public.match_schedule_fixture_deadlines_suppressed_for_club(
                  f.id, f.home_club_short_name
                )
            THEN NULL
$n$, E'\r\n', E'\n');

  IF position(v_needle IN v_def) = 0 THEN
    RAISE WARNING 'forecast arrangement: grace needle not found';
  ELSE
    v_def := replace(v_def, v_needle, v_insert);
  END IF;

  -- Reply fine + warn: add AND NOT suppressed after new-owner grace AND
  v_needle := replace($n$        AND NOT public.club_scheduling_fines_in_new_owner_grace(
          v_season, s.response_required_club_short_name, v_lock_month
        )
$n$, E'\r\n', E'\n');

  v_insert := replace($n$        AND NOT public.club_scheduling_fines_in_new_owner_grace(
          v_season, s.response_required_club_short_name, v_lock_month
        )
        AND (
          to_regprocedure(
            'public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)'
          ) IS NULL
          OR NOT public.match_schedule_fixture_deadlines_suppressed_for_club(
            f.id, s.response_required_club_short_name
          )
        )
$n$, E'\r\n', E'\n');

  IF position(v_needle IN v_def) = 0 THEN
    RAISE WARNING 'forecast reply: grace AND not found (may already be partial)';
  ELSE
    -- replace_all for reply_fine + reply_warn
    v_def := replace(v_def, v_needle, v_insert);
  END IF;

  IF position('match_schedule_fixture_deadlines_suppressed_for_club' IN v_def) = 0 THEN
    RAISE WARNING 'board forecast: suppress NOT applied';
    RETURN;
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'board forecast: vacant/new-opp suppress applied';
END;
$inj_fc$;

-- ---------------------------------------------------------------------------
-- Club Wire cutoffs — hide deadline rows when suppressed for my club
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_wire_cutoffs()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint;
  v_out jsonb := '[]'::jsonb;
  v_lock_at timestamptz;
  v_lock_month text;
  r record;
  v_side text;
  v_home_proposed boolean;
  v_opp text;
  v_state text;
  v_title text;
  v_detail text;
  v_sev text;
  v_at timestamptz;
  v_kind text;
  v_href text;
  v_before int := 10;
  v_after int := 10;
  v_opens timestamptz;
  v_closes timestamptz;
  v_grace int;
  v_final_lock timestamptz;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'cutoffs', '[]'::jsonb);
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'club_short_name', v_club, 'cutoffs', '[]'::jsonb);
  END IF;

  BEGIN
    v_before := coalesce(public.match_schedule_checkin_open_before_minutes(), 10);
  EXCEPTION WHEN OTHERS THEN
    v_before := 10;
  END;
  BEGIN
    v_after := coalesce(public.match_schedule_checkin_minutes(), 10);
  EXCEPTION WHEN OTHERS THEN
    v_after := 10;
  END;

  SELECT c.lock_at, c.gpsl_month
  INTO v_lock_at, v_lock_month
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND c.lock_at > now() - interval '1 hour'
  ORDER BY c.lock_at
  LIMIT 1;

  IF v_lock_at IS NOT NULL AND v_lock_at <= now() + interval '21 days' THEN
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', 'month_lock:' || coalesce(v_lock_month, ''),
      'kind', 'month_lock',
      'at', v_lock_at,
      'title', 'GPSL month lock',
      'detail', format(
        'Thu lock — unproposed homes (₿2.5m), late proposals (₿1m), overdue replies, unfinished no-shows (3–0 + ₿2.5m). Closing %s.',
        public.competition_gpsl_month_label(v_lock_month)
      ),
      'severity', CASE
        WHEN v_lock_at <= now() + interval '48 hours' THEN 'urgent'
        WHEN v_lock_at <= now() + interval '5 days' THEN 'warn'
        ELSE 'info'
      END,
      'href', 'fixtures.html',
      'fixture_id', NULL
    ));
  END IF;

  FOR r IN
    SELECT
      f.id,
      f.gpsl_month,
      f.matchday,
      f.competition_type,
      f.cup_code,
      f.cup_round,
      f.home_club_short_name,
      f.away_club_short_name,
      cal.unlock_at,
      s.status AS sched_status,
      s.response_required_club_short_name AS reply_club,
      s.response_due_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '21 days'
      AND coalesce(s.status, 'unscheduled') <> 'agreed'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT public.match_schedule_fixture_deadlines_suppressed_for_club(f.id, v_club)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY cal.unlock_at, f.id
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN upper(btrim(r.away_club_short_name))
      ELSE upper(btrim(r.home_club_short_name)) END;
    v_href := 'fixture_schedule.html?fixture=' || r.id::text;

    BEGIN
      v_home_proposed := public.match_schedule_home_has_proposed(r.id, now());
    EXCEPTION WHEN OTHERS THEN
      v_home_proposed := coalesce(r.sched_status, 'unscheduled') <> 'unscheduled';
    END;

    v_state := CASE
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating'
           AND upper(btrim(coalesce(r.reply_club, ''))) = v_club THEN 'reply'
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating' THEN 'waiting'
      WHEN v_side = 'home' AND NOT v_home_proposed THEN 'propose'
      ELSE 'waiting_home'
    END;

    IF v_state = 'reply' AND r.response_due_at IS NOT NULL THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', 'reply:' || r.id::text,
        'kind', 'reply',
        'at', r.response_due_at,
        'title', format('Reply vs %s', v_opp),
        'detail', CASE
          WHEN r.response_due_at < now() THEN 'Overdue — first month lock warns; later locks while still overdue = ₿2.5m'
          ELSE 'Reply before this deadline (often 24h turns)'
        END,
        'severity', CASE
          WHEN r.response_due_at < now() THEN 'urgent'
          WHEN r.response_due_at <= now() + interval '6 hours' THEN 'warn'
          ELSE 'info'
        END,
        'href', v_href,
        'fixture_id', r.id
      ));
    ELSIF v_state = 'propose' THEN
      IF r.unlock_at - interval '48 hours' > now() THEN
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'id', 'late_fee:' || r.id::text,
          'kind', 'late_fee',
          'at', r.unlock_at - interval '48 hours',
          'title', format('Propose vs %s (avoid late fee)', v_opp),
          'detail', format(
            'Propose by %s UK to avoid the ₿1m late fee. No proposal by month unlock → ₿2.5m (repeats each lock).',
            to_char((r.unlock_at - interval '48 hours') AT TIME ZONE 'Europe/London', 'Dy HH24:MI')
          ),
          'severity', CASE
            WHEN r.unlock_at - interval '48 hours' <= now() + interval '36 hours' THEN 'warn'
            ELSE 'info'
          END,
          'href', v_href,
          'fixture_id', r.id
        ));
      END IF;

      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', 'propose:' || r.id::text,
        'kind', 'propose',
        'at', r.unlock_at,
        'title', format('Propose vs %s (avoid ₿2.5m)', v_opp),
        'detail', CASE
          WHEN now() >= r.unlock_at - interval '48 hours' THEN
            'Late-fee window open (₿1m). No proposal by this unlock → ₿2.5m Match Management fine.'
          ELSE
            'Home must propose a kick-off before this GPSL month opens.'
        END,
        'severity', CASE
          WHEN now() >= r.unlock_at - interval '48 hours' THEN 'urgent'
          WHEN r.unlock_at <= now() + interval '5 days' THEN 'warn'
          ELSE 'info'
        END,
        'href', v_href,
        'fixture_id', r.id
      ));
    END IF;
  END LOOP;

  FOR r IN
    SELECT
      f.id,
      f.home_club_short_name,
      f.away_club_short_name,
      s.agreed_kickoff_at
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id AND s.status = 'agreed'
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND s.agreed_kickoff_at IS NOT NULL
      AND s.agreed_kickoff_at > now() - interval '2 hours'
      AND s.agreed_kickoff_at <= now() + interval '3 days'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT public.match_schedule_fixture_deadlines_suppressed_for_club(f.id, v_club)
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = f.id AND upper(btrim(c.club_short_name)) = v_club
      )
    ORDER BY s.agreed_kickoff_at
    LIMIT 6
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN upper(btrim(r.away_club_short_name))
      ELSE upper(btrim(r.home_club_short_name)) END;
    v_opens := r.agreed_kickoff_at - make_interval(mins => v_before);
    v_closes := r.agreed_kickoff_at + make_interval(mins => v_after);
    v_href := 'fixture_schedule.html?fixture=' || r.id::text;

    IF now() < v_opens THEN
      v_kind := 'checkin';
      v_at := v_opens;
      v_title := format('Check-in opens vs %s', v_opp);
      v_detail := format('Window %s–%s UK. Miss alone → no-show risk (3–0 + ₿2.5m at later lock if unfinished).',
        to_char(v_opens AT TIME ZONE 'Europe/London', 'Dy HH24:MI'),
        to_char(v_closes AT TIME ZONE 'Europe/London', 'HH24:MI'));
      v_sev := CASE WHEN v_opens <= now() + interval '6 hours' THEN 'warn' ELSE 'info' END;
    ELSIF now() <= v_closes THEN
      v_kind := 'checkin';
      v_at := v_closes;
      v_title := format('Check in now vs %s', v_opp);
      v_detail := 'Check-in window open — miss alone and the match stays unfinished → forfeit risk at month lock.';
      v_sev := 'urgent';
    ELSE
      v_kind := 'noshow';
      v_at := coalesce(v_lock_at, v_closes);
      v_title := format('Check-in missed vs %s', v_opp);
      v_detail := 'Reschedule on the schedule page, or face 3–0 + ₿2.5m at month lock if still unfinished.';
      v_sev := 'urgent';
    END IF;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_kind || ':' || r.id::text,
      'kind', v_kind,
      'at', v_at,
      'title', v_title,
      'detail', v_detail,
      'severity', v_sev,
      'href', v_href,
      'fixture_id', r.id
    ));
  END LOOP;

  FOR r IN
    SELECT
      f.id,
      f.gpsl_month,
      f.competition_type,
      f.home_club_short_name,
      f.away_club_short_name,
      public.competition_gpsl_month_sort(f.gpsl_month) AS play_sort
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal_play
      ON cal_play.season_id = f.season_id
     AND lower(btrim(cal_play.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND cal_play.unlock_at <= now()
      AND public.competition_gpsl_month_sort(f.gpsl_month) IS NOT NULL
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT public.match_schedule_fixture_deadlines_suppressed_for_club(f.id, v_club)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY f.id
    LIMIT 12
  LOOP
    BEGIN
      v_grace := public.match_schedule_play_grace_months(r.competition_type, r.gpsl_month);
    EXCEPTION WHEN OTHERS THEN
      v_grace := CASE WHEN lower(coalesce(r.competition_type, 'league')) = 'cup' THEN 1 ELSE 2 END;
    END;

    SELECT cal.lock_at INTO v_final_lock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season
      AND public.competition_gpsl_month_sort(cal.gpsl_month) <= r.play_sort + v_grace
    ORDER BY public.competition_gpsl_month_sort(cal.gpsl_month) DESC
    LIMIT 1;

    IF v_final_lock IS NULL OR v_final_lock <= now() OR v_final_lock > now() + interval '14 days' THEN
      CONTINUE;
    END IF;

    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    v_opp := CASE WHEN v_side = 'home'
      THEN upper(btrim(r.away_club_short_name))
      ELSE upper(btrim(r.home_club_short_name)) END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', 'play_window:' || r.id::text,
      'kind', 'play_window',
      'at', v_final_lock,
      'title', format('Last play chance vs %s', v_opp),
      'detail', 'Still unplayed after this lock → awarded by scheduling activity (true tie 0–0).',
      'severity', CASE WHEN v_final_lock <= now() + interval '3 days' THEN 'warn' ELSE 'info' END,
      'href', 'fixture_schedule.html?fixture=' || r.id::text,
      'fixture_id', r.id
    ));
  END LOOP;

  SELECT coalesce(jsonb_agg(x.elem ORDER BY (x.elem->>'at')::timestamptz, x.elem->>'id'), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT elem
    FROM jsonb_array_elements(v_out) AS elem
    ORDER BY (elem->>'at')::timestamptz NULLS LAST, elem->>'id'
    LIMIT 10
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'next_month_lock_at', v_lock_at,
    'next_month_lock_month', v_lock_month,
    'cutoffs', coalesce(v_out, '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_wire_cutoffs() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_wire_cutoffs() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_wire_cutoffs() TO service_role;

-- ---------------------------------------------------------------------------
-- Guidance / checklist — also skip new-owner-opponent (vacant already filtered)
-- ---------------------------------------------------------------------------
DO $inj_guide$
DECLARE
  v_oid oid;
  v_def text;
  v_old text := 'AND NOT public.competition_fixture_involves_vacant_club(f.id)';
  v_new text;
  v_club_expr text;
  v_count int := 0;
BEGIN
  FOR v_oid IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'owner_upcoming_arrangements',
        'matchday_checklist_for_club',
        'gpsl_match_system_checklist_for_club'
      )
  LOOP
    SELECT replace(pg_get_functiondef(v_oid), E'\r\n', E'\n') INTO v_def;
    IF position('match_schedule_fixture_deadlines_suppressed_for_club' IN v_def) > 0 THEN
      CONTINUE;
    END IF;
    IF position(v_old IN v_def) = 0 THEN
      CONTINUE;
    END IF;

    IF v_def ~ 'p_club[_a-z]*\s+text' THEN
      v_club_expr := (regexp_match(v_def, '(p_club[_a-z]*)\s+text'))[1];
    ELSE
      v_club_expr := 'v_club';
    END IF;

    v_new := v_old
      || E'\n      AND NOT public.match_schedule_fixture_deadlines_suppressed_for_club(f.id, '
      || v_club_expr || ')';

    IF v_def IS DISTINCT FROM replace(v_def, v_old, v_new) THEN
      EXECUTE replace(v_def, v_old, v_new);
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'guidance/checklist vacant lines extended on % function(s)', v_count;
END;
$inj_guide$;

SELECT
  to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)')
    IS NOT NULL AS helper_ok,
  position(
    'match_schedule_fixture_deadlines_suppressed_for_club'
    IN pg_get_functiondef(
      'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
    )
  ) > 0 AS arrangement_has_suppress,
  position(
    'match_schedule_fixture_deadlines_suppressed_for_club'
    IN pg_get_functiondef(
      'public.competition_enforce_scheduling_response_fines(bigint,text)'::regprocedure
    )
  ) > 0 AS response_has_suppress,
  position(
    'match_schedule_fixture_deadlines_suppressed_for_club'
    IN pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure)
  ) > 0 AS cutoffs_has_suppress;
