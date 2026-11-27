-- Managers who are in the live manager draft stay on the market, but the
-- market cannot sell them. When the draft signs them, that market row is
-- cancelled and the FA board is topped back up with a random free agent.
-- Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Do not let a market auction finish while that manager is in the draft
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manager_market_hold_while_in_draft()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int := 0;
  v_end timestamptz;
BEGIN
  v_end := public.compute_standard_listing_end_time(now());
  IF v_end IS NULL OR v_end <= now() THEN
    v_end := now() + interval '24 hours';
  END IF;

  UPDATE public."Manager_Transfer_Listings" l
  SET end_time = v_end,
      updated_at = now(),
      metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
        'held_for_manager_draft', true,
        'held_at', now()
      )
  WHERE l.listing_type IS DISTINCT FROM 'draft'
    AND l.status = 'Active'
    AND (l.end_time IS NULL OR l.end_time <= now() + interval '6 hours')
    AND EXISTS (
      SELECT 1
      FROM public."Manager_Transfer_Listings" d
      WHERE d.manager_id = l.manager_id
        AND d.id <> l.id
        AND d.listing_type = 'draft'
        AND d.status = 'Active'
    );

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_manager_listing_block_settle_while_in_draft()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.listing_type IS DISTINCT FROM 'draft'
     AND OLD.status = 'Active'
     AND coalesce(NEW.transfer_completed, false)
     AND NOT coalesce(OLD.transfer_completed, false)
     AND EXISTS (
       SELECT 1
       FROM public."Manager_Transfer_Listings" d
       WHERE d.manager_id = NEW.manager_id
         AND d.id <> NEW.id
         AND d.listing_type = 'draft'
         AND d.status = 'Active'
     )
  THEN
    RAISE EXCEPTION
      'This manager is in the manager draft auction and cannot be sold on the market';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_listing_block_settle_while_in_draft
  ON public."Manager_Transfer_Listings";
CREATE TRIGGER manager_listing_block_settle_while_in_draft
  BEFORE UPDATE ON public."Manager_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_manager_listing_block_settle_while_in_draft();

-- Market bids are rejected while a draft listing is open for the same manager.
CREATE OR REPLACE FUNCTION public.trg_manager_market_bid_block_while_in_draft()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_type text;
BEGIN
  SELECT l.listing_type INTO v_type
  FROM public."Manager_Transfer_Listings" l
  WHERE l.id = NEW.listing_id;

  IF v_type = 'draft' THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public."Manager_Transfer_Listings" d
    WHERE d.manager_id = NEW.manager_id
      AND d.listing_type = 'draft'
      AND d.status = 'Active'
  ) THEN
    RAISE EXCEPTION
      'This manager is in the manager draft auction. Bid on the draft, not the market.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_market_bid_block_while_in_draft
  ON public."Manager_Transfer_Bids";
CREATE TRIGGER manager_market_bid_block_while_in_draft
  BEFORE INSERT ON public."Manager_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_manager_market_bid_block_while_in_draft();

-- ---------------------------------------------------------------------------
-- 2. Hold those clocks before the FA board tries to settle them
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manager_window_fa_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_held int := 0;
  v_process jsonb;
  v_spawn jsonb;
  v_topup jsonb;
