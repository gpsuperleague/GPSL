-- =============================================================================
-- Match scheduling — Phase 1 arrangement fines at GPSL month lock
-- Run after: match_scheduling_inbox_proposer_sent.sql, competition_fines.sql,
--            owner_inbox_fine_fix.sql, competition_totm_tots_awards_repair.sql
--            (or any deploy with competition_calendar_month_tick + calendar jobs)
-- =============================================================================
-- Rules (summary):
--   • At each closed GPSL month M (lock_at <= now), league fixtures in scope
--     with no home proposal → Match Management Fine (recurring each month lock).
--   • At arrangement deadline for play month P (M lock where sort(P)=sort(M)+1,
--     or August at August lock): either ₿10m (no proposal) OR ₿5m (first home
--     proposal in last 24h before P.unlock_at), never both.
--   • Fixtures with any home proposal before assessment skip recurring fines.
--   • Skips played / cancelled / agreed fixtures.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Tariff category: scheduling
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_fine_tariff
  DROP CONSTRAINT IF EXISTS competition_fine_tariff_category_check;

ALTER TABLE public.competition_fine_tariff
  ADD CONSTRAINT competition_fine_tariff_category_check
  CHECK (
    category IN (
      'matchday', 'squad', 'transfer', 'manager', 'compensation', 'other', 'scheduling'
    )
  );

INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES
  (
    'match_mgmt_no_proposal',
    'Match Management Fine',
    'scheduling',
    'fine',
    10000000,
    'fixed',
    110,
    true
  ),
  (
    'match_late_arrangement',
    'Late Arrangement Fee',
    'scheduling',
    'fine',
    5000000,
    'fixed',
    111,
    true
  )
ON CONFLICT (code) DO UPDATE SET
  label = EXCLUDED.label,
  category = EXCLUDED.category,
  amount = EXCLUDED.amount,
  amount_mode = EXCLUDED.amount_mode,
  sort_order = EXCLUDED.sort_order,
  is_active = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

