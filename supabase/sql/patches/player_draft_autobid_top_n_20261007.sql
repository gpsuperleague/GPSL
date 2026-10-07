-- =============================================================================
-- Player draft auto-bid: "Max players" = work only the top N targets
-- =============================================================================
-- Setting max players to N now means the plan works the first N targets on the
-- list (in priority order, skipping players the club already has) and never
-- goes below them. Each pass:
--   1) opens every fresh thread in the top N (earning credits),
--   2) goes round the top N again and joins other clubs' threads with the
--      credits earned.
-- Targets below the top N are shown as "Outside your top N". Blank = no limit
-- (whole list, as before).
--
-- Patches player_draft_autobid_run_plan in place. Safe to re-run.
-- =============================================================================

DO $patch$
DECLARE
  v_def text;
  v_marker text := 'FOR v_phase IN 1..2 LOOP';

  a1_old text := $s$  v_via text;
BEGIN$s$;
  a1_new text := $s$  v_via text;
  v_window bigint[];
  v_phase int;
BEGIN$s$;

  a2_old text := $s$    -- B) Threads not yet entered, in priority order
    FOR t IN
      SELECT * FROM public.player_draft_autobid_targets
      WHERE plan_id = pl.id AND included
        AND state NOT IN ('ineligible', 'owned', 'won')
      ORDER BY priority, id
    LOOP
      v_pid := t.player_id;
      CONTINUE WHEN public.player_draft_club_has_bid(v_club, v_pid);

      v_leader := public.player_draft_autobid_leader(v_pid, b.draft_start, b.draft_window_end);$s$;
  a2_new text := $s$    -- B) Threads not yet entered. With max players = N only the top N
    -- targets not already at the club are worked: phase 1 opens fresh threads
    -- (earning credits), phase 2 joins other clubs' threads with them.
    v_window := NULL;
    IF pl.max_wins IS NOT NULL THEN
      SELECT coalesce(array_agg(w.id), '{}'::bigint[]) INTO v_window
      FROM (
        SELECT tw.id FROM public.player_draft_autobid_targets tw
        WHERE tw.plan_id = pl.id AND tw.included
          AND tw.state IS DISTINCT FROM 'owned'
        ORDER BY tw.priority, tw.id
        LIMIT pl.max_wins
      ) w;

      UPDATE public.player_draft_autobid_targets tx
      SET state = 'skipped',
          state_note = format('Outside your top %s', pl.max_wins),
          updated_at = now()
      WHERE tx.plan_id = pl.id AND tx.included
        AND NOT (tx.id = ANY(v_window))
        AND tx.state NOT IN ('owned', 'won', 'leading', 'in_play', 'beaten')
        AND (tx.state IS DISTINCT FROM 'skipped'
          OR tx.state_note IS DISTINCT FROM format('Outside your top %s', pl.max_wins));
    END IF;

    FOR v_phase IN 1..2 LOOP
    FOR t IN
      SELECT * FROM public.player_draft_autobid_targets
      WHERE plan_id = pl.id AND included
        AND state NOT IN ('ineligible', 'owned', 'won')
        AND (v_window IS NULL OR id = ANY(v_window))
      ORDER BY priority, id
    LOOP
      v_pid := t.player_id;
      CONTINUE WHEN public.player_draft_club_has_bid(v_club, v_pid);

      v_leader := public.player_draft_autobid_leader(v_pid, b.draft_start, b.draft_window_end);
      CONTINUE WHEN v_phase = 1 AND v_leader IS NOT NULL;$s$;

  a3_old text := $s$        ELSIF pl.max_wins IS NOT NULL AND v_plan_inplay + 1 > pl.max_wins THEN
          v_state := 'skipped';
          v_note := format('Max players to win reached (%s)', pl.max_wins);
$s$;
  a3_new text := '';

  a4_old text := $s$      v_progress := true;
    END LOOP;
$s$;
  a4_new text := $s$      v_progress := true;
    END LOOP;
    END LOOP;
$s$;

  a5_old text := $s$It opens / joins threads in your priority order (credits permitting) and bids up to your max on each. $s$;
  a5_new text := $s$It works your top targets in priority order — opening fresh threads first, then joining other clubs'' threads with the credits earned — and bids up to your max on each. $s$;
BEGIN
  SELECT pg_get_functiondef('public.player_draft_autobid_run_plan(bigint)'::regprocedure) INTO v_def;
  v_def := replace(v_def, E'\r\n', E'\n');

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'player_draft_autobid_run_plan already works the top N';
    RETURN;
  END IF;

  IF position(a1_old IN v_def) = 0 THEN RAISE EXCEPTION 'anchor 1 (declarations) not found'; END IF;
  IF position(a2_old IN v_def) = 0 THEN RAISE EXCEPTION 'anchor 2 (section B loop) not found'; END IF;
  IF position(a3_old IN v_def) = 0 THEN RAISE EXCEPTION 'anchor 3 (max players check) not found'; END IF;
  IF position(a4_old IN v_def) = 0 THEN RAISE EXCEPTION 'anchor 4 (end of section B) not found'; END IF;

  v_def := replace(v_def, a1_old, a1_new);
  v_def := replace(v_def, a2_old, a2_new);
  v_def := replace(v_def, a3_old, a3_new);
  v_def := replace(v_def, a4_old, a4_new);
  v_def := replace(v_def, a5_old, a5_new);

  EXECUTE v_def;
END;
$patch$;

-- Check: should return true
SELECT position('FOR v_phase IN 1..2 LOOP' IN pg_get_functiondef(
  'public.player_draft_autobid_run_plan(bigint)'::regprocedure
)) > 0 AS top_n_installed;
