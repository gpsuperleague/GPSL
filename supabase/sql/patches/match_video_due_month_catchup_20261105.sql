-- =============================================================================
-- Match video deadline = month the fixture was *played* in (+ grace), not only
-- the fixture's original GPSL month.
--
-- Catch-up / holiday-delayed games kept the original month lock + 72h, so once
-- the result landed the grace window had already expired and fines assessed
-- immediately. Early holiday play still uses the fixture month (never earlier).
--
-- Safe re-run. Apply in Supabase SQL Editor / supabase db query --linked.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Play moment (kick-off preferred, else confirmed result timestamp)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_play_at(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_at timestamptz;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.agreed_kickoff_at
  INTO v_at
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  IF v_at IS NOT NULL THEN
    RETURN v_at;
  END IF;

  SELECT coalesce(rs.responded_at, rs.submitted_at)
  INTO v_at
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = p_fixture_id
    AND rs.status = 'confirmed'
  ORDER BY rs.id DESC
  LIMIT 1;

  RETURN v_at;
END;
$function$;

COMMENT ON FUNCTION public.match_video_play_at(bigint) IS
  'Best timestamp for when a fixture was played (agreed kick-off, else confirmed result).';

-- ---------------------------------------------------------------------------
-- GPSL month whose lock + grace governs the video upload window
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_due_gpsl_month(p_fixture_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_fix text;
  v_play_at timestamptz;
  v_play text;
  v_fix_sort int;
  v_play_sort int;
BEGIN
  SELECT f.season_id, lower(btrim(f.gpsl_month))
  INTO v_season, v_fix
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF v_season IS NULL OR nullif(v_fix, '') IS NULL THEN
    RETURN v_fix;
  END IF;

  v_play_at := public.match_video_play_at(p_fixture_id);
  IF v_play_at IS NULL THEN
    RETURN v_fix;
  END IF;

  -- Latest calendar month that had unlocked by the play moment
  -- (covers in-month play and the short post-lock gap before next unlock).
  SELECT lower(btrim(c.gpsl_month))
  INTO v_play
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND c.unlock_at <= v_play_at
  ORDER BY c.sort_order DESC
  LIMIT 1;

  IF nullif(v_play, '') IS NULL THEN
    RETURN v_fix;
  END IF;

  v_fix_sort := public.competition_gpsl_month_sort(v_fix);
  v_play_sort := public.competition_gpsl_month_sort(v_play);

  -- Delayed / catch-up → month played in. Early holiday → keep fixture month.
  IF v_play_sort IS NOT NULL
     AND v_fix_sort IS NOT NULL
     AND v_play_sort > v_fix_sort THEN
    RETURN v_play;
  END IF;

  RETURN v_fix;
END;
$function$;

COMMENT ON FUNCTION public.match_video_due_gpsl_month(bigint) IS
  'GPSL month used for match-video grace: later of fixture month and month of play.';

CREATE OR REPLACE FUNCTION public.match_video_due_lock_at(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_month text;
  v_lock timestamptz;
BEGIN
  SELECT f.season_id INTO v_season
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  v_month := public.match_video_due_gpsl_month(p_fixture_id);
  IF v_season IS NULL OR nullif(btrim(coalesce(v_month, '')), '') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND lower(btrim(c.gpsl_month)) = lower(btrim(v_month))
  LIMIT 1;

  RETURN v_lock;
END;
$function$;

COMMENT ON FUNCTION public.match_video_due_lock_at(bigint) IS
  'Month lock_at for match-video grace (due month, not always fixture.gpsl_month).';

CREATE OR REPLACE FUNCTION public.match_video_due_at(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN public.match_video_due_lock_at(p_fixture_id) IS NULL THEN NULL
    ELSE public.match_video_due_lock_at(p_fixture_id)
           + make_interval(hours => public.match_video_missing_fine_grace_hours())
  END;
$$;

REVOKE ALL ON FUNCTION public.match_video_play_at(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.match_video_due_gpsl_month(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.match_video_due_lock_at(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.match_video_due_at(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_play_at(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_video_due_gpsl_month(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_video_due_lock_at(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_video_due_at(bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Missing-video assessor: join calendar on due month
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_process_missing_fines(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_fine numeric := public.match_video_missing_fine_amount();
  v_grace int := public.match_video_missing_fine_grace_hours();
  v_suspend_h int := 24;
  v_r record;
  v_apply jsonb;
  v_fined int := 0;
  v_skipped int := 0;
  v_already int := 0;
  v_no_owner int := 0;
  v_deadline timestamptz;
  v_note text;
  v_opponent text;
  v_suspend_until timestamptz;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'No active season');
  END IF;

  SELECT coalesce(missing_pts_suspend_hours, 24)
  INTO v_suspend_h
  FROM public.gpsl_discord_match_videos_settings
  WHERE id = 1;

  IF v_suspend_h IS NULL OR v_suspend_h < 1 THEN
    v_suspend_h := 24;
  END IF;

  FOR v_r IN
    SELECT
      f.id AS fixture_id,
      public.match_video_due_gpsl_month(f.id) AS due_gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name,
      cal.lock_at,
      side.side,
      side.club_short_name
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(public.match_video_due_gpsl_month(f.id)))
    CROSS JOIN LATERAL (
      VALUES
        ('home', upper(btrim(f.home_club_short_name))),
        ('away', upper(btrim(f.away_club_short_name)))
    ) AS side(side, club_short_name)
    WHERE f.season_id = v_season_id
      AND f.status = 'played'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND nullif(btrim(f.gpsl_month), '') IS NOT NULL
      AND cal.lock_at IS NOT NULL
      AND cal.lock_at <= now()
      AND cal.lock_at + make_interval(hours => v_grace) <= now()
      AND side.club_short_name IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE upper(btrim(c."ShortName")) = side.club_short_name
          AND c.owner_id IS NOT NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id
          AND v.side = side.side
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_video_failures fail
        WHERE fail.fixture_id = f.id
          AND fail.side = side.side
      )
  LOOP
    v_deadline := v_r.lock_at + make_interval(hours => v_grace);
    v_suspend_until := now() + make_interval(hours => v_suspend_h);
    v_opponent := CASE
      WHEN v_r.side = 'home' THEN coalesce(
        public.club_display_name(v_r.away_club_short_name),
        v_r.away_club_short_name
      )
      ELSE coalesce(
        public.club_display_name(v_r.home_club_short_name),
        v_r.home_club_short_name
      )
    END;

    v_note := format(
      'No match video within %sh of %s lock, MD%s %s vs %s',
      v_grace,
      coalesce(public.competition_gpsl_month_label(v_r.due_gpsl_month), v_r.due_gpsl_month, '?'),
      coalesce(v_r.matchday::text, '?'),
      v_r.side,
      coalesce(v_opponent, '?')
    );

    v_apply := NULL;
    IF v_fine > 0 THEN
      BEGIN
        v_apply := public.competition_apply_club_fine_tariff(
          v_r.club_short_name,
          'match_video_missing',
          v_fine,
          v_note,
          v_r.fixture_id,
          v_season_id
        );
      EXCEPTION WHEN OTHERS THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END;
    END IF;

    INSERT INTO public.fixture_match_video_failures (
      season_id, fixture_id, side, club_short_name, gpsl_month,
      assessed_at, deadline_at, fine_amount, ledger_id, fine_applied_id,
      pts_status, pts_suspend_until
    ) VALUES (
      v_season_id,
      v_r.fixture_id,
      v_r.side,
      v_r.club_short_name,
      v_r.due_gpsl_month,
      now(),
      v_deadline,
      coalesce(v_fine, 0),
      nullif(v_apply->>'ledger_id', '')::bigint,
      nullif(v_apply->>'applied_id', '')::bigint,
      'suspended',
      v_suspend_until
    )
    ON CONFLICT (fixture_id, side) DO NOTHING;

    BEGIN
      PERFORM public.owner_inbox_send(
        'points_deduction',
        'Match video — 1 point suspended',
        format(
          E'Missing match video after the %s-hour upload window (MD%s %s vs %s).\n'
          || 'A 1 point deduction is SUSPENDED for %s hours. Upload the video before then to avoid the point.\n'
          || 'Money fine (if any) has already been applied and will not be rescinded.',
          v_grace,
          coalesce(v_r.matchday::text, '?'),
          v_r.side,
          coalesce(v_opponent, '?'),
          v_suspend_h
        ),
        v_r.club_short_name,
        NULL,
        NULL, NULL, NULL, NULL,
        'fixtures.html',
        'mv_pts_suspend:' || v_r.fixture_id::text || ':' || v_r.side,
        NULL,
        v_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    v_fined := v_fined + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'fine_amount', v_fine,
    'grace_hours', v_grace,
    'suspend_hours', v_suspend_h,
    'assessed', v_fined,
    'already', v_already,
    'skipped_errors', v_skipped,
    'no_owner_skipped_note', v_no_owner
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_process_missing_fines(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_process_missing_fines(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_process_missing_fines(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Rescind: still inside *due-month* grace (fixes premature catch-up fines)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_rescind_fines_inside_grace(
  p_grace_hours int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_grace int := coalesce(
    nullif(p_grace_hours, 0),
    public.match_video_missing_fine_grace_hours(),
    72
  );
  v_fail record;
  v_ledger public.competition_finance_ledger%ROWTYPE;
  v_refund numeric;
  v_new_ledger_id bigint;
  v_rescued int := 0;
  v_money int := 0;
  v_pts int := 0;
  v_esc int := 0;
  v_skipped int := 0;
  v_details jsonb := '[]'::jsonb;
  v_esc_row public.match_video_strike_escalations%ROWTYPE;
BEGIN
  IF NOT (
    coalesce(auth.role(), '') = 'service_role'
    OR coalesce(public.is_gpsl_admin_or_mod(), false)
    OR session_user IN ('postgres', 'supabase_admin')
  ) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_grace < 1 THEN
    v_grace := 72;
  END IF;

  FOR v_fail IN
    SELECT
      fail.*,
      f.matchday,
      public.match_video_due_lock_at(fail.fixture_id) AS due_lock_at,
      public.match_video_due_lock_at(fail.fixture_id)
        + make_interval(hours => v_grace) AS grace_ends_at
    FROM public.fixture_match_video_failures fail
    JOIN public.competition_fixtures f ON f.id = fail.fixture_id
    WHERE public.match_video_due_lock_at(fail.fixture_id) IS NOT NULL
      AND public.match_video_due_lock_at(fail.fixture_id)
            + make_interval(hours => v_grace) > now()
    ORDER BY fail.id
  LOOP
    IF v_fail.ledger_id IS NOT NULL AND EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE (l.metadata->>'rescind_of_ledger_id') = v_fail.ledger_id::text
         OR (l.metadata->>'rescind_of_failure_id') = v_fail.id::text
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_refund := 0;
    IF v_fail.ledger_id IS NOT NULL THEN
      SELECT * INTO v_ledger
      FROM public.competition_finance_ledger
      WHERE id = v_fail.ledger_id;

      IF FOUND AND v_ledger.amount < 0 THEN
        v_refund := abs(v_ledger.amount);
        PERFORM public.competition_credit_club_balance(
          v_fail.club_short_name,
          v_refund
        );

        INSERT INTO public.competition_finance_ledger (
          season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
        )
        VALUES (
          v_fail.season_id,
          v_fail.fixture_id,
          v_fail.club_short_name,
          'gov_fine_compensation',
          v_refund,
          format(
            'Compensation — Missing match video — Rescinded (still within %sh grace)',
            v_grace
          ),
          jsonb_build_object(
            'tariff_code', 'match_video_missing',
            'direction', 'compensation',
            'category', 'matchday',
            'rescind_of_ledger_id', v_fail.ledger_id,
            'rescind_of_failure_id', v_fail.id,
            'rescind_reason', 'inside_grace_window',
            'grace_hours', v_grace,
            'due_lock_at', v_fail.due_lock_at,
            'grace_ends_at', v_fail.grace_ends_at
          )
        )
        RETURNING id INTO v_new_ledger_id;

        IF v_fail.fine_applied_id IS NOT NULL THEN
          UPDATE public.competition_fine_applied
          SET note = concat_ws(
            E'\n',
            nullif(btrim(coalesce(note, '')), ''),
            format('RESCINDED %s (still within %sh grace); refund ledger %s',
              now()::date, v_grace, v_new_ledger_id)
          )
          WHERE id = v_fail.fine_applied_id;
        END IF;

        v_money := v_money + 1;
      END IF;
    ELSIF coalesce(v_fail.fine_amount, 0) > 0 THEN
      v_refund := abs(v_fail.fine_amount);
      PERFORM public.competition_credit_club_balance(v_fail.club_short_name, v_refund);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fail.season_id,
        v_fail.fixture_id,
        v_fail.club_short_name,
        'gov_fine_compensation',
        v_refund,
        format(
          'Compensation — Missing match video — Rescinded (still within %sh grace)',
          v_grace
        ),
        jsonb_build_object(
          'tariff_code', 'match_video_missing',
          'direction', 'compensation',
          'category', 'matchday',
          'rescind_of_failure_id', v_fail.id,
          'rescind_reason', 'inside_grace_window',
          'grace_hours', v_grace
        )
      );
      v_money := v_money + 1;
    END IF;

    IF v_fail.pts_adjustment_id IS NOT NULL THEN
      BEGIN
        PERFORM public.match_video_apply_league_points(
          v_fail.club_short_name,
          (1)::smallint,
          format(
            'Match video — rescinded full 1 pt (still within %sh grace; fixture %s %s)',
            v_grace,
            v_fail.fixture_id,
            v_fail.side
          ),
          v_fail.season_id
        );
        v_pts := v_pts + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;

    SELECT * INTO v_esc_row
    FROM public.match_video_strike_escalations e
    WHERE e.third_failure_id = v_fail.id
       OR (
         e.season_id = v_fail.season_id
         AND upper(btrim(e.club_short_name)) = upper(btrim(v_fail.club_short_name))
         AND e.third_failure_id IS NULL
       )
    LIMIT 1;

    IF FOUND AND v_esc_row.id IS NOT NULL
       AND v_esc_row.third_failure_id IS NOT DISTINCT FROM v_fail.id THEN
      IF v_esc_row.season_adjustment_id IS NOT NULL THEN
        BEGIN
          PERFORM public.match_video_apply_league_points(
            v_fail.club_short_name,
            (9)::smallint,
            format(
              'Match video — rescinded 3-strike −9 (still within %sh grace)',
              v_grace
            ),
            v_fail.season_id
          );
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END IF;

      DELETE FROM public.match_video_points_carry c
      WHERE c.escalation_id = v_esc_row.id
        AND c.applied_at IS NULL;

      DELETE FROM public.match_video_strike_escalations
      WHERE id = v_esc_row.id;

      v_esc := v_esc + 1;
    END IF;

    BEGIN
      PERFORM public.owner_inbox_send(
        'fine_applied',
        'Missing match video fine rescinded',
        format(
          E'Your missing match video fine for fixture %s (%s) was rescinded.\n'
          || 'Upload grace is now %s hours after the month you played in locks; you are still inside that window.\n'
          || CASE WHEN v_refund > 0
               THEN format('₿%s has been credited back to club finances.',
                 trim(to_char(v_refund, '999,999,999,999')))
               ELSE 'No money fine was on the ledger for this row.'
             END,
          v_fail.fixture_id,
          v_fail.side,
          v_grace
        ),
        v_fail.club_short_name,
        NULL,
        v_fail.fixture_id,
        NULL, NULL, NULL,
        'fixtures.html',
        'mv_fine_rescind:' || v_fail.id::text,
        NULL,
        v_fail.season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    DELETE FROM public.fixture_match_video_failures
    WHERE id = v_fail.id;

    v_rescued := v_rescued + 1;
    v_details := v_details || jsonb_build_array(
      jsonb_build_object(
        'failure_id', v_fail.id,
        'fixture_id', v_fail.fixture_id,
        'side', v_fail.side,
        'club', v_fail.club_short_name,
        'refund', v_refund,
        'grace_ends_at', v_fail.grace_ends_at
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'grace_hours', v_grace,
    'rescinded', v_rescued,
    'money_refunded', v_money,
    'points_reversed', v_pts,
    'escalations_reversed', v_esc,
    'skipped_already', v_skipped,
    'details', v_details
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_rescind_fines_inside_grace(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_rescind_fines_inside_grace(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_rescind_fines_inside_grace(int) TO service_role;

-- ---------------------------------------------------------------------------
-- Club Wire: swap fixture-month calendar join → due month
-- ---------------------------------------------------------------------------
DO $inject$
DECLARE
  v_def text;
  v_old text := $n$
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    LEFT JOIN public.fixture_match_video_failures fail
$n$;
  v_new text := $n$
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(public.match_video_due_gpsl_month(f.id)))
    LEFT JOIN public.fixture_match_video_failures fail
$n$;
BEGIN
  IF to_regprocedure('public.club_wire_cutoffs()') IS NULL THEN
    RAISE NOTICE 'club_wire_cutoffs missing — skip wire inject';
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure)
  INTO v_def;

  IF position(v_old IN v_def) = 0 THEN
    IF position('match_video_due_gpsl_month(f.id)' IN v_def) > 0 THEN
      RAISE NOTICE 'club_wire_cutoffs already uses due month';
      RETURN;
    END IF;
    RAISE WARNING 'club_wire_cutoffs: expected video calendar join not found — update manually';
    RETURN;
  END IF;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
  RAISE NOTICE 'club_wire_cutoffs: video deadlines now use match_video_due_gpsl_month';
END;
$inject$;

-- Matchday checklist: video overdue uses due-month lock when helper exists
DO $inject2$
DECLARE
  v_def text;
  v_old text := 'v_video_deadline := CASE WHEN r.month_lock_at IS NOT NULL THEN r.month_lock_at + make_interval(hours => v_grace) END;';
  v_new text := $n$v_video_deadline := CASE
        WHEN to_regprocedure('public.match_video_due_lock_at(bigint)') IS NOT NULL
             AND public.match_video_due_lock_at(r.id) IS NOT NULL
          THEN public.match_video_due_lock_at(r.id) + make_interval(hours => v_grace)
        WHEN r.month_lock_at IS NOT NULL
          THEN r.month_lock_at + make_interval(hours => v_grace)
        ELSE NULL
      END;$n$;
BEGIN
  IF to_regprocedure('public.matchday_checklist_for_club(text,boolean)') IS NULL THEN
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure)
  INTO v_def;

  IF position('match_video_due_lock_at(r.id)' IN v_def) > 0 THEN
    RAISE NOTICE 'matchday_checklist_for_club already uses due lock';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'matchday_checklist_for_club: video deadline needle not found';
    RETURN;
  END IF;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
  RAISE NOTICE 'matchday_checklist_for_club: video deadline uses due-month lock';
END;
$inject2$;

-- Auto-rescue any failures still inside the *new* due-month grace
DO $rescue$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.match_video_rescind_fines_inside_grace(NULL);
  RAISE NOTICE 'match_video_rescind_fines_inside_grace: %', v_result;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'match_video_rescind_fines_inside_grace failed: %', SQLERRM;
END;
$rescue$;

NOTIFY pgrst, 'reload schema';
