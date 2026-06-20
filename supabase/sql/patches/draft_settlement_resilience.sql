-- =============================================================================
-- Draft settlement resilience — fix systemic causes of stuck winning bids
--
-- Problems addressed:
--   1. Player draft skipped when draft_auction_enabled=false but listings remain
--   2. One failed listing aborts entire settlement batch (EXCEPTION in loop)
--   3. Ledger posts require status='active' only — fails in preseason
--   4. Report includes pending count + gate reason
--
-- After deploy: SELECT transferengine_run_report();
-- =============================================================================

-- Ledger: allow preseason (draft often settles before league status flips to active)
CREATE OR REPLACE FUNCTION public.post_club_ledger(
  p_club_short_name text,
  p_entry_type text,
  p_amount numeric,
  p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_season_id bigint DEFAULT NULL,
  p_fixture_id bigint DEFAULT NULL,
  p_bank_leg boolean DEFAULT false,
  p_apply_balance boolean DEFAULT true
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_season_id bigint;
  v_balance numeric;
  v_ledger_id bigint;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF p_amount IS NULL OR p_amount = 0 THEN
    RETURN NULL;
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY
      CASE status
        WHEN 'active' THEN 0
        WHEN 'preseason' THEN 1
        WHEN 'summer_break' THEN 2
        WHEN 'setup' THEN 3
        ELSE 4
      END,
      id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season for ledger post';
  END IF;

  IF p_apply_balance THEN
    SELECT balance INTO v_balance
    FROM public."Club_Finances"
    WHERE club_name = v_club
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Club_Finances row missing for %', v_club;
    END IF;

    UPDATE public."Club_Finances"
    SET balance = v_balance + p_amount
    WHERE club_name = v_club;
  END IF;

  INSERT INTO public.competition_finance_ledger (
    season_id,
    fixture_id,
    club_short_name,
    entry_type,
    amount,
    description,
    metadata
  )
  VALUES (
    v_season_id,
    p_fixture_id,
    v_club,
    p_entry_type,
    p_amount,
    coalesce(nullif(btrim(p_description), ''), p_entry_type),
    coalesce(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_ledger_id;

  RETURN v_ledger_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_settle_player_draft_listings(
  p_batch_limit int DEFAULT 100
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_settled int := 0;
  v_limit int := greatest(coalesce(p_batch_limit, 100), 1);
BEGIN
  FOR v_listing IN
    SELECT *
    FROM public."Player_Transfer_Listings"
    WHERE listing_type = 'draft'
      AND status = 'Active'
    ORDER BY id
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
      IF EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.id = v_listing.id
          AND l.status = 'Closed'
          AND l.transfer_completed = true
      ) THEN
        v_settled := v_settled + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'transferengine_accept_draft_sale listing % failed: %',
        v_listing.id, SQLERRM;
    END;
  END LOOP;

  RETURN v_settled;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_now timestamptz := now();
  v_mgr_active int;
  v_club_active int;
  v_player_draft_active int;
  v_should_settle_players boolean;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_mgr_active
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  SELECT count(*)::int INTO v_club_active
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  SELECT count(*)::int INTO v_player_draft_active
  FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  IF v_settings.draft_random_finish_time IS NULL
     OR v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  IF NOT COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.manager_draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.club_auction_enabled, false)
     AND v_player_draft_active = 0
     AND v_mgr_active = 0
     AND v_club_active = 0 THEN
    RETURN;
  END IF;

  PERFORM public.transferengine_process_standard_listings(v_now);

  v_should_settle_players :=
    v_player_draft_active > 0
    AND (
      COALESCE(v_settings.draft_auction_enabled, false)
      OR v_now >= v_settings.draft_random_finish_time
    )
    AND NOT public.transferengine_standard_listings_block_draft_settlement(
      v_now,
      v_settings.draft_random_finish_time
    );

  IF v_should_settle_players THEN
    PERFORM public.transferengine_settle_player_draft_listings(100);
  END IF;

  PERFORM public.transferengine_settle_manager_draft_auctions_only();

  IF to_regprocedure('public.transferengine_settle_club_auctions_only()') IS NOT NULL THEN
    PERFORM public.transferengine_settle_club_auctions_only();
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_draft_settlement_gate()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_pending int;
  v_blocked boolean;
BEGIN
  SELECT
    draft_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_pending
  FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  v_blocked := public.transferengine_standard_listings_block_draft_settlement(
    now(),
    v_settings.draft_random_finish_time
  );

  RETURN jsonb_build_object(
    'pending_active_draft_listings', v_pending,
    'draft_auction_enabled', COALESCE(v_settings.draft_auction_enabled, false),
    'secret_finish_passed',
      v_settings.draft_random_finish_time IS NOT NULL
      AND now() >= v_settings.draft_random_finish_time,
    'blocked_by_7pm_transfer_list', v_blocked,
    'will_settle_players',
      v_pending > 0
      AND v_settings.draft_random_finish_time IS NOT NULL
      AND now() >= v_settings.draft_random_finish_time
      AND NOT v_blocked
      AND (
        COALESCE(v_settings.draft_auction_enabled, false)
        OR v_pending > 0
      )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_settle_player_draft_listings() TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_draft_settlement_gate() TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_draft_settlement_gate() TO service_role;

NOTIFY pgrst, 'reload schema';
