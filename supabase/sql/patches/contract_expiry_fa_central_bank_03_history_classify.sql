-- =============================================================================
-- PART 3/4 — transfer history ledger / classify / discord
-- Run after: contract_expiry_fa_central_bank_02_assign_and_release.sql
-- =============================================================================

SET statement_timeout = '120s';

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
  v_bank_leg boolean;
  v_note text;
BEGIN
  SELECT *
  INTO v_h
  FROM public."Transfer_History" h
  WHERE h.id = p_transfer_history_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_note := coalesce(btrim(v_h.transfer_sale_note), '');

  SELECT coalesce(p."Name", v_h.player_id::text)
  INTO v_player_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_h.player_id::text
  LIMIT 1;

  v_player_name := coalesce(v_player_name, v_h.player_id::text);

  v_meta := jsonb_build_object(
    'transfer_history_id', v_h.id,
    'listing_id', v_h.listing_id,
    'player_id', v_h.player_id
  );

  IF v_note = 'contract_expiry' THEN
    IF EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.entry_type = 'contract_expiry_compensation'
        AND (
          l.metadata->>'transfer_history_id' = v_h.id::text
          OR (
            coalesce(l.metadata->>'source', '') = 'contract_expiry_fa'
            AND l.metadata->>'player_id' = v_h.player_id::text
            AND l.club_short_name = v_h.seller_club_id
          )
        )
      LIMIT 1
    ) THEN
      RETURN;
    END IF;

    IF coalesce(v_h.fee, 0) > 0 AND v_h.seller_club_id IS NOT NULL THEN
      v_bank_leg := true;
      IF to_regprocedure('public.finance_entry_via_central_bank(text)') IS NOT NULL THEN
        v_bank_leg := coalesce(
          public.finance_entry_via_central_bank('contract_expiry_compensation'),
          true
        );
      END IF;

      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        'contract_expiry_compensation',
        abs(v_h.fee),
        'Contract ended (free agent): ' || v_player_name,
        v_meta || jsonb_build_object(
          'source', 'contract_expiry_fa',
          'compensation_from', 'central_bank',
          'transfer_sale_note', v_note
        ),
        NULL,
        NULL,
        v_bank_leg,
        p_apply_balance
      );
    END IF;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = v_h.id::text
      AND l.entry_type IN (
        'transfer_sale', 'transfer_purchase', 'transfer_foreign_sale',
        'transfer_overflow_release', 'contract_expiry_compensation'
      )
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

  v_draft_from_gpdb := v_h.seller_club_id IS NULL OR btrim(v_h.seller_club_id::text) = '';

  IF v_h.buyer_club_id IS NOT NULL
     AND btrim(v_h.buyer_club_id::text) <> ''
     AND v_h.buyer_club_id <> 'FOREIGN' THEN
    v_desc_buy := 'Purchase: ' || v_player_name;
    PERFORM public.post_club_ledger(
      v_h.buyer_club_id,
      'transfer_purchase',
      -abs(v_h.fee),
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
    IF v_note = 'squad_overflow' THEN
      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        CASE
          WHEN v_h.buyer_club_id = 'FOREIGN' THEN 'transfer_foreign_sale'
          ELSE 'transfer_overflow_release'
        END,
        abs(v_h.fee),
        coalesce(nullif(btrim(v_h.foreign_buyer_name), ''), v_desc_sell),
        v_meta || jsonb_build_object('transfer_sale_note', v_h.transfer_sale_note),
        NULL,
        NULL,
        false,
        p_apply_balance
      );
    ELSE
      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        'transfer_sale',
        abs(v_h.fee),
        v_desc_sell,
        v_meta,
        NULL,
        NULL,
        false,
        p_apply_balance
      );
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
END;
$function$;

