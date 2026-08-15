-- =============================================================================
-- Manager window FA board (board of 10): same end-time rule as player market
--   ≥ 24 hours from list/renew time, completing at the next 19:00 Europe/London
--
-- Fixes prior FA board helpers that used now()+48h / month-lock shortcuts
-- (often ending too soon or looking like "window open / spawn" timestamps).
--
-- Safe re-run. Depends on: compute_standard_listing_end_time(...)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.manager_window_fa_listing_end_at(
  p_season_id bigint,
  p_month text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_end timestamptz;
BEGIN
  -- Same rule as player transfer listings / owner-listed managers.
  -- p_season_id / p_month kept for call-site compatibility (month close still
  -- handled by manager_window_fa_close_batch when the TW month ends).
  v_end := public.compute_standard_listing_end_time(now());

  IF v_end IS NULL OR v_end <= now() THEN
    v_end := public.compute_standard_listing_end_time(now() + interval '1 second');
  END IF;

  RETURN v_end;
END;
$function$;

COMMENT ON FUNCTION public.manager_window_fa_listing_end_at(bigint, text) IS
  'FA board listing end: compute_standard_listing_end_time(now()) — ≥24h then next 19:00 Europe/London.';

-- Renew / revive expired no-bid FA rows with the standard rule
CREATE OR REPLACE FUNCTION public.manager_window_fa_renew_active()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_n int := 0;
BEGIN
  v_season_id := public.manager_window_fa_current_season_id();
  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'renewed', 0);
  END IF;

  v_month := coalesce(public.manager_window_fa_resolve_month(v_season_id), '');
  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    PERFORM public.manager_window_fa_close_batch(v_season_id, NULL);
    RETURN jsonb_build_object('ok', true, 'renewed', 0, 'closed_off_month', true);
  END IF;

  UPDATE public."Manager_Transfer_Listings" l
  SET end_time = public.manager_window_fa_listing_end_at(v_season_id, v_month),
      updated_at = now(),
      metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
        'end_rule', 'standard_24h_7pm_uk',
        'renewed_end', true
      )
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND (l.end_time IS NULL OR l.end_time <= now())
    AND l.current_highest_bidder IS NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'renewed', v_n, 'month', v_month);
END;
$function$;

-- One-shot: fix currently Active FA board rows (no high bidder) to the player rule.
-- Uses created_at when that still yields a future end; otherwise from now().
UPDATE public."Manager_Transfer_Listings" l
SET
  end_time = CASE
    WHEN public.compute_standard_listing_end_time(coalesce(l.created_at, now())) > now()
      THEN public.compute_standard_listing_end_time(coalesce(l.created_at, now()))
    ELSE public.compute_standard_listing_end_time(now())
  END,
  updated_at = now(),
  metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
    'end_rule', 'standard_24h_7pm_uk',
    'end_time_aligned_players', true,
    'aligned_at', now()
  )
WHERE l.listing_type = 'window_fa'
  AND l.status = 'Active'
  AND l.current_highest_bidder IS NULL;

GRANT EXECUTE ON FUNCTION public.manager_window_fa_listing_end_at(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_renew_active() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_renew_active() TO service_role;

NOTIFY pgrst, 'reload schema';
