-- =============================================================================
-- Player draft auto-bid: scale for 20–30 live plans (2026-10-08)
-- =============================================================================
-- 1) Indexes for the per-thread lookups the engine and max-bid system run
--    hundreds of times a minute (leader / high bid / min next bid / has bid).
-- 2) Tick commits after EACH plan (procedure), so one plan's bids and locks
--    are released straight away instead of being held until every plan has
--    run — manual bidders are never stuck waiting on the whole tick.
-- 3) Fair order (least recently run first) and a 50s budget per minute, so a
--    slow minute never starves the same plans or overlaps the next tick.
--
-- Safe re-run. Bidding rules are unchanged.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Indexes (draft bids: direct, no seller)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS player_transfer_bids_draft_player_time_idx
  ON public."Player_Transfer_Bids" ((coalesce(player_id, direct_bid_id::text)), bid_time)
  WHERE is_direct = true AND seller_club_id IS NULL;

CREATE INDEX IF NOT EXISTS player_transfer_bids_draft_club_time_idx
  ON public."Player_Transfer_Bids" (bidder_club_id, bid_time)
  WHERE is_direct = true AND seller_club_id IS NULL;

CREATE INDEX IF NOT EXISTS player_draft_autobid_targets_plan_state_idx
  ON public.player_draft_autobid_targets (plan_id, state);

ANALYZE public."Player_Transfer_Bids";

-- ---------------------------------------------------------------------------
-- 2. One plan, errors recorded on the plan (never aborts the tick)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.player_draft_autobid_run_plan_safe(p_plan_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int := 0;
BEGIN
  BEGIN
    v_n := public.player_draft_autobid_run_plan(p_plan_id);
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.player_draft_autobid_plans
    SET last_error = left(SQLERRM, 500), last_run_at = now()
    WHERE id = p_plan_id;
    v_n := 0;
  END;
  RETURN coalesce(v_n, 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.player_draft_autobid_run_plan_safe(bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Tick procedure: commit per plan, fair order, time budget
--    (no SECURITY DEFINER / SET clause — both block COMMIT in procedures;
--     pg_cron runs it as the job owner)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.player_draft_autobid_tick_proc()
LANGUAGE plpgsql
AS $proc$
DECLARE
  b record;
  v_paused boolean;
  v_ids bigint[];
  v_id bigint;
  v_started timestamptz := clock_timestamp();
BEGIN
  IF NOT pg_try_advisory_lock(hashtext('gpsl_draft_autobid_tick')) THEN
    RETURN;
  END IF;

  PERFORM public.player_draft_autobid_finish_due();
  COMMIT;

  SELECT coalesce(gs.draft_autobid_paused, false) INTO v_paused
  FROM public.global_settings gs WHERE gs.id = 1;

  SELECT * INTO b FROM public.draft_auction_window_bounds();

  IF NOT coalesce(v_paused, false)
     AND coalesce(b.draft_enabled, false) AND b.draft_start IS NOT NULL
     AND now() >= b.draft_start AND now() < b.draft_window_end THEN

    SELECT array_agg(pl.id ORDER BY pl.last_run_at NULLS FIRST, pl.created_at, pl.id)
    INTO v_ids
    FROM public.player_draft_autobid_plans pl
    WHERE pl.status IN ('scheduled', 'live')
      AND pl.enabled
      AND abs(extract(epoch FROM (pl.draft_start_at - b.draft_start))) <= 43200;

    IF v_ids IS NOT NULL THEN
      FOREACH v_id IN ARRAY v_ids LOOP
        EXIT WHEN clock_timestamp() - v_started > interval '50 seconds';
        PERFORM public.player_draft_autobid_run_plan_safe(v_id);
        COMMIT;
      END LOOP;
    END IF;
  END IF;

  PERFORM pg_advisory_unlock(hashtext('gpsl_draft_autobid_tick'));
END;
$proc$;

REVOKE ALL ON PROCEDURE public.player_draft_autobid_tick_proc() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Cron → procedure
-- ---------------------------------------------------------------------------
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-draft-autobid');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-draft-autobid',
      '* * * * *',
      $job$CALL public.player_draft_autobid_tick_proc();$job$
    );
  END IF;
END;
$cron$;

-- Check
SELECT
  (SELECT command FROM cron.job WHERE jobname = 'gpsl-draft-autobid') AS cron_command,
  to_regclass('public.player_transfer_bids_draft_player_time_idx') IS NOT NULL AS player_idx,
  to_regclass('public.player_transfer_bids_draft_club_time_idx') IS NOT NULL AS club_idx;
