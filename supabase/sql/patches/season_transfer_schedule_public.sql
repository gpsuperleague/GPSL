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
  v_calendar_label text;
  v_player_used int;
  v_manager_used int;
  v_special_used int;
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

  SELECT season_label
  INTO v_calendar_label
  FROM public.competition_calendar_status_public
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

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'season_label', coalesce(v_season_label, v_calendar_label),
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
    'transfer_window', jsonb_build_object(
      'open', coalesce(v_transfer_open, false)
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.season_transfer_schedule_public() TO authenticated;
