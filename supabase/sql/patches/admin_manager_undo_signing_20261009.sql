-- =============================================================================
-- Admin: undo a manager signing with a full refund (2026-10-09)
-- =============================================================================
--   SELECT public.admin_manager_undo_signing('Kohlmann');         -- preview only
--   SELECT public.admin_manager_undo_signing('Kohlmann', true);   -- apply
-- (name match is partial / accent-sensitive; a numeric argument = manager id)
--
-- Reverses it "as if he was never signed":
--   • refunds the signing fee to the buying club (same ledger type, + amount)
--     – free-agent fee: Central Bank leg reversed too (if the original had one)
--     – club-to-club sale: the seller's sale income is taken back
--   • manager back to free agent (no contract, no wage, no deal seasons)
--   • club's manager slot cleared
--   • his career stint at that club deleted (no sack / no re-hire block)
--   • the listing he was bought from marked not completed (stays closed)
--   • inbox note to the club
-- Weekly wages already paid while he was at the club are NOT refunded
-- (preview shows how many wage lines exist).
-- Safe re-run (a second apply finds no contracted manager).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_manager_undo_signing(
  p_manager text,
  p_apply boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := btrim(coalesce(p_manager, ''));
  v_matches int;
  v_mgr public."Managers"%rowtype;
  v_club text;
  v_buy public.competition_finance_ledger%rowtype;
  v_sell public.competition_finance_ledger%rowtype;
  v_fee numeric := 0;
  v_seller text;
  v_bank_leg boolean := false;
  v_stint public.manager_club_stints%rowtype;
  v_listing_id bigint;
  v_wage_lines int := 0;
  v_plan jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_q = '' THEN
    RAISE EXCEPTION 'Manager name or id required';
  END IF;

  IF v_q ~ '^\d+$' THEN
    SELECT * INTO v_mgr FROM public."Managers" WHERE id = v_q::bigint;
    v_matches := CASE WHEN FOUND THEN 1 ELSE 0 END;
  ELSE
    SELECT count(*) INTO v_matches
    FROM public."Managers" m
    WHERE m.name ILIKE '%' || v_q || '%'
      AND nullif(btrim(coalesce(m.contracted_club, '')), '') IS NOT NULL;
    IF v_matches = 1 THEN
      SELECT * INTO v_mgr
      FROM public."Managers" m
      WHERE m.name ILIKE '%' || v_q || '%'
        AND nullif(btrim(coalesce(m.contracted_club, '')), '') IS NOT NULL;
    END IF;
  END IF;

  IF v_matches = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'No contracted manager matches that name/id');
  ELSIF v_matches > 1 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'More than one contracted manager matches — be more specific or pass the id',
      'matches', (
        SELECT jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'club', m.contracted_club))
        FROM public."Managers" m
        WHERE m.name ILIKE '%' || v_q || '%'
          AND nullif(btrim(coalesce(m.contracted_club, '')), '') IS NOT NULL
      )
    );
  END IF;

  v_club := nullif(btrim(coalesce(v_mgr.contracted_club, '')), '');
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'Manager is already a free agent', 'manager', v_mgr.name);
  END IF;

  SELECT * INTO v_stint
  FROM public.manager_club_stints s
  WHERE s.manager_id = v_mgr.id
    AND upper(s.club_short_name) = upper(v_club)
    AND s.ended_at IS NULL
  ORDER BY s.started_at DESC
  LIMIT 1;

  -- The signing fee line (latest unreversed debit for this manager at this club)
  SELECT l.* INTO v_buy
  FROM public.competition_finance_ledger l
  WHERE l.club_short_name = v_club
    AND l.entry_type = 'contract_signing_offer'
    AND l.amount < 0
    AND l.metadata->>'manager_id' = v_mgr.id::text
    AND NOT EXISTS (
      SELECT 1 FROM public.competition_finance_ledger r
      WHERE r.metadata->>'reverses_ledger_id' = l.id::text
    )
  ORDER BY l.id DESC
  LIMIT 1;

  IF v_buy.id IS NOT NULL THEN
    v_fee := abs(v_buy.amount);
    v_seller := nullif(btrim(coalesce(v_buy.metadata->>'seller', '')), '');
    v_bank_leg := EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_buy.id);
  END IF;

  IF v_seller IS NOT NULL THEN
    SELECT l.* INTO v_sell
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_seller
      AND l.entry_type = 'transfer_sale'
      AND l.amount > 0
      AND l.metadata->>'manager_id' = v_mgr.id::text
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_finance_ledger r
        WHERE r.metadata->>'reverses_ledger_id' = l.id::text
      )
    ORDER BY l.id DESC
    LIMIT 1;
  END IF;

  SELECT l.id INTO v_listing_id
  FROM public."Manager_Transfer_Listings" l
  WHERE l.manager_id = v_mgr.id
    AND l.transfer_completed = true
  ORDER BY l.updated_at DESC
  LIMIT 1;

  SELECT count(*) INTO v_wage_lines
  FROM public.competition_finance_ledger l
  WHERE l.club_short_name = v_club
    AND l.metadata->>'manager_id' = v_mgr.id::text
    AND l.id IS DISTINCT FROM v_buy.id
    AND l.entry_type <> 'contract_signing_offer';

  v_plan := jsonb_build_object(
    'manager', v_mgr.name,
    'manager_id', v_mgr.id,
    'club', v_club,
    'signed_at', v_stint.started_at,
    'signed_how', v_stint.start_kind,
    'refund_to_club', v_fee,
    'refund_from', CASE
      WHEN v_buy.id IS NULL THEN 'no signing fee found — nothing to refund'
      WHEN v_seller IS NOT NULL THEN format('seller %s (sale income reversed)', v_seller)
      WHEN v_bank_leg THEN 'GPSL Central Bank'
      ELSE 'league (no bank leg on original)'
    END,
    'signing_ledger_id', v_buy.id,
    'seller_ledger_id', v_sell.id,
    'listing_id', v_listing_id,
    'other_ledger_lines_not_refunded', v_wage_lines
  );

  IF NOT coalesce(p_apply, false) THEN
    RETURN jsonb_build_object('ok', true, 'preview', true, 'plan', v_plan,
      'next', 'Re-run with p_apply => true to reverse');
  END IF;

  -- 1. Money
  IF v_buy.id IS NOT NULL AND v_fee > 0 THEN
    PERFORM public.post_club_ledger(
      v_club,
      'contract_signing_offer',
      v_fee,
      format('Manager signing reversed — %s (admin refund)', v_mgr.name),
      jsonb_build_object(
        'manager_id', v_mgr.id, 'kind', 'manager',
        'reverses_ledger_id', v_buy.id, 'admin_undo_signing', true
      ),
      NULL, NULL,
      v_bank_leg,
      true
    );
  END IF;

  IF v_sell.id IS NOT NULL THEN
    PERFORM public.post_club_ledger(
      v_seller,
      'transfer_sale',
      -abs(v_sell.amount),
      format('Manager sale reversed — %s (admin)', v_mgr.name),
      jsonb_build_object(
        'manager_id', v_mgr.id, 'kind', 'manager',
        'reverses_ledger_id', v_sell.id, 'admin_undo_signing', true
      ),
      NULL, NULL,
      false,
      true
    );
  END IF;

  -- 2. Manager back to free agent
  UPDATE public."Managers"
  SET contracted_club = NULL,
      contract_seasons_remaining = 0,
      weekly_wage = 0,
      signed_season_id = NULL,
      deal_start_season_id = NULL,
      pending_owner_renewal = false,
      updated_at = now()
  WHERE id = v_mgr.id;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = v_club
    AND (manager_id IS NULL OR manager_id = v_mgr.id);

  IF to_regprocedure('public.manager_sync_club_rating(text)') IS NOT NULL THEN
    BEGIN
      PERFORM public.manager_sync_club_rating(v_club);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  -- 3. History: as if never signed
  IF v_stint.id IS NOT NULL THEN
    DELETE FROM public.manager_club_stints WHERE id = v_stint.id;
  END IF;
  DELETE FROM public.manager_deal_season_results
  WHERE manager_id = v_mgr.id
    AND club_short_name = v_club
    AND deal_start_season_id = coalesce(v_mgr.deal_start_season_id, v_mgr.signed_season_id);

  IF v_listing_id IS NOT NULL THEN
    UPDATE public."Manager_Transfer_Listings"
    SET transfer_completed = false,
        updated_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'admin_undo_signing', true,
          'undone_at', now(),
          'refunded', v_fee
        )
    WHERE id = v_listing_id;
  END IF;

  -- 4. Tell the club
  BEGIN
    PERFORM public.owner_inbox_send(
      p_message_type => 'season_overview',
      p_title => format('Manager signing reversed — %s', v_mgr.name),
      p_body => format(
        'An admin has reversed the signing of %s. He is a free agent again and %s has been refunded to your club bank. You can now hire another manager.',
        v_mgr.name,
        CASE WHEN v_fee > 0 THEN '₿' || to_char(v_fee, 'FM999,999,999') ELSE 'nothing (no fee was found)' END
      ),
      p_recipient_club => v_club,
      p_action_href => 'manager_listings.html',
      p_dedupe_key => format('mgr_undo_signing:%s:%s:%s', v_mgr.id, v_club, coalesce(v_buy.id::text, 'nofee'))
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'undo signing inbox failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object('ok', true, 'applied', true, 'plan', v_plan,
    'club_balance_now', (SELECT balance FROM public."Club_Finances" WHERE club_name = v_club));
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_manager_undo_signing(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_manager_undo_signing(text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT to_regprocedure('public.admin_manager_undo_signing(text,boolean)') IS NOT NULL AS installed;
