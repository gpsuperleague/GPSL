-- =============================================================================
-- Season opening balance — expose starting_budget for finances UI
-- Run after club_assignment_ledger_display.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_assignment_finance_display(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_row record;
  v_stadium_cost numeric;
  v_total_debit numeric;
  v_season_id bigint;
  v_ledger_posted boolean := false;
  v_display_name text;
  v_starting_budget numeric;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'club_required');
  END IF;

  SELECT
    c."Club" AS club_name,
    coalesce(nullif(btrim(c."Stadium"), ''), c."Club", c."ShortName") AS stadium_name,
    c.owner_id,
    l.winning_bid,
    l.updated_at AS settled_at
  INTO v_row
  FROM public."Clubs" c
  LEFT JOIN public."Club_Auction_Listings" l
    ON l.club_short_name = c."ShortName"
   AND l.transfer_completed = true
   AND l.winning_owner_id = c.owner_id
  WHERE c."ShortName" = v_club;

  IF NOT FOUND OR v_row.owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'show_in_accounts', false);
  END IF;

  v_stadium_cost := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_total_debit := greatest(coalesce(nullif(v_row.winning_bid, 0), v_stadium_cost), v_stadium_cost);
  v_display_name := v_row.stadium_name;
  v_season_id := public.competition_finances_current_season_id();

  IF v_season_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
        AND l.season_id = v_season_id
        AND l.entry_type = 'infra_purchase'
    ) INTO v_ledger_posted;
  END IF;

  SELECT coalesce(
    nullif((l.metadata->>'starting_budget')::numeric, 0),
    public.club_auction_default_starting_balance()
  )
  INTO v_starting_budget
  FROM public.competition_finance_ledger l
  WHERE l.club_short_name = v_club
    AND l.entry_type = 'infra_purchase'
    AND (v_season_id IS NULL OR l.season_id = v_season_id)
  ORDER BY l.created_at ASC
  LIMIT 1;

  IF coalesce(v_starting_budget, 0) <= 0 THEN
    v_starting_budget := public.club_auction_default_starting_balance();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'show_in_accounts', v_total_debit > 0,
    'club_short_name', v_club,
    'club_name', v_row.club_name,
    'stadium_name', v_display_name,
    'stadium_cost', v_stadium_cost,
    'total_debit', v_total_debit,
    'starting_budget', v_starting_budget,
    'ledger_posted', v_ledger_posted,
    'season_id', v_season_id,
    'settled_at', v_row.settled_at,
    'ledger_description', format('Stadium purchase — %s', v_display_name)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_assignment_finance_display(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
