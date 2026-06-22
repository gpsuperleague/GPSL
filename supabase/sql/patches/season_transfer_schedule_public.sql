-- =============================================================================
-- Season transfer schedule — public RPC for owner schedule strip (optional).
-- Client derives counts from inbox + special_auctions; this centralises counts.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.season_transfer_schedule_public()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_season_label text;
  v_season_start timestamptz;
  v_transfer_open boolean;
  v_cal record;
  v_aug record;
  v_jan record;
  v_player_used int;
  v_manager_used int;
  v_special_used int;
  v_preseason text;
  v_january text;
  v_player_live boolean;
  v_manager_live boolean;
  v_special_live boolean;
BEGIN
  SELECT s.id, s.started_at, s.label
  INTO v_season_id, v_season_start, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  LIMIT 1;

  SELECT transfer_window_open,
         draft_auction_enabled AND coalesce(draft_bidding_open, false),
         manager_draft_auction_enabled AND coalesce(manager_draft_bidding_open, false)
  INTO v_transfer_open, v_player_live, v_manager_live
  FROM public.global_settings
  LIMIT 1;

  SELECT EXISTS (
    SELECT 1 FROM public.special_auctions sa
    WHERE sa.status IN ('scheduled', 'active')
      AND sa.end_time > now()
  ) INTO v_special_live;

  SELECT *
  INTO v_cal
  FROM public.competition_calendar_status_public
  LIMIT 1;

  SELECT m.*
  INTO v_aug
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season_id AND m.gpsl_month = 'august'
  LIMIT 1;

  SELECT m.*
  INTO v_jan
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season_id AND m.gpsl_month = 'january'
  LIMIT 1;

  SELECT COUNT(DISTINCT regexp_replace(i.dedupe_key, ':[^:]+$', ''))
  INTO v_player_used
  FROM public.competition_inbox i
  WHERE i.message_type = 'draft_scheduled'
    AND i.dedupe_key LIKE 'draft_scheduled:player:%'
    AND (
      i.season_id = v_season_id
      OR (v_season_start IS NOT NULL AND i.created_at >= v_season_start)
    );

  SELECT COUNT(DISTINCT regexp_replace(i.dedupe_key, ':[^:]+$', ''))
  INTO v_manager_used
  FROM public.competition_inbox i
  WHERE i.message_type = 'draft_scheduled'
    AND i.dedupe_key LIKE 'draft_scheduled:manager:%'
    AND (
      i.season_id = v_season_id
      OR (v_season_start IS NOT NULL AND i.created_at >= v_season_start)
    );

  SELECT COUNT(*)::int
  INTO v_special_used
  FROM public.special_auctions sa
  WHERE sa.status IN ('scheduled', 'active', 'revealed', 'settled')
    AND (
      v_season_start IS NULL
      OR sa.created_at >= v_season_start
    );

  IF coalesce(v_aug.has_started, false) OR coalesce(v_aug.is_active, false) THEN
    v_preseason := 'closed';
  ELSIF v_cal.calendar_phase = 'pre_season' THEN
    v_preseason := CASE WHEN v_transfer_open THEN 'open' ELSE 'closed' END;
  ELSIF coalesce(v_aug.is_future, false) AND v_season_id IS NOT NULL THEN
    v_preseason := 'upcoming';
  ELSE
    v_preseason := 'closed';
  END IF;

  IF coalesce(v_jan.is_active, false) THEN
    v_january := CASE WHEN v_transfer_open THEN 'open' ELSE 'closed' END;
  ELSIF coalesce(v_jan.is_future, false) THEN
    v_january := 'upcoming';
  ELSE
    v_january := 'closed';
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'season_label', coalesce(v_season_label, v_cal.season_label),
    'player', jsonb_build_object(
      'total', 3,
      'used', coalesce(v_player_used, 0),
      'remaining', GREATEST(0, 3 - coalesce(v_player_used, 0)),
      'live', coalesce(v_player_live, false)
    ),
    'manager', jsonb_build_object(
      'total', 2,
      'used', coalesce(v_manager_used, 0),
      'remaining', GREATEST(0, 2 - coalesce(v_manager_used, 0)),
      'live', coalesce(v_manager_live, false)
    ),
    'special', jsonb_build_object(
      'total', 3,
      'used', coalesce(v_special_used, 0),
      'remaining', GREATEST(0, 3 - coalesce(v_special_used, 0)),
      'live', coalesce(v_special_live, false)
    ),
    'windows', jsonb_build_object(
      'preseason', jsonb_build_object('label', 'Summer window', 'range', 'Pre-season until August', 'status', v_preseason),
      'january', jsonb_build_object('label', 'Winter window', 'range', 'January', 'status', v_january)
    ),
    'transfer_open', coalesce(v_transfer_open, false)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.season_transfer_schedule_public() TO authenticated;
