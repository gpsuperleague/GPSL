-- =============================================================================
-- Forced-sale ledger descriptions — player + reason (2026-08-13)
--
-- Problem: squad-overflow foreign sales posted description = foreign club name
-- only (e.g. "Inter"), so owners could not see who was sold or why a foreign
-- interest slot was used. MV overflow lines said "Market value (squad over 28)"
-- without the player; fines carried the name separately.
--
-- This patch:
--   1) Adds transfer_sale_ledger_description()
--   2) Updates post_transfer_ledger_for_history (keeps prize discount + tax)
--   3) Backfills existing overflow / forced-sale ledger descriptions
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transfer_sale_ledger_description(
  p_player_name text,
  p_buyer_club_id text,
  p_foreign_buyer_name text,
  p_sale_note text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_player text := coalesce(nullif(btrim(p_player_name), ''), 'Player');
  v_buyer text := coalesce(btrim(p_buyer_club_id), '');
  v_label text := coalesce(nullif(btrim(p_foreign_buyer_name), ''), '');
  v_note text := coalesce(btrim(p_sale_note), '');
  v_is_mv_label boolean;
BEGIN
  v_is_mv_label :=
    v_label = ''
    OR v_label ILIKE 'Market value%'
    OR v_label ILIKE '%squad over 28%'
    OR v_label ILIKE '%August%';

  IF v_note = 'squad_overflow' THEN
    IF v_buyer = 'FOREIGN' AND NOT v_is_mv_label THEN
      RETURN format('Forced release (squad over 28): %s → %s', v_player, v_label);
    END IF;
    RETURN format('Forced release (squad over 28): %s', v_player);
  END IF;

  IF v_note = 'august_star_compliance' THEN
    RETURN format('Forced release (star cap): %s', v_player);
  END IF;

  IF v_note IN ('august_enforcement', 'august_compliance')
     OR v_note LIKE 'august_%' THEN
    RETURN format('Forced release (August compliance): %s', v_player);
  END IF;

  IF v_buyer = 'FOREIGN' THEN
    IF v_label <> '' AND NOT v_is_mv_label THEN
      RETURN format('Foreign sale: %s → %s', v_player, v_label);
    END IF;
    IF v_label <> '' THEN
      RETURN format('%s: %s', v_label, v_player);
    END IF;
    RETURN 'Foreign sale: ' || v_player;
  END IF;

  RETURN 'Sale: ' || v_player;
END;
$function$;

COMMENT ON FUNCTION public.transfer_sale_ledger_description(text, text, text, text) IS
  'Human ledger description for transfer sales, including forced/regulation releases.';

-- Based on gov_income_tax_transfer_restore.sql + clearer forced-sale descriptions
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
  v_note text;
  v_bank_leg boolean;
  v_sell_type text;
BEGIN
  SELECT *
  INTO v_h
  FROM public."Transfer_History" h
  WHERE h.id = p_transfer_history_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_note := coalesce(btrim(v_h.transfer_sale_note), '');
  v_fee := abs(coalesce(v_h.fee, 0));

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

  -- Contract expiry compensation (central bank) — early return
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
        'transfer_sale',
        'transfer_purchase',
        'transfer_foreign_sale',
        'transfer_overflow_release',
        'contract_expiry_compensation'
      )
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

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
    v_desc_sell := public.transfer_sale_ledger_description(
      v_player_name,
      v_h.buyer_club_id::text,
      v_h.foreign_buyer_name,
      v_note
    );

    IF v_note = 'squad_overflow'
       OR v_note LIKE 'august_%'
       OR (
         v_h.buyer_club_id = 'FOREIGN'
         AND v_note NOT IN ('contract_expiry', 'special_auction')
         AND coalesce(v_note, '') NOT LIKE 'special_auction:%'
       ) THEN
      v_sell_type := CASE
        WHEN v_note = 'squad_overflow' AND v_h.buyer_club_id IS DISTINCT FROM 'FOREIGN'
          THEN 'transfer_overflow_release'
        WHEN v_h.buyer_club_id = 'FOREIGN'
          THEN 'transfer_foreign_sale'
        ELSE 'transfer_sale'
      END;

      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        v_sell_type,
        abs(v_fee),
        v_desc_sell,
        v_meta || jsonb_build_object(
          'transfer_sale_note', nullif(v_note, ''),
          'foreign_buyer_name', nullif(btrim(v_h.foreign_buyer_name), '')
        ),
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