/** Earliest home-club proposal before p_before (exclusive assessment boundary). */
CREATE OR REPLACE FUNCTION public.match_schedule_home_first_proposal_at(
  p_fixture_id bigint,
  p_before timestamptz DEFAULT now()
)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT min(p.created_at)
  FROM public.competition_fixture_schedule_proposal p
  JOIN public.competition_fixtures f ON f.id = p.fixture_id
  WHERE p.fixture_id = p_fixture_id
    AND p.proposed_by_club_short_name = f.home_club_short_name
    AND p.status <> 'withdrawn'
    AND p.created_at < p_before;
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_home_has_proposed(
  p_fixture_id bigint,
  p_before timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.match_schedule_home_first_proposal_at(p_fixture_id, p_before) IS NOT NULL;
$$;

-- ---------------------------------------------------------------------------
-- Enforce fines for one closed GPSL month
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_arrangement_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_closed_sort smallint;
  v_closed_lock timestamptz;
  v_f record;
  v_first_at timestamptz;
  v_deadline timestamptz;
  v_is_arrangement_deadline boolean;
  v_tariff_code text;
  v_note_key text;
  v_note_body text;
  v_opponent text;
  v_apply jsonb;
  v_fined jsonb := '[]'::jsonb;
  v_skipped int := 0;
  v_play_label text;
  v_closed_label text;
BEGIN
  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);
  IF v_closed_sort IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_closed_month');
  END IF;

  SELECT c.lock_at
  INTO v_closed_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_closed_lock IS NULL OR v_closed_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  v_closed_label := public.competition_gpsl_month_label(p_closed_gpsl_month);

  FOR v_f IN
    SELECT
      f.id,
      f.matchday,
      f.gpsl_month,
      f.home_club_short_name,
      f.away_club_short_name,
      public.competition_gpsl_month_sort(f.gpsl_month) AS play_sort,
      cal_play.unlock_at AS play_unlock_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal_play
      ON cal_play.season_id = f.season_id
     AND cal_play.gpsl_month = f.gpsl_month
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_closed_sort + 1
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = f.home_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.competition_fixture_schedule s
      WHERE s.fixture_id = v_f.id
        AND s.status = 'agreed'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_first_at := public.match_schedule_home_first_proposal_at(v_f.id, v_closed_lock);
    v_deadline := v_f.play_unlock_at;
    v_play_label := public.competition_gpsl_month_label(v_f.gpsl_month);

    v_is_arrangement_deadline := (
      v_f.play_sort = v_closed_sort + 1
      OR (v_f.play_sort = v_closed_sort AND v_f.play_sort = 1)
    );

    v_tariff_code := NULL;

    IF v_is_arrangement_deadline THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      ELSIF v_first_at >= v_deadline - interval '24 hours'
        AND v_first_at < v_deadline
      THEN
        v_tariff_code := 'match_late_arrangement';
      END IF;
    ELSIF v_closed_sort >= v_f.play_sort THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      END IF;
    END IF;

    IF v_tariff_code IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_note_key := format(
      'sched_arrangement:%s:%s:%s',
      p_closed_gpsl_month,
      v_f.id,
      v_tariff_code
    );

    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_f.id
        AND fa.tariff_code = v_tariff_code
        AND fa.note LIKE v_note_key || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_opponent := coalesce(
      public.club_display_name(v_f.away_club_short_name),
      v_f.away_club_short_name
    );

    v_note_body := format(
      '%s|GPSL %s closed · %s fixture · MD%s vs %s',
      v_note_key,
      v_closed_label,
      v_play_label,
      v_f.matchday,
      v_opponent
    );

    v_apply := public.competition_apply_club_fine_tariff(
      v_f.home_club_short_name,
      v_tariff_code,
      NULL,
      v_note_body,
      v_f.id,
      p_season_id
    );

    v_fined := v_fined || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_f.id,
        'club', v_f.home_club_short_name,
        'tariff_code', v_tariff_code,
        'gpsl_month', v_f.gpsl_month,
        'apply', v_apply
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'closed_lock_at', v_closed_lock,
    'fines_applied', coalesce(jsonb_array_length(v_fined), 0),
    'skipped', v_skipped,
    'fined', v_fined
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Process all closed months not yet assessed (idempotent; safe every cron tick)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_process_scheduling_arrangement_fines(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_job_key text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = p_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month, c.lock_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'scheduling_arrangement_fines:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_res := public.competition_enforce_scheduling_arrangement_fines(
      p_season_id,
      v_cal.gpsl_month
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      v_job_key,
      v_cal.gpsl_month,
      coalesce(v_res, '{}'::jsonb)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_cal.gpsl_month,
        'result', v_res
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'processed', v_results
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Month tick — include arrangement fines (runs even before August squad job)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_calendar_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_sort smallint;
  v_august_sort constant smallint := public.competition_gpsl_month_sort('august');
  v_job_id bigint;
  v_enforcement jsonb;
  v_totm jsonb;
  v_sched_fines jsonb;
  v_out jsonb;
BEGIN
  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_calendar',
      'season_id', v_season_id
    );
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_month_sort := public.competition_gpsl_month_sort(v_month);

  v_out := jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'calendar_phase', CASE
      WHEN v_month IS NULL THEN 'between_months'
      ELSE 'in_month'
    END
  );

  IF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
    v_totm := public.competition_process_month_team_awards(v_season_id);
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  END IF;

  v_sched_fines := public.competition_process_scheduling_arrangement_fines(v_season_id);
  v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);

  IF v_month IS NULL OR v_month_sort IS NULL OR v_month_sort < v_august_sort THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'before_august')
    );
  END IF;

  INSERT INTO public.competition_season_calendar_jobs (
    season_id, job_key, gpsl_month, result
  )
  VALUES (
    v_season_id,
    'squad_minimum_august',
    v_month,
    jsonb_build_object('status', 'running')
  )
  ON CONFLICT (season_id, job_key) DO NOTHING
  RETURNING id INTO v_job_id;

  IF v_job_id IS NULL THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'already_ran')
    );
  END IF;

  v_enforcement := public.competition_enforce_squad_minimum_august(v_season_id);

  UPDATE public.competition_season_calendar_jobs
  SET result = v_enforcement,
      gpsl_month = v_month,
      ran_at = now()
  WHERE id = v_job_id;

  RETURN v_out || jsonb_build_object('squad_minimum_august', v_enforcement);
END;
$function$;

-- Admin manual run (testing / backfill one closed month)
CREATE OR REPLACE FUNCTION public.competition_admin_enforce_scheduling_arrangement_fines(
  p_closed_gpsl_month text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_res jsonb;
  v_job_key text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season';
  END IF;

  v_res := public.competition_enforce_scheduling_arrangement_fines(
    v_season_id,
    p_closed_gpsl_month
  );

  v_job_key := 'scheduling_arrangement_fines:' || p_closed_gpsl_month;

  INSERT INTO public.competition_season_calendar_jobs (
    season_id, job_key, gpsl_month, result
  )
  VALUES (
    v_season_id,
    v_job_key,
    p_closed_gpsl_month,
    coalesce(v_res, '{}'::jsonb)
  )
  ON CONFLICT (season_id, job_key) DO UPDATE
    SET result = excluded.result,
        gpsl_month = excluded.gpsl_month,
        ran_at = now();

  RETURN v_res;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_arrangement_fines(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_arrangement_fines(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_admin_enforce_scheduling_arrangement_fines(text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
