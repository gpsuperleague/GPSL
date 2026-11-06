-- =============================================================================
-- Cup arrangement fines: drawn at month change, not the month before
--
-- League (unchanged): home must propose before the play month opens.
--   Last 48h before unlock → ₿1m Late Arrangement Fee.
--   No proposal by that lock → ₿2.5m Match Management, then each later lock.
--
-- Cups are drawn when the round month opens, so that prior-month charge is
-- wrong. Home arranges during the cup round month, then has the normal cup
-- grace month (May cups: none). The ₿2.5m no-proposal fine starts only when
-- that grace month locks, and can repeat after that. No ₿1m last-48h fee.
--
-- Injects into the live functions so holiday / new-owner / vacant / black-box
-- skips already on the server stay in place.
-- Safe re-run. Run in the Supabase SQL editor.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Month-lock arrangement fines
-- ---------------------------------------------------------------------------
DO $cup_fines$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_enforce_scheduling_arrangement_fines(bigint,text)') IS NULL THEN
    RAISE EXCEPTION 'competition_enforce_scheduling_arrangement_fines missing';
  END IF;

  SELECT replace(replace(pg_get_functiondef(
    'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
  ), E'\r\n', E'\n'), E'\r', E'\n') INTO v_def;

  IF position('cup arrangement grace' IN v_def) > 0 THEN
    RAISE NOTICE 'arrangement fines already use cup grace';
    RETURN;
  END IF;

  IF position('f.competition_type' IN v_def) = 0
     AND position('f.away_club_short_name,' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      'f.away_club_short_name,',
      E'f.away_club_short_name,\n      f.competition_type,'
    );
  END IF;

  v_old := replace($n$    IF v_is_arrangement_deadline THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      ELSIF v_deadline IS NOT NULL
        AND v_first_at >= v_deadline - interval '48 hours'
        AND v_first_at < v_deadline
      THEN
        v_tariff_code := 'match_late_arrangement';
      END IF;
    ELSIF v_closed_sort >= v_f.play_sort THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      END IF;
    END IF;
$n$, E'\r\n', E'\n');

  v_new := replace($n$    -- cup arrangement grace: round month + play-grace month, no prior-month fee
    IF lower(coalesce(v_f.competition_type, 'league')) = 'cup' THEN
      IF v_first_at IS NULL
         AND v_closed_sort >= v_f.play_sort
             + public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month)
      THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      END IF;
    ELSIF v_is_arrangement_deadline THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      ELSIF v_deadline IS NOT NULL
        AND v_first_at >= v_deadline - interval '48 hours'
        AND v_first_at < v_deadline
      THEN
        v_tariff_code := 'match_late_arrangement';
      END IF;
    ELSIF v_closed_sort >= v_f.play_sort THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      END IF;
    END IF;
$n$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'arrangement fines: tariff block not found — cup grace NOT applied';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'arrangement fines: cup grace applied';
END;
$cup_fines$;

