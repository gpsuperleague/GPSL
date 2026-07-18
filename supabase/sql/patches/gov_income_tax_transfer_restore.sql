-- Restore income tax on transfer purchases.
--
-- Bug: competition_challenge_prize_packs_part2.sql replaced
-- post_transfer_ledger_for_history and dropped the gov_income_tax hook from
-- gov_income_tax.sql. Buying clubs no longer paid income tax on fee + agent fee.
--
-- Run after gov_income_tax.sql and competition_challenge_prize_packs_part2.sql.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.post_transfer_ledger_for_history(
  p_transfer_history_id bigint,
  p_apply_balance boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_h record;
  v_player_name text;
  v_desc_buy text;
  v_desc_sell text;
  v_meta jsonb;
  v_draft_from_gpdb boolean;
  v_fee numeric;
  v_disc jsonb;
  v_club_pays numeric;
  v_gap numeric;
  v_ctx_kind text;
  v_pct text;
  v_spend numeric;
BEGIN
  SELECT *
  INTO v_h
  FROM public."Transfer_History" h
  WHERE h.id = p_transfer_history_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_fee := abs(coalesce(v_h.fee, 0));
  v_meta := jsonb_build_object(
    'transfer_history_id', v_h.id,
    'listing_id', v_h.listing_id,
    'player_id', v_h.player_id
  );

  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = v_h.id::text
      AND l.entry_type IN ('transfer_sale', 'transfer_purchase')
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

  SELECT p."Name" INTO v_player_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_h.player_id::text
  LIMIT 1;

  v_player_name := coalesce(v_player_name, 'Player ' || v_h.player_id::text);
  v_draft_from_gpdb := v_h.seller_club_id IS NULL OR btrim(v_h.seller_club_id::text) = '';

  v_club_pays := v_fee;
  v_gap := 0;
  v_disc := '{}'::jsonb;

  IF v_h.buyer_club_id IS NOT NULL
     AND btrim(v_h.buyer_club_id::text) <> ''
     AND v_h.buyer_club_id <> 'FOREIGN'
     AND v_h.listing_id IS NOT NULL
     AND v_fee > 0
     AND to_regprocedure(
       'public.prize_apply_fee_discount_settlement(text, text, bigint, numeric)'
     ) IS NOT NULL THEN
    v_ctx_kind := CASE WHEN v_draft_from_gpdb THEN 'draft_listing' ELSE 'listing' END;
    v_disc := public.prize_apply_fee_discount_settlement(
      v_h.buyer_club_id, v_ctx_kind, v_h.listing_id, v_fee
    );
    IF coalesce((v_disc->>'applied')::boolean, false) THEN
      v_club_pays := coalesce((v_disc->>'club_pays')::numeric, v_fee);
      v_gap := coalesce((v_disc->>'bank_gap')::numeric, 0);
      v_pct := v_disc->>'discount_pct';
      v_meta := v_meta || jsonb_build_object(
        'fee_discount_pct', v_disc->'discount_pct',
        'fee_discount_inventory_id', v_disc->'inventory_id',
        'club_pays', v_club_pays,
        'bank_gap', v_gap
      );
    END IF;
  END IF;

  IF v_h.buyer_club_id IS NOT NULL
     AND btrim(v_h.buyer_club_id::text) <> ''
     AND v_h.buyer_club_id <> 'FOREIGN' THEN
    v_desc_buy := 'Purchase: ' || v_player_name;
    IF v_gap > 0 THEN
      v_desc_buy := v_desc_buy || format(' (%s%% prize discount)', v_pct);
    END IF;
    PERFORM public.post_club_ledger(
      v_h.buyer_club_id,
      'transfer_purchase',
      -abs(v_club_pays),
      v_desc_buy,
      v_meta,
      NULL,
      NULL,
      v_draft_from_gpdb,
      p_apply_balance
    );
  END IF;

  IF v_h.seller_club_id IS NOT NULL AND btrim(v_h.seller_club_id::text) <> '' THEN
    v_desc_sell := 'Sale: ' || v_player_name;
    IF coalesce(v_h.transfer_sale_note, '') = 'squad_overflow' THEN
      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        CASE
          WHEN v_h.buyer_club_id = 'FOREIGN' THEN 'transfer_foreign_sale'
          ELSE 'transfer_overflow_release'
        END,
        abs(v_fee),
        coalesce(nullif(btrim(v_h.foreign_buyer_name), ''), v_desc_sell),
        v_meta || jsonb_build_object('transfer_sale_note', v_h.transfer_sale_note),
        NULL,
        NULL,
        false,
        p_apply_balance
      );
    ELSE
      IF (abs(v_fee) - abs(v_gap)) > 0 THEN
        PERFORM public.post_club_ledger(
          v_h.seller_club_id,
          'transfer_sale',
          abs(v_fee) - abs(v_gap),
          v_desc_sell,
          v_meta,
          NULL,
          NULL,
          false,
          p_apply_balance
        );
      END IF;
      IF v_gap > 0 THEN
        PERFORM public.post_club_ledger(
          v_h.seller_club_id,
          'prize_fee_discount_subsidy',
          abs(v_gap),
          format('Fee discount top-up (buyer prize token) — %s', v_player_name),
          v_meta,
          NULL,
          NULL,
          true,
          p_apply_balance
        );
      END IF;
    END IF;
  END IF;

  IF coalesce(v_h.agent_fee, 0) > 0 AND v_h.buyer_club_id IS NOT NULL THEN
    PERFORM public.post_club_ledger(
      v_h.buyer_club_id,
      'transfer_agent_fee',
      -abs(v_h.agent_fee),
      'Agent fee: ' || v_player_name,
      v_meta,
      NULL,
      NULL,
      false,
      p_apply_balance
    );
  END IF;

  -- Income tax on what the buyer actually spends (fee after prize discount + agent fee)
  IF v_h.buyer_club_id IS NOT NULL
     AND btrim(v_h.buyer_club_id::text) <> ''
     AND v_h.buyer_club_id <> 'FOREIGN'
     AND to_regprocedure(
       'public.post_gov_income_tax_on_player_spend(text, numeric, text, jsonb, boolean)'
     ) IS NOT NULL THEN
    v_spend := abs(coalesce(v_club_pays, 0)) + abs(coalesce(v_h.agent_fee, 0));
    IF v_spend > 0 THEN
      PERFORM public.post_gov_income_tax_on_player_spend(
        v_h.buyer_club_id,
        v_spend,
        'Income tax — ' || v_player_name,
        v_meta || jsonb_build_object('income_tax_source', 'transfer'),
        p_apply_balance
      );
    END IF;
  END IF;

  IF v_h.listing_id IS NOT NULL
     AND to_regprocedure(
       'public.prize_release_locked_discounts_for_context(text, bigint, text)'
     ) IS NOT NULL THEN
    PERFORM public.prize_release_locked_discounts_for_context(
      CASE WHEN v_draft_from_gpdb THEN 'draft_listing' ELSE 'listing' END,
      v_h.listing_id,
      v_h.buyer_club_id
    );
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.post_transfer_ledger_for_history(bigint, boolean)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
