-- =============================================================================
-- Match scheduling rules refresh (2026-09-11)
--
-- Agreed owner rules:
--   • Late band = last 48h before play-month unlock → ₿2.5m late arrangement
--   • No home proposal by prior-month lock → ₿5m every later lock until proposed
--   • First reply: due at prior unlock if proposed early; 48h if late-band first
--     offer; counters / catch-up → 24h
--   • Response fine ₿2.5m at lock ONLY if reply deadline already exceeded
--   • Carry negotiation (do NOT reset to unscheduled)
--   • League play window = scheduled month + 2; cup = +1 (May: no extra)
--   • After window: award by activity ladder; tie → 0–0
--   • Holiday: suppress arrangement/response/no-proposal fines while away;
--     at award, club on holiday for scheduled month forfeits (both → 0–0)
--
-- Run after existing match_scheduling_* patches. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Tariffs
-- ---------------------------------------------------------------------------
UPDATE public.competition_fine_tariff
SET
  amount = 5000000,
  label = 'Match Management Fine (no proposal)',
  is_active = true,
  updated_at = now()
WHERE code = 'match_mgmt_no_proposal';

UPDATE public.competition_fine_tariff
SET
  amount = 2500000,
  label = 'Late Arrangement Fee',
  is_active = true,
  updated_at = now()
WHERE code = 'match_late_arrangement';

UPDATE public.competition_fine_tariff
SET
  label = 'Missed scheduling response',
  is_active = true,
  updated_at = now()
WHERE code = 'match_response_deadline';

INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES (
  'match_window_expiry',
  'Unplayed window expiry',
  'scheduling',
  'fine',
  0,
  'fixed',
  115,
  true
)
ON CONFLICT (code) DO UPDATE SET
  label = EXCLUDED.label,
  category = EXCLUDED.category,
  is_active = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Holiday / play-window helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_club_on_holiday_for_month(
  p_season_id bigint,
  p_club_short_name text,
  p_gpsl_month text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    JOIN public.competition_season_calendar c
      ON c.season_id = h.season_id
     AND lower(btrim(c.gpsl_month)) = lower(btrim(p_gpsl_month))
    WHERE h.season_id = p_season_id
      AND h.club_short_name = p_club_short_name
      AND h.starts_at < c.lock_at
      AND h.ends_at > c.unlock_at
  );
$$;

/** Extra GPSL months after scheduled month when fixture may still be played. */
CREATE OR REPLACE FUNCTION public.match_schedule_play_grace_months(
  p_competition_type text,
  p_gpsl_month text
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(p_competition_type, ''))) = 'cup'
      AND lower(btrim(coalesce(p_gpsl_month, ''))) = 'may'
      THEN 0
    WHEN lower(btrim(coalesce(p_competition_type, ''))) = 'cup'
      THEN 1
    ELSE 2 -- league (and default)
  END;
$$;

/** True when play month has closed but fixture is still inside the grace window. */
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_within_play_window(
  p_fixture_id bigint,
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play_sort int;
  v_active text;
  v_active_sort int;
  v_grace int;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_play_sort := public.competition_gpsl_month_sort(v_f.gpsl_month);
  v_grace := public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month);
  v_active := public.competition_active_gpsl_month(v_f.season_id, p_at);

  IF v_active IS NULL THEN
    -- Before any month active: treat as within window if play month not yet locked
    RETURN NOT public.match_schedule_fixture_play_month_closed(p_fixture_id);
  END IF;

  v_active_sort := public.competition_gpsl_month_sort(v_active);
  IF v_active_sort IS NULL OR v_play_sort IS NULL THEN
    RETURN true;
  END IF;

  -- Still in/before play month, or within grace after
  RETURN v_active_sort <= v_play_sort + v_grace;
END;
$function$;

/** True when scheduled play month closed AND still within grace (catch-up). */
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_is_catch_up(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND public.match_schedule_fixture_play_month_closed(p_fixture_id)
      AND public.match_schedule_fixture_within_play_window(p_fixture_id, now())
  );
$$;

/** True when play window has fully expired (ready to award). */
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_play_window_expired(
  p_fixture_id bigint,
  p_closed_gpsl_month text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play_sort int;
  v_closed_sort int;
  v_grace int;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN false;
  END IF;

  v_play_sort := public.competition_gpsl_month_sort(v_f.gpsl_month);
  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);
  v_grace := public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month);

  IF v_play_sort IS NULL OR v_closed_sort IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_closed_sort >= v_play_sort + v_grace;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Response due-at (48h late band)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_compute_response_due_at(
  p_fixture_id bigint,
  p_proposal_id bigint,
  p_proposed_at timestamptz,
  p_proposer_club text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_play_unlock timestamptz;
  v_is_first_proposal boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  SELECT cal.unlock_at INTO v_play_unlock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_fixture.season_id
    AND cal.gpsl_month = v_fixture.gpsl_month;

  SELECT NOT EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.id <> p_proposal_id
      AND p.status <> 'withdrawn'
  )
  INTO v_is_first_proposal;

  -- Counters always 24h
  IF NOT v_is_first_proposal THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  -- First proposal before play month opens
  IF v_play_unlock IS NOT NULL AND p_proposed_at < v_play_unlock THEN
    -- Late band: last 48h before unlock → 48h to reply
    IF p_proposed_at >= v_play_unlock - interval '48 hours' THEN
      RETURN p_proposed_at + interval '48 hours';
    END IF;
    -- Early: away must reply by play-month unlock (prior month lock)
    RETURN v_play_unlock;
  END IF;

  -- First proposal after play month opened → 48h (same as late first offer)
  RETURN p_proposed_at + interval '48 hours';
