-- =============================================================================
-- Income tax on player spend (% from admin Tax % page)
-- Run once after central_bank_model_a_flows.sql and transfer_ledger_polish.sql
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS gov_income_tax_pct numeric(6, 3) NOT NULL DEFAULT 0.000;

COMMENT ON COLUMN public.global_settings.gov_income_tax_pct IS
  'League income tax % on player spend (transfer fee + agent fee, special auction fees). 0 = off.';

-- ---------------------------------------------------------------------------
-- Admin RPC
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_update_income_tax_settings(p_pct numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_pct IS NULL OR p_pct < 0 OR p_pct > 100 THEN
    RAISE EXCEPTION 'Income tax %% must be between 0 and 100';
  END IF;

  UPDATE public.global_settings
  SET gov_income_tax_pct = p_pct,
      updated_at = now()
  WHERE id = 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_update_income_tax_settings(numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- Post income tax when a club spends on players
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.post_gov_income_tax_on_player_spend(
  p_club_short_name text,
  p_spend_amount numeric,
  p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_apply_balance boolean DEFAULT true
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_pct numeric;
  v_tax numeric;
  v_meta jsonb;
  v_source_key text;
  v_source_val text;
BEGIN
  IF v_club IS NULL OR v_club = '' OR coalesce(p_spend_amount, 0) <= 0 THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(g.gov_income_tax_pct, 0)
  INTO v_pct
  FROM public.global_settings g
  WHERE g.id = 1;

  IF coalesce(v_pct, 0) <= 0 THEN
    RETURN NULL;
  END IF;

  v_tax := round(p_spend_amount * v_pct / 100.0, 2);
  IF v_tax <= 0 THEN
    RETURN NULL;
  END IF;

  v_meta := coalesce(p_metadata, '{}'::jsonb);

  IF v_meta ? 'transfer_history_id' THEN
    v_source_key := 'transfer_history_id';
    v_source_val := v_meta->>'transfer_history_id';
  ELSIF v_meta ? 'special_auction_id' THEN
    v_source_key := 'special_auction_id';
    v_source_val := v_meta->>'special_auction_id';
  END IF;

  IF v_source_key IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND l.entry_type = 'gov_income_tax'
      AND l.metadata->>v_source_key = v_source_val
    LIMIT 1
  ) THEN
    RETURN NULL;
  END IF;

  RETURN public.post_club_ledger(
    v_club,
    'gov_income_tax',
    -v_tax,
    coalesce(nullif(btrim(p_description), ''), 'Income tax on player spend'),
    v_meta || jsonb_build_object(
      'income_tax_pct', v_pct,
      'taxable_spend', p_spend_amount
    ),
    NULL,
    NULL,
    public.finance_entry_via_central_bank('gov_income_tax'),
    p_apply_balance
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.post_gov_income_tax_on_player_spend(text, numeric, text, jsonb, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Hook: transfer purchases
-- ---------------------------------------------------------------------------

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
  v_spend numeric;
BEGIN
  SELECT *
  INTO v_h
  FROM public."Transfer_History" h
  WHERE h.id = p_transfer_history_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

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
    IF coalesce(v_h.transfer_sale_note, '') = 'squad_overflow' THEN
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

  IF v_h.buyer_club_id IS NOT NULL
     AND btrim(v_h.buyer_club_id::text) <> ''
     AND v_h.buyer_club_id <> 'FOREIGN' THEN
    v_spend := abs(coalesce(v_h.fee, 0)) + abs(coalesce(v_h.agent_fee, 0));
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
END;
$function$;

-- ---------------------------------------------------------------------------
-- Hook: special auction fees
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.post_special_auction_ledger_line(
  p_club_short_name text,
  p_entry_type text,
  p_amount numeric,
  p_description text,
  p_auction_id bigint,
  p_apply_balance boolean DEFAULT false,
  p_extra_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_meta jsonb;
  v_ledger_id bigint;
BEGIN
  IF v_club IS NULL OR v_club = '' OR p_amount IS NULL OR p_amount = 0 THEN
    RETURN NULL;
  END IF;

  v_meta := jsonb_build_object('special_auction_id', p_auction_id)
    || coalesce(p_extra_metadata, '{}'::jsonb);

  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND l.entry_type = p_entry_type
      AND l.metadata->>'special_auction_id' = p_auction_id::text
      AND coalesce(l.metadata->>'ledger_role', '') =
          coalesce(v_meta->>'ledger_role', '')
    LIMIT 1
  ) THEN
    RETURN NULL;
  END IF;

  v_ledger_id := public.post_club_ledger(
    v_club,
    p_entry_type,
    p_amount,
    p_description,
    v_meta,
    NULL,
    NULL,
    false,
    p_apply_balance
  );

  IF v_ledger_id IS NOT NULL
     AND p_entry_type = 'special_auction_fee'
     AND p_amount < 0 THEN
    PERFORM public.post_gov_income_tax_on_player_spend(
      v_club,
      abs(p_amount),
      'Income tax — ' || coalesce(nullif(btrim(p_description), ''), 'special auction'),
      v_meta || jsonb_build_object('income_tax_source', 'special_auction'),
      p_apply_balance
    );
  END IF;

  RETURN v_ledger_id;
END;
$function$;
