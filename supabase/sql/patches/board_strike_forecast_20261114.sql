-- Season owner board F lock: project the strike rules, not the retired tariffs.
-- No proposal from either club is a match_strike on the home club.
-- The late-arrangement fee is not added.
-- A reply counts only when the lock would add another strike.
-- Safe re-run.

DO $board$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.admin_owner_board_fine_forecast()'::regprocedure
  ), E'\r\n', E'\n');

  IF position('board strikes 2026-11-14' IN v_def) > 0 THEN
    RAISE NOTICE 'forecast already uses strike amounts';
    RETURN;
  END IF;

  v_old := replace($old$        (
          count(*) FILTER (WHERE tariff = 'match_mgmt_no_proposal')::numeric * v_no_prop
          + count(*) FILTER (WHERE tariff = 'match_late_arrangement')::numeric * v_late
        ) AS amt,$old$, E'\r\n', E'\n');
  v_new := replace($new$        (
          count(*) FILTER (WHERE tariff = 'match_mgmt_no_proposal')::numeric
            * coalesce((SELECT t.amount FROM public.competition_fine_tariff t WHERE t.code = 'match_strike'), 500000)
        ) AS amt, -- board strikes 2026-11-14$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'forecast amount expression not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$            END,
            CASE
              WHEN count(*) FILTER (WHERE tariff = 'match_late_arrangement') > 0
                THEN format(
                  'late arrange×%s',
                  count(*) FILTER (WHERE tariff = 'match_late_arrangement')
                )
              ELSE NULL
            END$old$, E'\r\n', E'\n');
  v_new := replace($new$            END$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'forecast late-arrange detail not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$                  'no proposal×%s',$old$, E'\r\n', E'\n');
  v_new := replace($new$                  'no proposal strike×%s',$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'forecast no-proposal detail not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$              AND s.status = 'agreed'
          ) THEN NULL
          WHEN public.club_scheduling_fines_in_new_owner_grace($old$, E'\r\n', E'\n');
  v_new := replace($new$              AND s.status = 'agreed'
          ) THEN NULL
          WHEN EXISTS (
            SELECT 1
            FROM public.competition_fixture_schedule_proposal p
            WHERE p.fixture_id = f.id
              AND p.proposed_by_club_short_name = f.away_club_short_name
              AND p.status <> 'withdrawn'
          ) THEN NULL
          WHEN to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
            AND public.fixture_is_manual_black_box(f.id)
            THEN NULL
          WHEN public.club_scheduling_fines_in_new_owner_grace($new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'forecast agreed branch not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$        count(*)::numeric * v_response AS amt,
        format('reply overdue×%s', count(*)) AS detail$old$, E'\r\n', E'\n');
  v_new := replace($new$        count(*)::numeric * coalesce((SELECT t.amount FROM public.competition_fine_tariff t WHERE t.code = 'match_strike'), 500000) AS amt,
        format('reply strike×%s', count(*)) AS detail$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'forecast reply amount not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$        AND s.response_due_at < coalesce(v_lock_at, now())
        AND s.response_deadline_warned_at IS NOT NULL
        AND s.response_deadline_warned_at < coalesce(v_lock_at, now())$old$, E'\r\n', E'\n');
  v_new := replace($new$        AND s.response_due_at < coalesce(v_lock_at, now())
        AND (
          EXISTS (
            SELECT 1
            FROM public.competition_fixture_reply_strikes rs
            WHERE rs.fixture_id = f.id
              AND rs.club_short_name = s.response_required_club_short_name
              AND rs.pending_proposal_id = s.pending_proposal_id
              AND rs.kind = 'deadline'
          )
          OR s.response_due_at < coalesce((
            SELECT cu.cutover_at
            FROM public.gpsl_rule_cutover cu
            WHERE cu.rule_key = 'reply_strike_48h'
          ), '-infinity'::timestamptz)
        )
        AND NOT (
          to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
          AND public.fixture_is_manual_black_box(f.id)
        )$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'forecast reply warning filter not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE v_def;
END;
$board$;

DO $warn$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.admin_owner_board_fine_forecast()'::regprocedure
  ), E'\r\n', E'\n');

  IF position('reply warning retired 2026-11-14' IN v_def) > 0 THEN
    RAISE NOTICE 'forecast already skips the reply warning';
    RETURN;
  END IF;

  v_old := replace($old$        AND s.response_deadline_warned_at IS NULL$old$, E'\r\n', E'\n');
  v_new := replace($new$        AND false -- reply warning retired 2026-11-14$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) <> 1 AND position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'forecast reply warning filter not found';
  END IF;
  IF (SELECT count(*) FROM regexp_matches(v_def, 'response_deadline_warned_at IS NULL', 'g')) <> 1 THEN
    RAISE EXCEPTION 'forecast reply warning filter was not unique';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END;
$warn$;
