-- =============================================================================
-- Transfer Market anti-snipe: extend from scheduled end_time (not now()+1h)
--
-- Rules (all_listings):
--   Bid in final 2 hours → +1 hour once  (end_time := end_time + 1 hour)
--   Then bid in final 5 minutes → +5 minutes (can repeat)
--
-- Bug: a late bid ~20m before expiry looked like "1 hour remaining from the
-- bid", so the new end landed only ~30–40m past the original. That is what
-- GREATEST(end_time, now()+1 hour) / now()+1 hour does. Correct behaviour is
-- always additive on the scheduled end: original_end + 1 hour.
--
-- This patch:
--   1) Shared helper transferengine_apply_listing_bid_extension
--   2) Apply on bid (AFTER INSERT) so the clock jumps immediately
--   3) Harden expiry handler to use the same helper (never now()+1h)
--   4) Optional repair for Active listings short of initial_end + 1h
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transferengine_apply_listing_bid_extension(
  p_listing_id bigint,
  p_bid_time timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing            public."Player_Transfer_Listings"%rowtype;
  v_bid_at             timestamptz := coalesce(p_bid_time, now());
  v_late_window        interval := interval '2 hours';
  v_main_extension     interval := interval '1 hour';
  v_micro_window       interval := interval '5 minutes';
  v_micro_ext          interval := interval '5 minutes';
  v_late_window_start  timestamptz;
  v_micro_window_start timestamptz;
BEGIN
  IF p_listing_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF lower(coalesce(v_listing.status::text, '')) IS DISTINCT FROM 'active' THEN
    RETURN false;
  END IF;

  IF lower(coalesce(v_listing.listing_type::text, '')) = 'draft' THEN
    RETURN false;
  END IF;

  IF v_listing.end_time IS NULL THEN
    RETURN false;
  END IF;

  -- Bid must fall in the scheduled auction window (allow tiny clock skew past end)
  IF v_bid_at > v_listing.end_time + interval '2 minutes' THEN
    RETURN false;
  END IF;

  IF NOT coalesce(v_listing.was_extended, false) THEN
    v_late_window_start := v_listing.end_time - v_late_window;

    IF v_bid_at >= v_late_window_start
       AND v_bid_at <= v_listing.end_time + interval '2 minutes' THEN
      -- CRITICAL: add to scheduled end — never now() + 1 hour
      UPDATE public."Player_Transfer_Listings"
      SET end_time = v_listing.end_time + v_main_extension,
          was_extended = true,
          hour_extended = true,
          extension_type = '1h',
          extension_count = coalesce(extension_count, 0) + 1,
          last_extension_time = now(),
          extension_state = '1h'
      WHERE id = v_listing.id;

      RETURN true;
    END IF;

    RETURN false;
  END IF;

  -- Already had the +1h: micro soft-close in final 5 minutes
  v_micro_window_start := v_listing.end_time - v_micro_window;

  IF v_bid_at >= v_micro_window_start
     AND v_bid_at <= v_listing.end_time + interval '2 minutes' THEN
    UPDATE public."Player_Transfer_Listings"
    SET end_time = v_listing.end_time + v_micro_ext,
        was_extended = true,
        extension_type = '5m',
        extension_count = coalesce(extension_count, 0) + 1,
        last_extension_time = now(),
        extension_state = '5m'
    WHERE id = v_listing.id;

    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

COMMENT ON FUNCTION public.transferengine_apply_listing_bid_extension(bigint, timestamptz) IS
  'Anti-snipe: late bid adds 1h (once) or 5m to scheduled end_time — never now()+1h.';

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_antisnipe_extend()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM public.transferengine_apply_listing_bid_extension(
    NEW.listing_id,
    coalesce(NEW.bid_time, now())
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_antisnipe_extend ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_antisnipe_extend
  AFTER INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_antisnipe_extend();

-- Expiry path: same additive rule, then settle if no extension applied
CREATE OR REPLACE FUNCTION public.transferengine_handle_expiry_or_extension(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing    public."Player_Transfer_Listings"%rowtype;
  v_latest_bid public."Player_Transfer_Bids"%rowtype;
  v_extended   boolean := false;
BEGIN
  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found in handle_expiry_or_extension', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.transferengine_sync_listing_high_bid(p_listing_id);

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  SELECT *
  INTO v_latest_bid
  FROM public."Player_Transfer_Bids"
  WHERE listing_id = v_listing.id
  ORDER BY bid_time DESC
  LIMIT 1;

  IF NOT FOUND THEN
    PERFORM public.transferengine_evaluate_expired_listing(v_listing.id);
    RETURN;
  END IF;

  v_extended := public.transferengine_apply_listing_bid_extension(
    v_listing.id,
    v_latest_bid.bid_time
  );

  IF v_extended THEN
    RETURN;
  END IF;

  PERFORM public.transferengine_evaluate_expired_listing(v_listing.id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_apply_listing_bid_extension(bigint, timestamptz)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Repair Active standard/direct listings that got a short "now()+1h" style
-- first extension (end still before initial_end + 1 hour).
-- ---------------------------------------------------------------------------
UPDATE public."Player_Transfer_Listings" l
SET end_time = l.initial_end_time + interval '1 hour',
    was_extended = true,
    hour_extended = true,
    extension_type = coalesce(nullif(l.extension_type, 'none'), '1h'),
    last_extension_time = coalesce(l.last_extension_time, now()),
    extension_state = coalesce(nullif(l.extension_state, 'none'), '1h')
WHERE l.status = 'Active'
  AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
  AND l.initial_end_time IS NOT NULL
  AND coalesce(l.was_extended, false) = true
  AND l.end_time < l.initial_end_time + interval '1 hour'
  AND l.end_time > l.initial_end_time;

-- Sanity read (optional): recent extended actives
-- SELECT id, seller_club_id, player_id,
--        initial_end_time AT TIME ZONE 'Europe/London' AS initial_uk,
--        end_time AT TIME ZONE 'Europe/London' AS end_uk,
--        was_extended, hour_extended, extension_type, extension_count
-- FROM public."Player_Transfer_Listings"
-- WHERE status = 'Active' AND coalesce(was_extended, false)
-- ORDER BY end_time DESC
-- LIMIT 20;
