-- =============================================================================
-- Repair Transfer_History rows removed by old admin_reset_draft_auction (purge)
-- Squads/balances were NOT rolled back — only history (and listings) were deleted.
--
-- Rebuilds draft signings from competition_finance_ledger transfer_purchase lines
-- where the player is still at that club and no history row exists.
-- Run once as admin: SELECT repair_draft_transfer_history_from_ledger();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.repair_draft_transfer_history_from_ledger()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_count int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_row IN
    SELECT DISTINCT ON (
      btrim(l.metadata->>'player_id'),
      l.club_short_name
    )
      l.club_short_name AS buyer_club,
      l.metadata->>'player_id' AS player_id,
      abs(l.amount) AS fee,
      l.created_at AS transfer_time
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'transfer_purchase'
      AND l.metadata->>'player_id' IS NOT NULL
      AND btrim(l.metadata->>'player_id') <> ''
      AND l.club_short_name IS NOT NULL
    ORDER BY
      btrim(l.metadata->>'player_id'),
      l.club_short_name,
      l.created_at DESC
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM public."Players" p
      WHERE p."Konami_ID"::text = btrim(v_row.player_id)
        AND p."Contracted_Team" = v_row.buyer_club
    ) THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public."Transfer_History" h
      WHERE h.player_id::text = btrim(v_row.player_id)
        AND h.buyer_club_id = v_row.buyer_club
    ) THEN
      CONTINUE;
    END IF;

    INSERT INTO public."Transfer_History" (
      player_id,
      seller_club_id,
      buyer_club_id,
      fee,
      agent_fee,
      transfer_time,
      listing_id
    )
    VALUES (
      btrim(v_row.player_id),
      NULL,
      v_row.buyer_club,
      v_row.fee,
      0,
      v_row.transfer_time,
      NULL
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.repair_draft_transfer_history_from_ledger() TO authenticated;

NOTIFY pgrst, 'reload schema';