END;
$function$;

-- Mid-month: track misses only — do NOT extend due_at (lock assesses overdue)
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
  v_count int := 0;
BEGIN
  FOR v_row IN
    SELECT s.fixture_id, s.response_miss_count
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
      AND public.match_schedule_fixture_within_play_window(f.id, now())
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
  LOOP
    UPDATE public.competition_fixture_schedule
    SET
      response_miss_count = coalesce(response_miss_count, 0) + 1,
      updated_at = now()
    WHERE fixture_id = v_row.fixture_id
      AND coalesce(response_miss_count, 0) = coalesce(v_row.response_miss_count, 0);

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'misses_tracked', v_count,
    'fines_deferred', true,
    'due_at_extended', false
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Arrangement fines (2.5m late / 5m none; 48h band; holiday suppress)
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
  v_holiday int := 0;
  v_play_label text;
  v_closed_label text;
BEGIN
  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);
  IF v_closed_sort IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_closed_month');
  END IF;

  SELECT c.lock_at INTO v_closed_lock
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
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_closed_sort + 1
      AND EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c."ShortName" = f.home_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_fixture_schedule s
      WHERE s.fixture_id = v_f.id AND s.status = 'agreed'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Suppress while home is on holiday overlapping the closed month
    IF public.match_schedule_club_on_holiday_for_month(
      p_season_id, v_f.home_club_short_name, p_closed_gpsl_month
    ) THEN
      v_holiday := v_holiday + 1;
      CONTINUE;
    END IF;

    v_first_at := public.match_schedule_home_first_proposal_at(v_f.id, v_closed_lock);
    v_deadline := v_f.play_unlock_at;
    v_play_label := public.competition_gpsl_month_label(v_f.gpsl_month);

    v_is_arrangement_deadline := (v_f.play_sort = v_closed_sort + 1);

    v_tariff_code := NULL;

    IF v_is_arrangement_deadline THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      ELSIF v_deadline IS NOT NULL
        AND v_first_at >= v_deadline - interval '48 hours'
        AND v_first_at < v_deadline
      THEN
        v_tariff_code := 'match_late_arrangement';
      END IF;
    ELSIF v_closed_sort >= v_f.play_sort THEN
      -- Recurring ₿5m while still no proposal (every lock)
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
      p_closed_gpsl_month, v_f.id, v_tariff_code
    );

    IF EXISTS (
      SELECT 1 FROM public.competition_fine_applied fa
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
      '%s|GPSL %s closed · %s fixture · MD%s vs %s · %s',
      v_note_key,
      v_closed_label,
      v_play_label,
      v_f.matchday,
      v_opponent,
      CASE v_tariff_code
        WHEN 'match_late_arrangement' THEN 'Late arrangement (last 48h)'
        ELSE 'No home proposal'
      END
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
        'tariff', v_tariff_code,
        'apply', v_apply
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'fined', v_fined,
    'skipped', v_skipped,
    'holiday_suppressed', v_holiday
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Response fines: overdue only, carry negotiation (no reset), holiday suppress
-- ---------------------------------------------------------------------------
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
  v_holiday int := 0;
BEGIN
  SELECT c.lock_at INTO v_lock
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

  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_required_club_short_name,
      s.response_due_at,
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
      AND s.response_due_at IS NOT NULL
      AND s.response_due_at < v_lock  -- only if deadline already exceeded
      AND public.match_schedule_fixture_within_play_window(f.id, v_lock)
      AND EXISTS (
        SELECT 1 FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id AND p.status = 'pending'
      )
      AND EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c."ShortName" = s.response_required_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    IF public.match_schedule_club_on_holiday_for_month(
      p_season_id, v_row.response_required_club_short_name, p_closed_gpsl_month
    ) THEN
      v_holiday := v_holiday + 1;
      CONTINUE;
    END IF;

    v_note_key := format(
      'sched_response_lock:%s:%s',
      p_closed_gpsl_month,
      v_row.fixture_id
    );

    IF EXISTS (
      SELECT 1 FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_response_deadline'
        AND fa.note LIKE v_note_key || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_note_body := format(
      '%s|Missed scheduling response · %s fixture · MD%s · reply was due %s · negotiation continues',
      v_note_key,
      public.competition_gpsl_month_label(v_row.gpsl_month),
      v_row.matchday,
      to_char(v_row.response_due_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
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
        'apply', v_apply
      )
    );
  END LOOP;

  -- Intentionally NO negotiation reset — pending proposals carry over

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'fines_applied', v_count,
    'skipped', v_skipped,
    'holiday_suppressed', v_holiday,
    'negotiations_reset', 0
  );
END;
$function$;

-- See part 2 appended below for awards / inbox / wire.
