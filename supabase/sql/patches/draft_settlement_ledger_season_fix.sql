-- =============================================================================
-- Draft settlement — ledger season + probe errors swallowed by settle loop
--
-- Symptom: transferengine_run_report() ok but draft_settled_count stays 0.
-- Cause: post_club_ledger() only finds status='active' (or active+preseason);
--        draft often settles in preseason / summer_break / between_months.
--        accept_draft_sale throws → caught per listing → no visible progress.
--
-- Run AFTER draft_settlement_accept_fix.sql (or overload_fix.sql at minimum).
-- Then:
--   SELECT public.transferengine_probe_draft_settlement(3);
--   SELECT public.transferengine_run_report();
-- =============================================================================

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

  IF p_bank_leg THEN
    UPDATE public.gpsl_bank_account
    SET reserves = reserves - p_amount,
        updated_at = now()
    WHERE id = 1;

    INSERT INTO public.bank_ledger (
      entry_type,
      amount,
      description,
      club_short_name,
      club_ledger_id,
      metadata
    )
    VALUES (
      p_entry_type,
      -p_amount,
      coalesce(nullif(btrim(p_description), ''), p_entry_type),
      v_club,
      v_ledger_id,
      coalesce(p_metadata, '{}'::jsonb)
    );
  END IF;

  RETURN v_ledger_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_probe_draft_settlement(p_limit int DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing record;
  v_limit int := greatest(coalesce(p_limit, 3), 1);
  v_results jsonb := '[]'::jsonb;
  v_closed boolean;
  v_season record;
BEGIN
  SELECT s.id, s.label, s.status, s.is_current
  INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  FOR v_listing IN
    SELECT l.id, l.player_id, l.current_highest_bidder, l.current_highest_bid
    FROM public."Player_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.current_highest_bidder IS NOT NULL
    ORDER BY l.id
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);

      SELECT EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.id = v_listing.id
          AND l.status = 'Closed'
          AND l.transfer_completed = true
      ) INTO v_closed;

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'listing_id', v_listing.id,
        'player_id', v_listing.player_id,
        'buyer', v_listing.current_highest_bidder,
        'fee', v_listing.current_highest_bid,
        'ok', v_closed,
        'status_after', (
          SELECT l.status FROM public."Player_Transfer_Listings" l WHERE l.id = v_listing.id
        ),
        'transfer_completed_after', (
          SELECT l.transfer_completed FROM public."Player_Transfer_Listings" l WHERE l.id = v_listing.id
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'listing_id', v_listing.id,
        'player_id', v_listing.player_id,
        'buyer', v_listing.current_highest_bidder,
        'fee', v_listing.current_highest_bid,
        'ok', false,
        'error', SQLERRM,
        'sqlstate', SQLSTATE
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'current_season', jsonb_build_object(
      'id', v_season.id,
      'label', v_season.label,
      'status', v_season.status,
      'is_current', v_season.is_current
    ),
    'probed', jsonb_array_length(v_results),
    'results', v_results
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_diagnose_draft_backlog()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
  v_season record;
BEGIN
  SELECT draft_random_finish_time INTO v_finish
  FROM public.global_settings WHERE id = 1;

  SELECT s.id, s.status
  INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'active_draft_listings', (
      SELECT count(*)::int FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    ),
    'with_listing_leader', (
      SELECT count(*)::int FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
    ),
    'no_direct_bid_row', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Bids" b
          WHERE b.is_direct = true
            AND (
              b.listing_id = l.id
              OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(l.player_id::text)
            )
        )
    ),
    'player_already_signed_elsewhere', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND p."Contracted_Team" IS NOT NULL AND btrim(p."Contracted_Team"::text) <> ''
        AND btrim(p."Contracted_Team"::text) IS DISTINCT FROM btrim(l.current_highest_bidder::text)
    ),
    'buyer_missing_club_finances', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = btrim(l.current_highest_bidder::text)
        )
    ),
    'ready_to_settle', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team"::text) = '')
        AND EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = btrim(l.current_highest_bidder::text)
        )
    ),
    'current_season_id', v_season.id,
    'current_season_status', v_season.status,
    'draft_random_finish_time', v_finish
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_probe_draft_settlement(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_probe_draft_settlement(int) TO service_role;

NOTIFY pgrst, 'reload schema';
