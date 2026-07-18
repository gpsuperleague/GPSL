-- =============================================================================
-- Recovery when a GPSL month was ended early without opening the next month.
-- Also hardens admin season lookup (is_current + active, with active fallback).
-- Run once after competition_admin_end_gpsl_month.sql and admin_season_lifecycle.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_live_season_id()
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NOT NULL THEN
    RETURN v_season_id;
  END IF;

  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  RETURN v_season_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_between_months_context(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_last record;
  v_next record;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF public.competition_active_gpsl_month(p_season_id, now()) IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_already_active',
      'active_gpsl_month', public.competition_active_gpsl_month(p_season_id, now())
    );
  END IF;

  SELECT *
  INTO v_last
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.lock_at <= now()
  ORDER BY c.sort_order DESC
  LIMIT 1;

  SELECT *
  INTO v_next
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.unlock_at > now()
  ORDER BY c.sort_order ASC
  LIMIT 1;

  IF v_last.gpsl_month IS NULL OR v_next.gpsl_month IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_active_month',
      'season_id', p_season_id
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'reason', 'between_months',
    'last_locked_month', v_last.gpsl_month,
    'last_locked_month_label', public.competition_gpsl_month_label(v_last.gpsl_month),
    'last_locked_at', v_last.lock_at,
    'next_gpsl_month', v_next.gpsl_month,
    'next_gpsl_month_label', public.competition_gpsl_month_label(v_next.gpsl_month),
    'next_scheduled_unlock_at', v_next.unlock_at,
    'next_scheduled_lock_at', v_next.lock_at,
    'calendar_months_shifted', (
      SELECT count(*)::int
      FROM public.competition_season_calendar c
      WHERE c.season_id = p_season_id
        AND c.sort_order >= v_next.sort_order
    ),
    'confirm_phrase', 'OPEN GPSL MONTH',
    'recovery_hint',
      'The previous GPSL month was locked without opening the next month. Open the next month now to resume play.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_open_next_gpsl_month_preview(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_season_id := coalesce(p_season_id, public.competition_admin_live_season_id());

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar', 'season_id', v_season_id);
  END IF;

  RETURN public.competition_admin_between_months_context(v_season_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_open_next_gpsl_month(
  p_confirm_phrase text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_preview jsonb;
  v_season_id bigint;
  v_pull jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(btrim(p_confirm_phrase), '') <> 'OPEN GPSL MONTH' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: OPEN GPSL MONTH';
  END IF;

  v_preview := public.competition_admin_open_next_gpsl_month_preview(p_season_id);

  IF coalesce((v_preview ->> 'ok')::boolean, false) IS NOT TRUE THEN
    RETURN v_preview;
  END IF;

  v_season_id := (v_preview ->> 'season_id')::bigint;

  v_pull := public.competition_admin_pull_forward_calendar_months(
    v_season_id,
    v_preview ->> 'last_locked_month'
  );

  IF coalesce((v_pull ->> 'ok')::boolean, false) IS NOT TRUE THEN
    RETURN v_preview || jsonb_build_object(
      'opened', false,
      'calendar_pull_forward', v_pull
    );
  END IF;

  RETURN v_preview || jsonb_build_object(
    'opened', true,
    'calendar_pull_forward', v_pull,
    'active_gpsl_month_after', public.competition_active_gpsl_month(v_season_id, now())
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_end_gpsl_month_preview(
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_unlock_next_month boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_cal record;
  v_next record;
  v_gap jsonb;
  v_unplayed_league int := 0;
  v_unplayed_cup int := 0;
  v_pending_submissions int := 0;
  v_shift interval;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_season_id := coalesce(p_season_id, public.competition_admin_live_season_id());

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar', 'season_id', v_season_id);
  END IF;

  v_month := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  IF v_month IS NULL THEN
    v_month := public.competition_active_gpsl_month(v_season_id, now());
  END IF;

  IF v_month IS NULL THEN
    v_gap := public.competition_admin_between_months_context(v_season_id);
    IF coalesce((v_gap ->> 'ok')::boolean, false) THEN
      RETURN v_gap || jsonb_build_object(
        'confirm_phrase', CASE
          WHEN coalesce(p_unlock_next_month, false) THEN 'END MONTH OPEN NEXT'
          ELSE 'END GPSL MONTH'
        END
      );
    END IF;

    RETURN jsonb_build_object(
      'ok', false,
      'reason', coalesce(v_gap ->> 'reason', 'no_active_month'),
      'season_id', v_season_id,
      'confirm_phrase', CASE
        WHEN coalesce(p_unlock_next_month, false) THEN 'END MONTH OPEN NEXT'
        ELSE 'END GPSL MONTH'
      END
    );
  END IF;

  SELECT *
  INTO v_cal
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season_id
    AND c.gpsl_month = v_month;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_on_calendar',
      'gpsl_month', v_month
    );
  END IF;

  SELECT *
  INTO v_next
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season_id
    AND c.sort_order = v_cal.sort_order + 1;

  IF coalesce(p_unlock_next_month, false) AND v_next.gpsl_month IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_next_month',
      'gpsl_month', v_month,
      'gpsl_month_label', public.competition_gpsl_month_label(v_month)
    );
  END IF;

  IF coalesce(p_unlock_next_month, false) AND v_next.unlock_at <= now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'next_month_already_open',
      'gpsl_month', v_month,
      'next_gpsl_month', v_next.gpsl_month
    );
  END IF;

  SELECT count(*)::int
  INTO v_unplayed_league
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND f.competition_type = 'league'
    AND f.status <> 'played';

  SELECT count(*)::int
  INTO v_unplayed_cup
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND f.competition_type = 'cup'
    AND f.status <> 'played';

  SELECT count(*)::int
  INTO v_pending_submissions
  FROM public.competition_result_submissions s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND s.status = 'pending';

  v_shift := CASE
    WHEN coalesce(p_unlock_next_month, false) THEN now() - v_next.unlock_at
    ELSE NULL
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'unlock_at', v_cal.unlock_at,
    'lock_at', v_cal.lock_at,
    'is_live', (now() >= v_cal.unlock_at AND now() < v_cal.lock_at),
    'is_already_locked', (now() >= v_cal.lock_at),
    'unplayed_league', v_unplayed_league,
    'unplayed_cup', v_unplayed_cup,
    'pending_submissions', v_pending_submissions,
    'unlock_next_month', coalesce(p_unlock_next_month, false),
    'next_gpsl_month', v_next.gpsl_month,
    'next_gpsl_month_label', CASE
      WHEN v_next.gpsl_month IS NOT NULL THEN public.competition_gpsl_month_label(v_next.gpsl_month)
      ELSE NULL
    END,
    'next_scheduled_unlock_at', v_next.unlock_at,
    'next_scheduled_lock_at', v_next.lock_at,
    'calendar_shift', v_shift,
    'calendar_months_shifted', CASE
      WHEN coalesce(p_unlock_next_month, false) AND v_next.gpsl_month IS NOT NULL THEN (
        SELECT count(*)::int
        FROM public.competition_season_calendar c
        WHERE c.season_id = v_season_id
          AND c.sort_order >= v_next.sort_order
      )
      ELSE 0
    END,
    'confirm_phrase', CASE
      WHEN coalesce(p_unlock_next_month, false) THEN 'END MONTH OPEN NEXT'
      ELSE 'END GPSL MONTH'
    END,
    'jobs', jsonb_build_array(
      'calendar_lock',
      'loan_installments_due',
      'team_of_month',
      'gpsl_sport_edition',
      'scheduling_response_deadlines',
      'scheduling_arrangement_fines',
      'scheduling_response_fines',
      'scheduling_checkin_no_show_forfeits',
      CASE
        WHEN coalesce(p_unlock_next_month, false) THEN 'calendar_pull_forward'
        ELSE NULL
      END
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_end_season()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_season
    FROM public.competition_seasons
    WHERE status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active current season to end';
  END IF;

  UPDATE public.competition_seasons
  SET status = 'complete', is_current = false, ended_at = coalesce(ended_at, now())
  WHERE id = v_season.id;

  UPDATE public.global_settings
  SET league_phase = 'summer_break', updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'season_id', v_season.id,
    'label', v_season.label,
    'league_phase', 'summer_break'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_live_season_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_between_months_context(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_open_next_gpsl_month_preview(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_open_next_gpsl_month(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_end_season() TO authenticated;

NOTIFY pgrst, 'reload schema';
