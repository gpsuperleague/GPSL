-- Hotfix: duplicate transferengine_settle_player_draft_listings() overloads
-- (resilience no-arg + accept_fix with p_batch_limit). Run once in SQL Editor.

DROP FUNCTION IF EXISTS public.transferengine_settle_player_draft_listings();
DROP FUNCTION IF EXISTS public.transferengine_settle_player_draft_listings(int);

-- Re-create accept_fix version if already deployed; minimal stub if not:
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

NOTIFY pgrst, 'reload schema';
