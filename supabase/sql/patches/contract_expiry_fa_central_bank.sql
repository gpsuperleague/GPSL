-- =============================================================================
-- Contract expiry FA releases → Central Bank compensation (not foreign sales)
-- + former-club re-sign block
--
-- Rules:
--   • Unrenewed / unbid final-year players return to GPDB as free agents
--   • Holding club receives MV from GPSL Central Bank (entry: contract_expiry_compensation)
--   • NOT posted as transfer_foreign_sale / real-world foreign buyer
--   • Former club cannot re-sign that player while the expiry_fa block remains
--     (cleared when another club signs them via player_assign_to_club)
--
-- Contested wage wars unchanged: other club pays MV; holder wins → no MV fee.
--
-- Run in Supabase SQL Editor after:
--   contract_release_delete_where_fix.sql / contract_expiry_rollover_new_season_ledger.sql
--   foreign_lock_preseason_fallback.sql
--   player_assign_to_club_overload_fix.sql
--   central_bank_model_a_flows.sql (or any finance_entry_via_central_bank definition)
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Ledger entry type allow-list (union live + catalogue + new type)
-- ---------------------------------------------------------------------------
DO $ledger_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'gate_league_home', 'gate_cup_share', 'gate_friendlies',
      'prize', 'prize_league', 'prize_cup', 'prize_challenge',
      'tv_revenue',
      'gov_hg_subsidy', 'gov_youth_subsidy', 'gov_bnb_subsidy',
      'gov_fine_compensation', 'gov_emergency_tax', 'gov_income_tax',
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax',
      'adjustment', 'admin_one_off_injection', 'admin_purchase_payment',
      'transfer_sale', 'transfer_purchase', 'transfer_agent_fee',
      'transfer_foreign_sale', 'transfer_overflow_release',
      'loan_drawdown', 'loan_repayment_principal', 'loan_interest_payment',
      'infra_maintenance', 'infra_purchase', 'infra_expansion',
      'infra_expansion_refund', 'infra_expansion_penalty',
      'contract_release_comp', 'contract_release_comp_received',
      'contract_termination', 'contract_signing_offer',
      'contract_expiry_compensation',
      'staff_manager_salary',
      'eos_debt_interest', 'eos_ffp_charge', 'eos_balance_interest', 'eos_injection',
      'special_auction_fee', 'special_auction_prize',
      'season_loan_fee', 'season_loan_refund',
      'new_owner_release', 'voluntary_contract_release',
      'medical_physio_hire', 'medical_doctor_hire',
      'contract_expiry_champ_signing_fee'
    ])
  ) s;

  IF v_list IS NULL OR length(v_list) < 3 THEN
    RAISE EXCEPTION 'Could not build entry_type allow-list';
  END IF;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );
END;
$ledger_types$;

-- ---------------------------------------------------------------------------
-- Central Bank: contract_expiry_compensation is a bank payout to clubs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finance_entry_via_central_bank(p_entry_type text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_entry_type, '') = ANY(ARRAY[
    'gov_hg_subsidy',
    'gov_youth_subsidy',
    'gov_bnb_subsidy',
    'gov_emergency_tax',
    'gov_income_tax',
    'gov_fine_compensation',
    'wage_star_tax',
    'eos_debt_interest',
    'eos_ffp_charge',
    'eos_balance_interest',
    'eos_injection',
    'prize',
    'prize_league',
    'prize_cup',
    'prize_challenge',
    'prize_fee_discount_subsidy',
    'tv_revenue',
    'infra_purchase',
    'infra_expansion',
    'infra_expansion_refund',
    'infra_expansion_penalty',
    'loan_drawdown',
    'loan_repayment_principal',
    'loan_interest_payment',
    'admin_one_off_injection',
    'contract_release_comp_received',
    'contract_expiry_compensation',
    'special_auction_prize'
  ]);
$$;

COMMENT ON FUNCTION public.finance_entry_via_central_bank(text) IS
  'Model A: true when club ledger line should mirror a GPSL Central Bank leg. '
  'Gate receipts, squad/manager wages, 34+ fees, and club-to-club transfers are false. '
  'contract_expiry_compensation = Central Bank MV payout on uncontested contract ends.';

-- ---------------------------------------------------------------------------
-- Lock kind: expiry_fa = former club blocked; other clubs may sign
-- ---------------------------------------------------------------------------
ALTER TABLE public."Players"
  DROP CONSTRAINT IF EXISTS players_foreign_contract_lock_kind_check;