CREATE OR REPLACE FUNCTION public.transfer_classify_method(
  p_seller_club text,
  p_buyer_club text,
  p_listing_id bigint,
  p_sale_note text,
  p_foreign_buyer_name text,
  p_method_override text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing_type text;
  v_note text := coalesce(btrim(p_sale_note), '');
  v_buyer text := btrim(coalesce(p_buyer_club, ''));
  v_seller text := btrim(coalesce(p_seller_club, ''));
BEGIN
  IF p_method_override IS NOT NULL AND btrim(p_method_override) <> '' THEN
    RETURN btrim(p_method_override);
  END IF;

  IF v_note = 'special_auction' OR v_note LIKE 'special_auction:%' THEN
    RETURN 'Special auction';
  END IF;

  IF v_note = 'contract_expiry' THEN
    RETURN 'Contract Run Down - Central Bank Compensation';
  END IF;

  IF p_listing_id IS NOT NULL THEN
    SELECT l.listing_type INTO v_listing_type
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = p_listing_id;
  END IF;

  IF v_listing_type = 'draft' THEN
    RETURN 'Draft auction';
  END IF;

  IF v_note = 'squad_overflow' THEN
    IF v_buyer = 'FOREIGN' AND coalesce(btrim(p_foreign_buyer_name), '') <> '' THEN
      RETURN 'Foreign sale (squad over 28)';
    END IF;
    RETURN 'Squad release (market value, over 28)';
  END IF;

  IF v_buyer = 'FOREIGN' THEN
    IF coalesce(btrim(p_foreign_buyer_name), '') <> '' THEN
      RETURN 'Foreign sale — ' || btrim(p_foreign_buyer_name);
    END IF;
    RETURN 'Foreign sale';
  END IF;

  IF v_listing_type = 'direct' THEN
    RETURN 'Direct offer (transfer market)';
  END IF;

  IF v_seller <> '' AND v_buyer <> '' THEN
    RETURN 'Transfer list (auction)';
  END IF;

  IF v_seller = '' AND v_buyer <> '' THEN
    RETURN 'Draft auction signing';
  END IF;

  RETURN 'Transfer';
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee text;
  v_listing_type text;
  v_method text;
  v_note text := lower(coalesce(btrim(NEW.transfer_sale_note), ''));
BEGIN
  SELECT p."Name" INTO v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_seller := public.gpsl_discord_feed_club_name(NEW.seller_club_id);

  IF v_note = 'voluntary_contract_release' THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'release',
      format('📋 CONTRACT RELEASE — %s', v_name),
      format('%s left %s.', v_name, v_seller),
      12370112,
      'transfer:' || NEW.id::text,
      jsonb_build_object(
        'transfer_history_id', NEW.id,
        'transfer_sale_note', NEW.transfer_sale_note
      )
    );
    RETURN NEW;
  END IF;

  IF v_note = 'contract_expiry' THEN
    RETURN NEW;
  END IF;

  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.listing_type INTO v_listing_type
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = NEW.listing_id;

  IF lower(coalesce(v_listing_type, '')) IS DISTINCT FROM 'direct' THEN
    RETURN NEW;
  END IF;

  v_buyer := CASE
    WHEN NEW.buyer_club_id = 'FOREIGN' THEN coalesce(nullif(btrim(NEW.foreign_buyer_name), ''), 'Foreign club')
    ELSE public.gpsl_discord_feed_club_name(NEW.buyer_club_id)
  END;

  BEGIN
    v_fee := public.transfer_format_money(coalesce(NEW.fee, 0));
  EXCEPTION WHEN OTHERS THEN
    v_fee := coalesce(NEW.fee, 0)::text;
  END;

  BEGIN
    v_method := public.transfer_classify_method(
      NEW.seller_club_id, NEW.buyer_club_id, NEW.listing_id,
      NEW.transfer_sale_note, NEW.foreign_buyer_name, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_method := 'Direct offer (transfer market)';
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'transfer',
    format('🔨 DONE DEAL — %s', v_name),
    format('%s → %s\nFee: %s\n%s', v_seller, v_buyer, v_fee, v_method),
    42641,
    'transfer:' || NEW.id::text,
    jsonb_build_object('transfer_history_id', NEW.id, 'listing_type', v_listing_type)
  );

  RETURN NEW;
END;
$function$;

NOTIFY pgrst, 'reload schema';

SELECT 'PART 3 OK — history classify + discord' AS status;