-- Also post ledger for August forced releases (balance already applied in-function)
CREATE OR REPLACE FUNCTION public.club_august_release_player(
  p_club_short_name text,
  p_player_id text,
  p_mv_rate numeric DEFAULT 1.0,
  p_sale_note text DEFAULT 'august_enforcement',
  p_buyer_label text DEFAULT 'Market value (August enforcement)'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_pid text := btrim(p_player_id);
  v_ooo text := public.club_ooo_player_id(v_club);
  v_player public."Players"%rowtype;
  v_fee numeric;
  v_bal numeric;
  v_rate numeric := greatest(coalesce(p_mv_rate, 1.0), 0);
  v_history_id bigint;
BEGIN
  IF v_ooo IS NOT NULL AND v_pid = v_ooo THEN
    RAISE EXCEPTION 'One of Our Own cannot be released';
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := round(greatest(coalesce(v_player.market_value::numeric, 0), 0) * v_rate);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed', transfer_completed = false, winning_bid = null, winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.ensure_foreign_buyer_club();
  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

  INSERT INTO public."Transfer_History" (
    player_id, seller_club_id, buyer_club_id, fee, agent_fee,
    transfer_time, listing_id, foreign_buyer_name, transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID", v_club, 'FOREIGN', v_fee, 0,
    now(), NULL, p_buyer_label, p_sale_note
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id, false);
  END IF;

  IF to_regprocedure('public.player_apply_overflow_paid_up_lock(text, text)') IS NOT NULL THEN
    PERFORM public.player_apply_overflow_paid_up_lock(v_pid, v_club);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'fee', v_fee,
    'mv_rate', v_rate,
    'sale_note', p_sale_note,
    'history_id', v_history_id
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Backfill existing overflow / forced foreign-sale ledger lines (description only)
-- ---------------------------------------------------------------------------
WITH targets AS (
  SELECT
    l.id AS ledger_id,
    l.description AS old_description,
    public.transfer_sale_ledger_description(
      coalesce(p."Name", h.player_id::text),
      h.buyer_club_id::text,
      h.foreign_buyer_name,
      h.transfer_sale_note
    ) AS new_description
  FROM public.competition_finance_ledger l
  JOIN public."Transfer_History" h
    ON l.metadata->>'transfer_history_id' = h.id::text
  LEFT JOIN public."Players" p
    ON p."Konami_ID"::text = h.player_id::text
  WHERE l.entry_type IN ('transfer_foreign_sale', 'transfer_overflow_release', 'transfer_sale')
    AND (
      coalesce(h.transfer_sale_note, '') IN (
        'squad_overflow',
        'august_star_compliance',
        'august_enforcement',
        'august_compliance'
      )
      OR coalesce(h.transfer_sale_note, '') LIKE 'august_%'
      OR (
        h.buyer_club_id = 'FOREIGN'
        AND l.entry_type = 'transfer_foreign_sale'
        AND (
          l.description IS NULL
          OR btrim(l.description) = btrim(coalesce(h.foreign_buyer_name, ''))
          OR l.description NOT ILIKE '%' || coalesce(p."Name", '___none___') || '%'
        )
      )
    )
)
UPDATE public.competition_finance_ledger l
SET description = t.new_description
FROM targets t
WHERE l.id = t.ledger_id
  AND coalesce(l.description, '') IS DISTINCT FROM t.new_description;

-- Preview helper (optional): how many still look like bare foreign-club names
-- SELECT count(*) FROM competition_finance_ledger
-- WHERE entry_type = 'transfer_foreign_sale'
--   AND description NOT ILIKE 'Forced release%'
--   AND description NOT ILIKE 'Foreign sale:%';

GRANT EXECUTE ON FUNCTION public.transfer_sale_ledger_description(text, text, text, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.post_transfer_ledger_for_history(bigint, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.club_august_release_player(text, text, numeric, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