-- ---------------------------------------------------------------------------
-- Board fine forecast (same clock, so the lock preview matches)
-- ---------------------------------------------------------------------------
DO $cup_forecast$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.admin_owner_board_fine_forecast()') IS NULL THEN
    RAISE NOTICE 'board forecast missing — skip';
    RETURN;
  END IF;

  SELECT replace(replace(pg_get_functiondef(
    'public.admin_owner_board_fine_forecast()'::regprocedure
  ), E'\r\n', E'\n'), E'\r', E'\n') INTO v_def;

  IF position('cup arrangement grace' IN v_def) > 0 THEN
    RAISE NOTICE 'board forecast already uses cup grace';
    RETURN;
  END IF;

  v_old := replace($n$          WHEN public.competition_gpsl_month_sort(f.gpsl_month) = v_lock_sort + 1 THEN
$n$, E'\r\n', E'\n');

  v_new := replace($n$          WHEN lower(coalesce(f.competition_type, 'league')) = 'cup' THEN
            CASE
              WHEN public.match_schedule_home_first_proposal_at(f.id, now()) IS NULL
                AND v_lock_sort >= public.competition_gpsl_month_sort(f.gpsl_month)
                    + public.match_schedule_play_grace_months(f.competition_type, f.gpsl_month)
                THEN 'match_mgmt_no_proposal'
              ELSE NULL
            END
          -- cup arrangement grace (above). League keeps the prior-month clock:
          WHEN public.competition_gpsl_month_sort(f.gpsl_month) = v_lock_sort + 1 THEN
$n$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'board forecast: next-month tariff branch not found — cup grace NOT applied';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'board forecast: cup grace applied';
END;
$cup_forecast$;

-- ---------------------------------------------------------------------------
-- Deadlines shown on the schedule page
-- ---------------------------------------------------------------------------
DO $cup_deadlines$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.match_schedule_fixture_deadlines(bigint)') IS NULL THEN
    RAISE NOTICE 'fixture deadlines missing — skip';
    RETURN;
  END IF;

  SELECT replace(replace(pg_get_functiondef(
    'public.match_schedule_fixture_deadlines(bigint)'::regprocedure
  ), E'\r\n', E'\n'), E'\r', E'\n') INTO v_def;

  IF position('cup_grace' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture deadlines already cup-aware';
    RETURN;
  END IF;

  v_old := replace($n$    'propose_by', v_play_unlock,
    'late_fee_from', v_play_unlock - interval '48 hours',
$n$, E'\r\n', E'\n');

  v_new := replace($n$    'propose_by', CASE
      WHEN lower(btrim(coalesce(v_f.competition_type, ''))) = 'cup' THEN v_final_lock
      ELSE v_play_unlock
    END,
    'late_fee_from', CASE
      WHEN lower(btrim(coalesce(v_f.competition_type, ''))) = 'cup' THEN NULL
      ELSE v_play_unlock - interval '48 hours'
    END,
    'arrangement_rule', CASE
      WHEN lower(btrim(coalesce(v_f.competition_type, ''))) = 'cup' THEN 'cup_grace'
      ELSE 'league_prior_lock'
    END,
$n$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'fixture deadlines: propose_by needle not found — schedule copy may still say prior-month';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'fixture deadlines: cup grace applied';
END;
$cup_deadlines$;

-- ---------------------------------------------------------------------------
-- Arrange-now list: no ₿1m late-fee clock on a cup
-- ---------------------------------------------------------------------------
DO $cup_upcoming$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.owner_upcoming_arrangements()') IS NULL THEN
    RAISE NOTICE 'upcoming arrangements missing — skip';
    RETURN;
  END IF;

  SELECT replace(replace(pg_get_functiondef(
    'public.owner_upcoming_arrangements()'::regprocedure
  ), E'\r\n', E'\n'), E'\r', E'\n') INTO v_def;

  IF position('cup arrangement grace' IN v_def) > 0 THEN
    RAISE NOTICE 'upcoming arrangements already cup-aware';
    RETURN;
  END IF;

  v_old := replace($n$    v_propose_by := CASE
      WHEN v_is_replay OR v_is_catch_up THEN coalesce(v_active_lock, now() + interval '7 days')
      ELSE r.unlock_at
    END;
$n$, E'\r\n', E'\n');

  v_new := replace($n$    -- cup arrangement grace: propose-by is the grace-month lock, not month open
    v_propose_by := CASE
      WHEN v_is_replay OR v_is_catch_up THEN coalesce(v_active_lock, now() + interval '7 days')
      WHEN lower(coalesce(r.competition_type, 'league')) = 'cup' THEN coalesce(
        (
          SELECT cal.lock_at
          FROM public.competition_season_calendar cal
          WHERE cal.season_id = v_season
            AND public.competition_gpsl_month_sort(cal.gpsl_month)
              <= public.competition_gpsl_month_sort(r.gpsl_month)
                 + public.match_schedule_play_grace_months(r.competition_type, r.gpsl_month)
          ORDER BY public.competition_gpsl_month_sort(cal.gpsl_month) DESC
          LIMIT 1
        ),
        r.unlock_at
      )
      ELSE r.unlock_at
    END;
$n$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'upcoming arrangements: propose_by needle not found';
  ELSE
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($n$      'late_fee_from', CASE
        WHEN v_is_replay OR v_is_catch_up THEN NULL
        ELSE r.unlock_at - interval '48 hours'
      END,
$n$, E'\r\n', E'\n');

  v_new := replace($n$      'late_fee_from', CASE
        WHEN v_is_replay OR v_is_catch_up THEN NULL
        WHEN lower(coalesce(r.competition_type, 'league')) = 'cup' THEN NULL
        ELSE r.unlock_at - interval '48 hours'
      END,
$n$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'upcoming arrangements: late_fee needle not found';
  ELSE
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF position('cup arrangement grace' IN v_def) = 0 THEN
    RAISE WARNING 'upcoming arrangements: cup grace NOT applied';
    RETURN;
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'upcoming arrangements: cup grace applied';
END;
$cup_upcoming$;

-- ---------------------------------------------------------------------------
-- Do not warn "propose before the month opens or ₿2.5m" for a cup
-- ---------------------------------------------------------------------------
DO $cup_warn$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_notify_scheduling_deadline_warnings(bigint)') IS NULL THEN
    RAISE NOTICE 'deadline warnings missing — skip';
    RETURN;
  END IF;

  SELECT replace(replace(pg_get_functiondef(
    'public.competition_notify_scheduling_deadline_warnings(bigint)'::regprocedure
  ), E'\r\n', E'\n'), E'\r', E'\n') INTO v_def;

  v_old := replace($n$      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '48 hours'
$n$, E'\r\n', E'\n');

  v_new := replace($n$      AND f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '48 hours'
$n$, E'\r\n', E'\n');

  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'deadline warnings already league-only for pre-month propose';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'deadline warnings: pre-month propose loop not found';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'deadline warnings: cups excluded from prior-month propose nag';
END;
$cup_warn$;

DO $cup_guidance$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.match_owner_guidance_reminders()');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'guidance reminders missing — skip';
    RETURN;
  END IF;

  SELECT replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n') INTO v_def;

  v_old := replace($n$      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '5 days'
$n$, E'\r\n', E'\n');

  v_new := replace($n$      AND coalesce(f.competition_type, 'league') = 'league'
      AND f.status = 'scheduled'
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '5 days'
$n$, E'\r\n', E'\n');

  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'guidance reminders already league-only for pre-month propose';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'guidance reminders: pre-month propose loop not found';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'guidance reminders: cups excluded from prior-month propose nag';
END;
$cup_guidance$;

NOTIFY pgrst, 'reload schema';