ALTER TABLE public."Players"
  ADD CONSTRAINT players_foreign_contract_lock_kind_check
  CHECK (
    foreign_contract_lock_kind IS NULL
    OR foreign_contract_lock_kind IN ('foreign', 'paid_up', 'expiry_fa')
  );

COMMENT ON COLUMN public."Players".foreign_contract_lock_kind IS
  'foreign = sold abroad (all clubs blocked); paid_up = overflow release (all clubs blocked); '
  'expiry_fa = contract ended → FA for other clubs only (former club blocked).';

CREATE OR REPLACE FUNCTION public.player_foreign_contract_locked(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- Global unavailability (draft / GPDB). expiry_fa is NOT global — other clubs may sign.
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND p.foreign_contract_club IS NOT NULL
      AND btrim(p.foreign_contract_club) <> ''
      AND p.foreign_contract_sold_season_id IS NOT NULL
      AND p.foreign_contract_sold_season_id = public.current_gpsl_season_id()
      AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), 'foreign')
            IN ('foreign', 'paid_up')
  );
$$;

CREATE OR REPLACE FUNCTION public.player_expiry_fa_former_club(p_player_id text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT nullif(btrim(p.foreign_contract_club), '')
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id)
    AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), '') = 'expiry_fa'
    AND p."Contracted_Team" IS NULL
$$;

CREATE OR REPLACE FUNCTION public.assert_club_may_sign_expiry_fa_player(
  p_player_id text,
  p_club_short_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_former text;
  v_club text := btrim(p_club_short_name);
BEGIN
  v_former := public.player_expiry_fa_former_club(p_player_id);
  IF v_former IS NULL OR v_club IS NULL OR v_club = '' THEN
    RETURN;
  END IF;

  IF lower(v_former) = lower(v_club) THEN
    RAISE EXCEPTION
      'You cannot re-sign this player after their contract expired — they returned to the GPDB as a free agent for other clubs only';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_apply_expiry_fa_former_club_block(
  p_player_id text,
  p_former_club_short_name text,
  p_sold_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_former_club_short_name);
  v_sold_season_id bigint;
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_apply_expiry_fa_former_club_block: player_id required';
  END IF;
  IF v_club = '' THEN
    RAISE EXCEPTION 'player_apply_expiry_fa_former_club_block: former club required';
  END IF;

  v_sold_season_id := coalesce(p_sold_season_id, public.gpsl_season_id_for_locks());
  IF v_sold_season_id IS NULL THEN
    v_sold_season_id := public.current_gpsl_season_id();
  END IF;

  UPDATE public."Players"
  SET
    foreign_contract_club = v_club,
    foreign_contract_sold_season_id = v_sold_season_id,
    foreign_contract_unlock_season_label = 'when signed by another club',
    foreign_contract_lock_kind = 'expiry_fa'
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_expiry_fa_former_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_club_may_sign_expiry_fa_player(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_apply_expiry_fa_former_club_block(text, text, bigint)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- player_assign_to_club: enforce former-club block before clear
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text);
DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text, numeric);

CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text,
  p_wage numeric DEFAULT NULL,
  p_defer_squad_overflow boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid      text := btrim(p_player_id);
  v_club     text := btrim(p_club_short_name);
  v_season   text;
  v_wage     numeric;
  v_overflow jsonb;
  v_defer    boolean;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  v_defer := p_defer_squad_overflow
    OR coalesce(
      nullif(current_setting('gpsl.defer_squad_overflow', true), ''),
      ''
    ) = 'on';

  PERFORM public.assert_club_may_sign_expiry_fa_player(v_pid, v_club);

  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    PERFORM public.assert_player_available_for_signing(v_pid);
  END IF;

  v_season := public.current_gpsl_season_label();
  v_wage := coalesce(p_wage, public.calculate_player_wage_for_club(v_pid, v_club));

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season,
    contract_seasons_remaining = 3,
    contract_wage = round(coalesce(v_wage, 0), 0),
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = v_pid;

  IF v_defer THEN
    v_overflow := jsonb_build_object(
      'released', false,
      'deferred', true,
      'squad_total', public.club_squad_player_count(v_club)
    );
  ELSE
    v_overflow := public.enforce_squad_overflow_after_signing(v_club, v_pid);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'club_short_name', v_club,
    'contract_seasons_remaining', 3,
    'overflow_release', v_overflow
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_assign_to_club(text, text, numeric, boolean)
  TO authenticated;