BEGIN
  v_held := public.manager_market_hold_while_in_draft();
  v_process := public.manager_process_window_fa_listings();
  v_spawn := public.manager_window_fa_spawn(NULL, NULL, false);
  v_topup := public.manager_window_fa_ensure_board(NULL, NULL, 10);

  RETURN jsonb_build_object(
    'ok', true,
    'held_for_draft', v_held,
    'process', v_process,
    'spawn', v_spawn,
    'ensure_board', v_topup
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Replacement free agents must not already be in the draft
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manager_window_fa_pick_ids(
  p_season_id bigint,
  p_limit int DEFAULT 10
)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(0, least(coalesce(p_limit, 10), 20));
  v_ids bigint[] := ARRAY[]::bigint[];
  v_id bigint;
  v_band text;
  v_need int;
  v_bands text[] := ARRAY['low', 'mid', 'upper', 'elite'];
  v_quotas_full int[] := ARRAY[2, 3, 3, 2];
  v_quotas int[] := ARRAY[0, 0, 0, 0];
  v_i int;
  v_sum int := 0;
  v_have int;
BEGIN
  IF v_limit <= 0 THEN
    RETURN v_ids;
  END IF;

  FOR v_i IN 1..4 LOOP
    v_quotas[v_i] := greatest(
      0,
      round((v_quotas_full[v_i]::numeric / 10.0) * v_limit)::int
    );
    v_sum := v_sum + v_quotas[v_i];
  END LOOP;
  IF v_sum > v_limit THEN
    v_quotas[2] := greatest(0, v_quotas[2] - (v_sum - v_limit));
  END IF;

  FOR v_i IN 1..4 LOOP
    v_band := v_bands[v_i];
    v_have := coalesce(array_length(v_ids, 1), 0);
    EXIT WHEN v_have >= v_limit;

    v_need := least(v_quotas[v_i], v_limit - v_have);
    IF v_need <= 0 THEN CONTINUE; END IF;

    FOR v_id IN
      SELECT m.id
      FROM public."Managers" m
      WHERE coalesce(m.archived, false) = false
        AND NOT public.gpdb_manager_is_season_excluded(m.id, p_season_id)
        AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
        AND NOT EXISTS (
          SELECT 1
          FROM public."Manager_Transfer_Listings" l
          WHERE l.manager_id = m.id
            AND l.status = 'Active'
            AND l.listing_type IN ('window_fa', 'standard', 'direct', 'draft')
        )
        AND NOT (m.id = ANY (v_ids))
        AND (
          (v_band = 'low' AND coalesce(m.rating, 0) <= 65)
          OR (v_band = 'mid' AND coalesce(m.rating, 0) BETWEEN 66 AND 72)
          OR (v_band = 'upper' AND coalesce(m.rating, 0) BETWEEN 73 AND 78)
          OR (v_band = 'elite' AND coalesce(m.rating, 0) >= 79)
        )
      ORDER BY random()
      LIMIT v_need
    LOOP
      v_ids := array_append(v_ids, v_id);
      EXIT WHEN coalesce(array_length(v_ids, 1), 0) >= v_limit;
    END LOOP;
  END LOOP;

  WHILE coalesce(array_length(v_ids, 1), 0) < v_limit LOOP
    SELECT m.id INTO v_id
    FROM public."Managers" m
    WHERE coalesce(m.archived, false) = false
      AND NOT public.gpdb_manager_is_season_excluded(m.id, p_season_id)
      AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
      AND NOT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Listings" l
        WHERE l.manager_id = m.id
          AND l.status = 'Active'
          AND l.listing_type IN ('window_fa', 'standard', 'direct', 'draft')
      )
      AND NOT (m.id = ANY (v_ids))
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_id IS NULL;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  RETURN v_ids;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Draft sale removes the market row and refills the board of 10
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_managers_signed_cancel_fa_listings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(NEW.contracted_club, '')), '');
  v_cancelled int := 0;
BEGIN
  IF v_club IS NULL
     OR v_club IS NOT DISTINCT FROM nullif(btrim(coalesce(OLD.contracted_club, '')), '') THEN
    RETURN NULL;
  END IF;

  BEGIN
    UPDATE public."Manager_Transfer_Listings" l
    SET status = 'Cancelled',
        updated_at = now(),
        metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
          'cancelled_reason', 'manager_signed_elsewhere',
          'cancelled_at', now(),
          'signed_club', v_club
        )
    WHERE l.manager_id = NEW.id
      AND l.listing_type = 'window_fa'
      AND l.status = 'Active';

    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'FA listing cleanup on sign failed: %', SQLERRM;
    v_cancelled := 0;
  END;

  IF v_cancelled > 0 THEN
    BEGIN
      PERFORM public.manager_window_fa_ensure_board(NULL, NULL, 10);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'FA board top-up after sign failed: %', SQLERRM;
    END;
  END IF;

  RETURN NULL;
END;
$function$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'held_now', public.manager_market_hold_while_in_draft(),
  'on_market_and_in_draft', (
    SELECT count(*)
    FROM public."Manager_Transfer_Listings" mkt
    WHERE mkt.listing_type IS DISTINCT FROM 'draft'
      AND mkt.status = 'Active'
      AND EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Listings" d
        WHERE d.manager_id = mkt.manager_id
          AND d.listing_type = 'draft'
          AND d.status = 'Active'
      )
  )
) AS result;
