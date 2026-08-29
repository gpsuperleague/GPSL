-- =============================================================================
-- Response fines each month + restart propose/counter on rollover
--
-- At each GPSL month lock:
--   1) Track overdue replies on catch-up as well as open play-month fixtures
--   2) Fine the club whose turn it was (₿2.5m) — play month closing OR catch-up
--      (once per fixture per closed month; can fine again next month)
--   3) Incomplete negotiations (status negotiating) for those fixtures reset to
--      unscheduled so home proposes again in the new month
--
-- Does not forfeit the match — fixture rolls forward as catch-up if still unplayed.
-- Safe re-run.
-- =============================================================================

-- Mid-month / tick: count misses for catch-up too
CREATE OR REPLACE FUNCTION public.competition_process_scheduling_response_deadlines(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_miss_num smallint;
  v_count int := 0;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at,
      s.response_miss_count
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_due_at IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at < now()
      AND (
        public.match_schedule_fixture_play_month_open(f.id)
        OR public.match_schedule_fixture_is_catch_up(f.id)
      )
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
  LOOP
    v_miss_num := coalesce(v_row.response_miss_count, 0) + 1;

    UPDATE public.competition_fixture_schedule
    SET
      response_due_at = response_due_at + interval '24 hours',
      response_miss_count = v_miss_num,
      updated_at = now()
    WHERE fixture_id = v_row.fixture_id;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'misses_tracked', v_count,
    'fines_deferred', true
  );
END;
$function$;

-- Month lock: fine non-replier, then restart negotiation for incomplete arrange
CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_response_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_note_key text;
  v_note_body text;
  v_apply jsonb;
  v_fined jsonb := '[]'::jsonb;
  v_count int := 0;
  v_skipped int := 0;
  v_reset int := 0;
  v_is_catch_up boolean;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  -- Fine clubs that owed a reply and were overdue / had misses
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_required_club_short_name,
      s.response_miss_count,
      f.gpsl_month,
      f.matchday
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND (
        f.gpsl_month = p_closed_gpsl_month
        OR public.match_schedule_fixture_is_catch_up(f.id)
      )
      AND (
        coalesce(s.response_miss_count, 0) > 0
        OR (
          s.response_due_at IS NOT NULL
          AND s.response_due_at < v_lock
        )
      )
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.response_required_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    v_note_key := format(
      'sched_response_lock:%s:%s',
      p_closed_gpsl_month,
      v_row.fixture_id
    );

    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_response_deadline'
        AND fa.note LIKE v_note_key || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_is_catch_up := public.match_schedule_fixture_is_catch_up(v_row.fixture_id)
      AND v_row.gpsl_month IS DISTINCT FROM p_closed_gpsl_month;

    v_note_body := format(
      '%s|Response deadline missed · %s fixture · MD%s · assessed at month lock (misses: %s)%s',
      v_note_key,
      public.competition_gpsl_month_label(v_row.gpsl_month),
      v_row.matchday,
      coalesce(v_row.response_miss_count, 0),
      CASE WHEN v_is_catch_up THEN ' · catch-up' ELSE '' END
    );

    v_apply := public.competition_apply_club_fine_tariff(
      v_row.response_required_club_short_name,
      'match_response_deadline',
      NULL,
      v_note_body,
      v_row.fixture_id,
      p_season_id
    );

    v_count := v_count + 1;
    v_fined := v_fined || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'club', v_row.response_required_club_short_name,
        'catch_up', v_is_catch_up,
        'apply', v_apply
      )
    );
  END LOOP;

  -- Restart propose/counter for incomplete negotiations rolling into the next month
  FOR v_row IN
    SELECT s.fixture_id, s.pending_proposal_id
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND (
        f.gpsl_month = p_closed_gpsl_month
        OR public.match_schedule_fixture_is_catch_up(f.id)
      )
  LOOP
    IF v_row.pending_proposal_id IS NOT NULL THEN
      UPDATE public.competition_fixture_schedule_proposal
      SET status = 'withdrawn'
      WHERE id = v_row.pending_proposal_id
        AND status = 'pending';
    END IF;

    UPDATE public.competition_fixture_schedule_proposal
    SET status = 'withdrawn'
    WHERE fixture_id = v_row.fixture_id
      AND status = 'pending';

    PERFORM public.match_schedule_reset_to_unscheduled(v_row.fixture_id);
    v_reset := v_reset + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'fines_applied', v_count,
    'skipped', v_skipped,
    'negotiations_reset', v_reset,
    'fined', v_fined
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_response_deadlines(bigint)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_response_fines(bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
