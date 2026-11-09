-- =============================================================================
-- List for preview — pending listing before the next transfer window
--
-- Outside January / June / July / August, with the transfer window shut, a
-- standard listing may be saved as Pending Window when the player would be
-- sellable at the next window:
--   September–December → January (second half, this season)
--   February–May       → summer window (signing lock ends; a summer contract
--                        with one season left has ended and stays blocked)
--
-- The auction clock still starts only when the window is open AND the sell
-- lock has cleared. A window opened early leaves those rows pending.
-- Bids stay blocked until the window is open.
--
-- Run once in the Supabase SQL editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.player_sell_lock_reason_at(
  p_player_id text,
  p_second_half boolean,
  p_next_season boolean
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_p record;
BEGIN
  SELECT
    nullif(btrim(p."Contracted_Team"::text), '') AS club,
    nullif(btrim(p."Season_Signed"), '') AS signed,
    p.contract_seasons_remaining AS rem,
    coalesce(p.contract_end_window, 'summer') AS end_window,
    coalesce(p.contract_join_second_half, false) AS joined_second_half,
    coalesce(p.pesdb_unavailable, false) AS legacy
  INTO v_p
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;
  IF v_p.legacy THEN
    RETURN 'legacy';
  END IF;
  IF v_p.club IS NULL THEN
    RETURN NULL;
  END IF;
  IF to_regprocedure('public.player_is_active_stopgap_loan(text)') IS NOT NULL
     AND public.player_is_active_stopgap_loan(v_pid) THEN
    RETURN 'loan';
  END IF;

  IF NOT coalesce(p_next_season, false)
     AND public.player_signed_this_season(v_p.signed) THEN
    IF v_p.joined_second_half THEN
      RETURN 'signed_this_season';
    ELSIF NOT coalesce(p_second_half, false) THEN
      RETURN 'signed_this_season';
    END IF;
  END IF;

  IF v_p.rem IS NOT NULL AND v_p.rem <= 0 THEN
    RETURN 'contract_ended';
  END IF;

  -- Summer deal in its last season ends at the summer rollover.
  IF v_p.rem = 1
     AND coalesce(p_next_season, false)
     AND v_p.end_window IS DISTINCT FROM 'january' THEN
    RETURN 'contract_ended';
  END IF;

  IF v_p.rem = 1 AND (v_p.end_window = 'january' OR coalesce(p_second_half, false)) THEN
    RETURN 'final_half';
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_preview_listable(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_open boolean;
  v_month text;
  v_second boolean;
  v_next boolean;
  v_season bigint;
BEGIN
  SELECT coalesce(transfer_window_open, false)
  INTO v_open
  FROM public.global_settings
  WHERE id = 1;

  IF coalesce(v_open, false) THEN
    RETURN false;
  END IF;

  v_season := public.current_gpsl_season_id();
  IF v_season IS NULL
     OR to_regprocedure('public.competition_active_gpsl_month(bigint,timestamptz)') IS NULL THEN
    RETURN false;
  END IF;

  v_month := lower(btrim(coalesce(
    public.competition_active_gpsl_month(v_season, now()),
    ''
  )));

  IF v_month IN ('january', 'june', 'july', 'august') OR v_month = '' THEN
    RETURN false;
  ELSIF v_month IN ('september', 'october', 'november', 'december') THEN
    v_second := true;
    v_next := false;
  ELSIF v_month IN ('february', 'march', 'april', 'may') THEN
    v_second := false;
    v_next := true;
  ELSE
    RETURN false;
  END IF;

  RETURN public.player_sell_lock_reason_at(p_player_id, v_second, v_next) IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.player_sell_lock_reason_at(text, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.player_preview_listable(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.player_sell_lock_reason_at(text, boolean, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.player_preview_listable(text) TO authenticated, service_role;

-- Pending Window insert is allowed when the player is listable at the next window.
-- Active listings, bids, and sales still use the current sell lock.
CREATE OR REPLACE FUNCTION public.trg_listing_block_same_season_sale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.player_id IS NULL OR btrim(NEW.player_id::text) = '' THEN
    RETURN NEW;
  END IF;

  IF lower(coalesce(NEW.status::text, '')) = 'pending window'
     AND lower(coalesce(NEW.listing_type::text, 'standard')) NOT IN ('draft', 'direct')
     AND public.player_preview_listable(btrim(NEW.player_id::text)) THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(btrim(NEW.player_id::text));
  RETURN NEW;
END;
$function$;

-- Do not start the clock while the window is shut, or while the sell lock remains.
CREATE OR REPLACE FUNCTION public.activate_pending_window_listings(
  p_now timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_now timestamptz := coalesce(p_now, now());
  v_end timestamptz;
  v_open boolean;
  v_count int := 0;
BEGIN
  SELECT coalesce(transfer_window_open, false)
  INTO v_open
  FROM public.global_settings
  WHERE id = 1;

  IF NOT coalesce(v_open, false) THEN
    RETURN jsonb_build_object('ok', true, 'activated', 0, 'reason', 'window_closed');
  END IF;

  v_end := public.compute_standard_listing_end_time(v_now);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Active',
      start_time = v_now,
      end_time = v_end,
      initial_end_time = v_end,
      seller_review_deadline = v_end,
      review_deadline = v_end,
      hour_extended = false,
      was_extended = false,
      extension_type = 'none',
      extension_count = 0,
      extension_state = 'none',
      last_extension_time = null
  WHERE l.status = 'Pending Window'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    AND coalesce(l.transfer_completed, false) = false
    AND (
      to_regprocedure('public.player_contract_sell_lock_reason(text)') IS NULL
      OR public.player_contract_sell_lock_reason(l.player_id::text) IS NULL
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'activated', v_count,
    'start_time', v_now,
    'end_time', v_end
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.activate_pending_window_listings(timestamptz)
  TO authenticated, service_role;

DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — preview listings go live only when the window is switched on';
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-preview-listing-activate') THEN
    PERFORM cron.unschedule('gpsl-preview-listing-activate');
  END IF;

  PERFORM cron.schedule(
    'gpsl-preview-listing-activate',
    '*/15 * * * *',
    $q$SELECT public.activate_pending_window_listings(now());$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule preview listing activation: %', SQLERRM;
END
$cron$;

NOTIFY pgrst, 'reload schema';