-- Block former club from bidding on expiry FAs (draft / market)
CREATE OR REPLACE FUNCTION public.trg_transfer_bid_block_same_season_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
  v_bidder text;
BEGIN
  v_player_id := btrim(coalesce(NEW.player_id, NEW.direct_bid_id::text, ''));

  IF v_player_id = '' AND NEW.listing_id IS NOT NULL THEN
    SELECT btrim(l.player_id::text)
    INTO v_player_id
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_player_id IS NULL OR v_player_id = '' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(v_player_id);
  PERFORM public.assert_player_available_for_signing(v_player_id);

  v_bidder := nullif(btrim(coalesce(NEW.bidder_club_id::text, '')), '');
  IF v_bidder IS NOT NULL THEN
    PERFORM public.assert_club_may_sign_expiry_fa_player(v_player_id, v_bidder);
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- FA release: Central Bank compensation + expiry_fa block (not foreign sale)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_release_zero_year_players(
  p_ledger_season_id bigint DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int := 0;
  v_ledger_id bigint := p_ledger_season_id;
  v_ledger_label text;
  v_ctx record;
  r record;
  v_bank_leg boolean := true;
BEGIN
  -- FOREIGN sentinel still required: Transfer_History.buyer_club_id is NOT NULL
  PERFORM public.ensure_foreign_buyer_club();

  IF v_ledger_id IS NULL THEN
    SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();
    v_ledger_id := v_ctx.ledger_season_id;
    v_ledger_label := v_ctx.ledger_season_label;
  ELSE
    SELECT btrim(s.label) INTO v_ledger_label
    FROM public.competition_seasons s
    WHERE s.id = v_ledger_id;
  END IF;

  IF v_ledger_id IS NULL THEN
    RAISE EXCEPTION 'No ledger season for contract FA releases';
  END IF;

  IF to_regprocedure('public.finance_entry_via_central_bank(text)') IS NOT NULL THEN
    v_bank_leg := coalesce(
      public.finance_entry_via_central_bank('contract_expiry_compensation'),
      true
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _contract_expire_batch (
    player_id text PRIMARY KEY,
    club text NOT NULL,
    fee numeric NOT NULL DEFAULT 0,
    player_name text
  ) ON COMMIT DROP;

  DELETE FROM _contract_expire_batch WHERE true;

  INSERT INTO _contract_expire_batch (player_id, club, fee, player_name)
  SELECT
    p."Konami_ID"::text,
    public.player_contracted_club_key(p."Contracted_Team"),
    greatest(coalesce(p.market_value::numeric, 0), 0),
    p."Name"
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining <= 0;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN 0;
  END IF;

  -- One ledger + bank leg per player (Central Bank pays MV to holding club)
  FOR r IN
    SELECT * FROM _contract_expire_batch e WHERE e.fee > 0 ORDER BY e.player_id
  LOOP
    PERFORM public.post_club_ledger(
      r.club,
      'contract_expiry_compensation',
      r.fee,
      'Contract ended (free agent): ' || coalesce(r.player_name, r.player_id),
      jsonb_build_object(
        'player_id', r.player_id,
        'player_name', r.player_name,
        'holding_club', r.club,
        'market_value', r.fee,
        'ledger_season_id', v_ledger_id,
        'ledger_season_label', v_ledger_label,
        'source', 'contract_expiry_fa',
        'compensation_from', 'central_bank'
      ),
      v_ledger_id,
      NULL,
      v_bank_leg,
      true
    );
  END LOOP;

  UPDATE public."Players" p
  SET
    "Contracted_Team" = NULL,
    "Season_Signed" = NULL,
    contract_seasons_remaining = NULL,
    contract_wage = NULL,
    foreign_contract_club = e.club,
    foreign_contract_sold_season_id = v_ledger_id,
    foreign_contract_unlock_season_label = 'when signed by another club',
    foreign_contract_lock_kind = 'expiry_fa'
  FROM _contract_expire_batch e
  WHERE p."Konami_ID"::text = e.player_id;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  SELECT
    e.player_id,
    e.club,
    'FOREIGN',
    e.fee,
    0,
    now(),
    NULL,
    'Contract Run Down - Central Bank Compensation',
    'contract_expiry'
  FROM _contract_expire_batch e;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_release_zero_year_players(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Transfer history → ledger backfill: do not treat as foreign sale
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

  -- Contract expiry FA: Central Bank compensation (idempotent)
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
      -- Club↔club (and legacy foreign rows) — same as central_bank_model_a_flows
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

-- ---------------------------------------------------------------------------
-- Classify / Discord: not a foreign sale
-- ---------------------------------------------------------------------------
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

-- Soft-skip Discord spam for mass FA releases
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

  -- Mass FA releases at season tick — skip Discord (would flood the channel)
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

-- ---------------------------------------------------------------------------
-- Optional backfill: reclassify already-posted contract_expiry FA foreign sales
-- (idempotent — only rows with source=contract_expiry_fa / note=contract_expiry)
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
  v_n int := 0;
  v_bank int := 0;
  v_bank_debit numeric := 0;
BEGIN
  UPDATE public.competition_finance_ledger l
  SET
    entry_type = 'contract_expiry_compensation',
    description = regexp_replace(
      coalesce(l.description, ''),
      '^Contract expired \(free agent\)',
      'Contract ended (free agent)'
    ),
    metadata = (coalesce(l.metadata, '{}'::jsonb) - 'buyer')
      || jsonb_build_object('compensation_from', 'central_bank')
  WHERE l.entry_type = 'transfer_foreign_sale'
    AND coalesce(l.metadata->>'source', '') = 'contract_expiry_fa';

  GET DIAGNOSTICS v_n = ROW_COUNT;

  WITH missing AS (
    SELECT
      l.id,
      l.entry_type,
      l.amount,
      l.description,
      l.club_short_name,
      coalesce(l.metadata, '{}'::jsonb) AS metadata
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_expiry_compensation'
      AND coalesce(l.metadata->>'source', '') = 'contract_expiry_fa'
      AND NOT EXISTS (
        SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = l.id
      )
  ),
  inserted AS (
    INSERT INTO public.bank_ledger (
      entry_type,
      amount,
      description,
      club_short_name,
      club_ledger_id,
      metadata
    )
    SELECT
      m.entry_type,
      -m.amount,
      m.description,
      m.club_short_name,
      m.id,
      m.metadata
    FROM missing m
    RETURNING amount
  )
  SELECT
    count(*)::int,
    coalesce(sum(-amount), 0)  -- positive debit from bank (= club credits)
  INTO v_bank, v_bank_debit
  FROM inserted;

  IF v_bank_debit <> 0 THEN
    UPDATE public.gpsl_bank_account
    SET
      reserves = reserves - v_bank_debit,
      updated_at = now()
    WHERE id = 1;
  END IF;

  UPDATE public."Transfer_History" h
  SET foreign_buyer_name = 'Contract Run Down - Central Bank Compensation'
  WHERE h.transfer_sale_note = 'contract_expiry'
    AND h.buyer_club_id = 'FOREIGN'
    AND coalesce(h.foreign_buyer_name, '')
          IS DISTINCT FROM 'Contract Run Down - Central Bank Compensation';

  UPDATE public."Players" p
  SET
    foreign_contract_club = h.seller_club_id,
    foreign_contract_sold_season_id = coalesce(
      public.gpsl_season_id_for_locks(),
      public.current_gpsl_season_id()
    ),
    foreign_contract_unlock_season_label = 'when signed by another club',
    foreign_contract_lock_kind = 'expiry_fa'
  FROM (
    SELECT DISTINCT ON (h2.player_id)
      h2.player_id::text AS player_id,
      h2.seller_club_id
    FROM public."Transfer_History" h2
    WHERE h2.transfer_sale_note = 'contract_expiry'
      AND h2.seller_club_id IS NOT NULL
    ORDER BY h2.player_id, h2.transfer_time DESC, h2.id DESC
  ) h
  WHERE p."Konami_ID"::text = h.player_id
    AND p."Contracted_Team" IS NULL
    AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), '')
          IS DISTINCT FROM 'foreign'
    AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), '')
          IS DISTINCT FROM 'paid_up';

  RAISE NOTICE
    'contract_expiry_fa backfill: ledger retyped=% bank legs=% bank debit=%',
    v_n, v_bank, v_bank_debit;
END;
$backfill$;
