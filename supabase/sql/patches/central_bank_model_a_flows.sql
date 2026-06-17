-- =============================================================================
-- Central Bank — Model A flows (signed-off counterparty rules)
-- Run once after: central_bank_phase1.sql, central_bank_loans.sql,
--   government_subsidies.sql, competition_fines.sql, competition_wages_taxes.sql,
--   competition_tv_revenue.sql, competition_league_prizes.sql,
--   competition_cup_prizes_fix.sql, stadium_expansion.sql,
--   patches/club_assignment_stadium_charge.sql, patches/manager_draft_settlement_fix.sql
--
-- After apply:
--   SELECT public.backfill_central_bank_legs(false);  -- mirror past ledger rows to bank_ledger
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Entry types + helper: which flows use GPSL Central Bank
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_finance_ledger
  DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

ALTER TABLE public.competition_finance_ledger
  ADD CONSTRAINT competition_finance_ledger_entry_type_check
  CHECK (
    entry_type IN (
      'gate_league_home',
      'gate_cup_share',
      'prize',
      'prize_league',
      'prize_cup',
      'prize_challenge',
      'tv_revenue',
      'gov_hg_subsidy',
      'gov_youth_subsidy',
      'gov_bnb_subsidy',
      'gov_fine_compensation',
      'gov_emergency_tax',
      'gov_income_tax',
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'adjustment',
      'admin_one_off_injection',
      'admin_purchase_payment',
      'transfer_sale',
      'transfer_purchase',
      'transfer_agent_fee',
      'transfer_foreign_sale',
      'transfer_overflow_release',
      'loan_drawdown',
      'loan_repayment_principal',
      'loan_interest_payment',
      'infra_maintenance',
      'infra_purchase',
      'infra_expansion',
      'infra_expansion_refund',
      'infra_expansion_penalty',
      'contract_release_comp',
      'contract_release_comp_received',
      'contract_termination',
      'contract_signing_offer',
      'staff_manager_salary',
      'eos_debt_interest',
      'eos_ffp_charge',
      'eos_balance_interest',
      'eos_injection',
      'special_auction_fee',
      'special_auction_prize'
    )
  );

ALTER TABLE public.competition_season_charge_paid
  DROP CONSTRAINT IF EXISTS competition_season_charge_paid_charge_type_check;

ALTER TABLE public.competition_season_charge_paid
  ADD CONSTRAINT competition_season_charge_paid_charge_type_check
  CHECK (
    charge_type IN (
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'gov_emergency_tax',
      'gov_income_tax',
      'eos_ffp_charge',
      'eos_debt_interest',
      'eos_balance_interest'
    )
  );

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
    'special_auction_prize'
  ]);
$$;

COMMENT ON FUNCTION public.finance_entry_via_central_bank(text) IS
  'Model A: true when club ledger line should mirror a GPSL Central Bank leg. '
  'Gate receipts, squad/manager wages, 34+ fees, and club-to-club transfers are false.';

-- ---------------------------------------------------------------------------
-- GPDB draft player signings → central bank (seller null); club↔club unchanged
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
END;
$function$;

-- ---------------------------------------------------------------------------
-- Manager GPDB draft signings → central bank + ledger
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_accept_manager_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_mgr     public."Managers"%rowtype;
  v_buyer_balance numeric;
  v_season_id bigint;
  v_wage bigint;
  v_mgr_name text;
  v_meta jsonb;
BEGIN
  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Manager draft listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RAISE NOTICE 'Manager listing % is not draft', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Manager draft listing % already processed', p_listing_id;
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_amount, v_buyer
  FROM public."Manager_Transfer_Bids" b
  WHERE b.is_direct = true
    AND (
      b.listing_id = v_listing.id
      OR b.manager_id = v_listing.manager_id
    )
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    v_buyer := nullif(btrim(v_listing.current_highest_bidder), '');
    v_amount := v_listing.current_highest_bid;
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer,
      updated_at = now()
  WHERE id = v_listing.id;

  SELECT balance
  INTO v_buyer_balance
  FROM public."Club_Finances"
  WHERE club_name = v_buyer
  FOR UPDATE;

  IF v_buyer_balance IS NULL THEN
    RAISE NOTICE 'Buyer finance missing for manager draft listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_buyer_balance < v_amount THEN
    RAISE NOTICE 'Insufficient balance for manager draft listing %', p_listing_id;
    RETURN;
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE id = v_listing.manager_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Manager not found for draft listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    RAISE NOTICE 'Manager already contracted for draft listing %', p_listing_id;
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Managers" m
    WHERE m.contracted_club = v_buyer
  ) OR EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_buyer AND c.manager_id IS NOT NULL
  ) THEN
    RAISE NOTICE 'Buyer % already has a manager — cannot settle draft listing %',
      v_buyer, p_listing_id;
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_wage := public.manager_weekly_wage_for(v_mgr.market_value);
  v_mgr_name := coalesce(nullif(btrim(v_mgr.name), ''), 'Manager #' || v_listing.manager_id::text);

  v_meta := jsonb_build_object(
    'manager_draft', true,
    'listing_id', v_listing.id,
    'manager_id', v_listing.manager_id
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'transfer_purchase'
      AND l.metadata->>'listing_id' = v_listing.id::text
      AND l.metadata->>'manager_draft' = 'true'
  ) THEN
    PERFORM public.post_club_ledger(
      v_buyer,
      'transfer_purchase',
      -abs(v_amount),
      format('Manager draft signing — %s', v_mgr_name),
      v_meta,
      v_season_id,
      NULL,
      true,
      true
    );
  END IF;

  UPDATE public."Managers"
  SET contracted_club = v_buyer,
      contract_seasons_remaining = 2,
      weekly_wage = v_wage,
      signed_season_id = v_season_id,
      updated_at = now()
  WHERE id = v_listing.manager_id;

  PERFORM public.manager_sync_club_rating(v_buyer);

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      updated_at = now()
  WHERE id = v_listing.id;

  RAISE NOTICE 'Manager draft listing % settled — manager % to % for %',
    p_listing_id, v_listing.manager_id, v_buyer, v_amount;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Club assignment / club auction stadium purchase → central bank
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_apply_club_assignment_finances(
  p_club_short_name text,
  p_owner_id uuid,
  p_starting_budget numeric,
  p_total_debit numeric DEFAULT NULL,
  p_source text DEFAULT 'club_assignment',
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_stadium numeric;
  v_debit numeric;
  v_starting numeric;
  v_balance numeric;
  v_season_id bigint;
  v_club_name text;
  v_desc text;
  v_meta jsonb;
  v_ledger_id bigint;
  v_dup_key text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_debit := coalesce(nullif(p_total_debit, 0), v_stadium);
  v_debit := greatest(v_debit, v_stadium);
  v_starting := greatest(coalesce(p_starting_budget, 0), 0);
  v_balance := greatest(v_starting - v_debit, 0);

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_meta := coalesce(p_metadata, '{}'::jsonb)
    || jsonb_build_object(
      'source', coalesce(nullif(btrim(p_source), ''), 'club_assignment'),
      'owner_id', p_owner_id,
      'stadium_cost', v_stadium,
      'total_debit', v_debit,
      'starting_budget', v_starting
    );

  v_dup_key := coalesce(v_meta->>'listing_id', v_meta->>'assignment_key', p_owner_id::text);

  IF EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_club
  ) THEN
    UPDATE public."Club_Finances"
    SET balance = v_balance
    WHERE club_name = v_club;
  ELSE
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_club, v_balance);
  END IF;

  v_season_id := public.competition_finances_current_season_id();

  IF v_debit > 0 AND v_season_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
        AND l.season_id = v_season_id
        AND l.entry_type = 'infra_purchase'
        AND coalesce(l.metadata->>'source', '') = coalesce(nullif(btrim(p_source), ''), 'club_assignment')
        AND coalesce(l.metadata->>'dup_key', l.metadata->>'listing_id', '') = v_dup_key
    ) THEN
      v_desc := coalesce(
        nullif(btrim(p_description), ''),
        format(
          'Stadium purchase — %s (%s) — ₿%s (capacity × ₿1,000)',
          coalesce(v_club_name, v_club),
          v_club,
          to_char(v_stadium, 'FM999,999,999,999')
        )
      );

      IF v_debit > v_stadium THEN
        v_desc := v_desc || format(
          ' + auction premium ₿%s',
          to_char(v_debit - v_stadium, 'FM999,999,999,999')
        );
      END IF;

      v_meta := v_meta || jsonb_build_object('dup_key', v_dup_key);

      v_ledger_id := public.post_club_ledger(
        v_club,
        'infra_purchase',
        -v_debit,
        v_desc,
        v_meta,
        v_season_id,
        NULL,
        true,
        false
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'stadium_cost', v_stadium,
    'total_debit', v_debit,
    'starting_budget', v_starting,
    'balance', v_balance,
    'season_id', v_season_id,
    'ledger_id', v_ledger_id,
    'ledger_skipped_no_season', v_season_id IS NULL AND v_debit > 0
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Government subsidies → central bank
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gov_pay_club_subsidy(
  p_season_id bigint,
  p_club_short_name text,
  p_subsidy_type text,
  p_amount numeric,
  p_status_label text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_desc text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_gov_subsidy_paid
    WHERE season_id = p_season_id
      AND club_short_name = p_club_short_name
      AND subsidy_type = p_subsidy_type
  ) THEN
    RETURN false;
  END IF;

  v_desc := CASE p_subsidy_type
    WHEN 'gov_hg_subsidy' THEN format('HG subsidy — %s', coalesce(p_status_label, 'Homegrown'))
    WHEN 'gov_youth_subsidy' THEN format('Youth subsidy — %s', coalesce(p_status_label, 'Youth'))
    WHEN 'gov_bnb_subsidy' THEN format('Built not bought — %s', coalesce(p_status_label, 'BnB'))
    ELSE 'Government subsidy'
  END;

  PERFORM public.post_club_ledger(
    p_club_short_name,
    p_subsidy_type,
    p_amount,
    v_desc,
    p_metadata,
    p_season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.competition_gov_subsidy_paid (
    season_id, club_short_name, subsidy_type, amount, status_label, metadata
  )
  VALUES (
    p_season_id, p_club_short_name, p_subsidy_type, p_amount, p_status_label, p_metadata
  );

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fines & compensation → central bank
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_apply_club_fine_tariff(
  p_club_short_name text,
  p_tariff_code text,
  p_amount_override numeric DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_fixture_id bigint DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tariff public.competition_fine_tariff;
  v_club text := btrim(p_club_short_name);
  v_amount numeric;
  v_ledger_amount numeric;
  v_season_id bigint;
  v_desc text;
  v_ledger_id bigint;
  v_applied_id bigint;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  SELECT * INTO v_tariff
  FROM public.competition_fine_tariff
  WHERE code = p_tariff_code AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown or inactive tariff: %', p_tariff_code;
  END IF;

  IF v_tariff.amount_mode = 'manual' THEN
    v_amount := p_amount_override;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Manual amount required for %', v_tariff.label;
    END IF;
  ELSE
    v_amount := coalesce(p_amount_override, v_tariff.amount);
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Tariff % has no amount configured', v_tariff.label;
    END IF;
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_tariff.direction = 'fine' THEN
    v_ledger_amount := -abs(v_amount);
    v_desc := format('Fine — %s', v_tariff.label);
  ELSE
    v_ledger_amount := abs(v_amount);
    v_desc := format('Compensation — %s', v_tariff.label);
  END IF;

  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    v_desc := v_desc || ' — ' || btrim(p_note);
  END IF;

  v_ledger_id := public.post_club_ledger(
    v_club,
    'gov_fine_compensation',
    v_ledger_amount,
    v_desc,
    jsonb_build_object(
      'tariff_code', v_tariff.code,
      'direction', v_tariff.direction,
      'category', v_tariff.category
    ),
    v_season_id,
    p_fixture_id,
    true,
    true
  );

  INSERT INTO public.competition_fine_applied (
    season_id, tariff_code, club_short_name, amount, direction,
    description, note, fixture_id, ledger_id, applied_by
  )
  VALUES (
    v_season_id, v_tariff.code, v_club, abs(v_amount), v_tariff.direction,
    v_desc, p_note, p_fixture_id, v_ledger_id,
    CASE WHEN public.is_gpsl_admin() THEN 'ADMIN' ELSE 'SYSTEM' END
  )
  RETURNING id INTO v_applied_id;

  RETURN jsonb_build_object(
    'applied_id', v_applied_id,
    'ledger_id', v_ledger_id,
    'club_short_name', v_club,
    'tariff_code', v_tariff.code,
    'amount', abs(v_amount),
    'direction', v_tariff.direction,
    'description', v_desc
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Season charges: central bank for taxes/FFP; virtual payees for wages
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_club_charge(
  p_season_id bigint,
  p_club_short_name text,
  p_charge_type text,
  p_amount numeric,
  p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_season_charge_paid
    WHERE season_id = p_season_id
      AND club_short_name = p_club_short_name
      AND charge_type = p_charge_type
  ) THEN
    RETURN false;
  END IF;

  PERFORM public.post_club_ledger(
    p_club_short_name,
    p_charge_type,
    -p_amount,
    p_description,
    p_metadata,
    p_season_id,
    NULL,
    public.finance_entry_via_central_bank(p_charge_type),
    true
  );

  INSERT INTO public.competition_season_charge_paid (
    season_id, club_short_name, charge_type, amount, metadata
  )
  VALUES (
    p_season_id, p_club_short_name, p_charge_type, p_amount, p_metadata
  );

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- TV revenue → central bank
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_tv_settle_fixture(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_amount numeric;
  v_desc text;
  v_meta jsonb;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection WHERE fixture_id = p_fixture_id
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND competition_type = 'league'
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_amount := (SELECT tv_per_match_amount FROM public.global_settings WHERE id = 1);

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.home_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue MD%s — %s vs %s',
      v_fixture.matchday,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object('gpsl_month', v_fixture.gpsl_month, 'role', 'home');
    PERFORM public.post_club_ledger(
      v_fixture.home_club_short_name,
      'tv_revenue',
      v_amount,
      v_desc,
      v_meta,
      v_fixture.season_id,
      p_fixture_id,
      true,
      true
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.away_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue MD%s — %s vs %s',
      v_fixture.matchday,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object('gpsl_month', v_fixture.gpsl_month, 'role', 'away');
    PERFORM public.post_club_ledger(
      v_fixture.away_club_short_name,
      'tv_revenue',
      v_amount,
      v_desc,
      v_meta,
      v_fixture.season_id,
      p_fixture_id,
      true,
      true
    );
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- League / cup / challenge prizes → central bank
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_credit_round_prize(
  p_fixture_id bigint,
  p_club_short_name text,
  p_stage text,
  p_amount numeric,
  p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_club text := btrim(p_club_short_name);
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN false;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cup fixture % not found', p_fixture_id;
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Club % is not in fixture %', v_club, p_fixture_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_cup_prize_paid
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_club
      AND stage = p_stage
  ) THEN
    RETURN false;
  END IF;

  PERFORM public.post_club_ledger(
    v_club,
    'prize_cup',
    p_amount,
    p_description,
    p_metadata,
    v_fixture.season_id,
    p_fixture_id,
    true,
    true
  );

  INSERT INTO public.competition_cup_prize_paid (fixture_id, club_short_name, stage, amount)
  VALUES (p_fixture_id, v_club, p_stage, p_amount);

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_award_challenge(
  p_challenge_id bigint,
  p_club_short_name text,
  p_stat_value int
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_c public.competition_challenge_config;
  v_amount numeric;
BEGIN
  SELECT * INTO v_c
  FROM public.competition_challenge_config
  WHERE id = p_challenge_id
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_challenge_awarded
    WHERE challenge_id = p_challenge_id
      AND club_short_name = p_club_short_name
  ) THEN
    RETURN false;
  END IF;

  IF NOT public.competition_challenge_window_open(
    v_c.season_id, v_c.window_phase, v_c.gpsl_month_to
  ) THEN
    RETURN false;
  END IF;

  v_amount := v_c.prize_amount;

  PERFORM public.post_club_ledger(
    p_club_short_name,
    'prize_challenge',
    v_amount,
    format('Challenge — %s', v_c.title),
    jsonb_build_object(
      'challenge_id', v_c.id,
      'window_phase', v_c.window_phase,
      'stat_type', v_c.stat_type,
      'target_value', v_c.target_value,
      'stat_value', p_stat_value
    ),
    v_c.season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.competition_challenge_awarded (
    season_id, challenge_id, club_short_name, amount, stat_value, metadata
  )
  VALUES (
    v_c.season_id,
    p_challenge_id,
    p_club_short_name,
    v_amount,
    p_stat_value,
    jsonb_build_object('title', v_c.title)
  );

  RETURN true;
END;
$function$;

-- Patch league prize loop (pay_league_division_prizes body uses credit+insert)
CREATE OR REPLACE FUNCTION public.competition_pay_league_division_prizes(
  p_season_id bigint,
  p_division text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_amount numeric;
  v_div_label text;
  v_paid int := 0;
BEGIN
  IF p_season_id IS NULL OR p_division IS NULL THEN
    RETURN 0;
  END IF;

  IF NOT public.competition_division_league_complete(p_season_id, p_division) THEN
    RETURN 0;
  END IF;

  v_div_label := CASE p_division
    WHEN 'superleague' THEN 'SuperLeague'
    WHEN 'championship_a' THEN 'Championship A'
    WHEN 'championship_b' THEN 'Championship B'
    ELSE p_division
  END;

  FOR v_row IN
    SELECT
      s.club_short_name,
      s.table_position,
      s.club_name
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id
      AND s.division = p_division
    ORDER BY s.table_position
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_league_prize_paid pp
      WHERE pp.season_id = p_season_id
        AND pp.division = p_division
        AND pp.club_short_name = v_row.club_short_name
    ) THEN
      CONTINUE;
    END IF;

    SELECT pc.amount INTO v_amount
    FROM public.competition_league_prize_config pc
    WHERE pc.season_id = p_season_id
      AND pc.division = p_division
      AND pc.position = v_row.table_position;

    IF v_amount IS NULL OR v_amount <= 0 THEN
      CONTINUE;
    END IF;

    PERFORM public.post_club_ledger(
      v_row.club_short_name,
      'prize_league',
      v_amount,
      format('%s league prize — position %s', v_div_label, v_row.table_position),
      jsonb_build_object(
        'division', p_division,
        'table_position', v_row.table_position,
        'club_name', v_row.club_name
      ),
      p_season_id,
      NULL,
      true,
      true
    );

    INSERT INTO public.competition_league_prize_paid (
      season_id, division, club_short_name, table_position, amount
    )
    VALUES (p_season_id, p_division, v_row.club_short_name, v_row.table_position, v_amount);

    v_paid := v_paid + 1;
  END LOOP;

  RETURN v_paid;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Stadium expansion → central bank (payment + refunds)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.stadium_expansion_place_order(p_quote_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_quote public.stadium_expansion_quotes;
  v_base int;
  v_current int;
  v_max int;
  v_balance numeric;
  v_order_id bigint;
  v_ledger_id bigint;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.stadium_expansion_orders o
    WHERE o.club_short_name = v_club AND o.season_id_ordered = v_season_id
  ) THEN
    RAISE EXCEPTION 'Only one stadium expansion order per season';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.stadium_expansion_orders o
    WHERE o.club_short_name = v_club
      AND o.status IN ('pre_build', 'awaiting_goahead', 'building')
  ) THEN
    RAISE EXCEPTION 'An expansion is already in progress';
  END IF;

  SELECT * INTO v_quote
  FROM public.stadium_expansion_quotes q
  WHERE q.id = p_quote_id
    AND q.club_short_name = v_club
    AND q.consumed_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Quote not found or already used';
  END IF;

  PERFORM public.stadium_expansion_sync_progress(v_club);

  SELECT coalesce(c."Capacity", 0)::int, coalesce(c.base_capacity, c."Capacity", 0)::int
  INTO v_current, v_base
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_max := public.stadium_max_capacity(v_base);

  IF v_quote.seats > public.stadium_expansion_headroom(v_club) THEN
    RAISE EXCEPTION 'Quote is no longer valid — capacity headroom changed';
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club finances not found';
  END IF;

  IF v_balance < v_quote.total_cost THEN
    RAISE EXCEPTION 'Insufficient balance (need %, have %)',
      v_quote.total_cost, v_balance;
  END IF;

  v_ledger_id := public.post_club_ledger(
    v_club,
    'infra_expansion',
    -v_quote.total_cost,
    format('Stadium expansion — %s seats ordered', v_quote.seats),
    jsonb_build_object('quote_id', p_quote_id, 'seats', v_quote.seats),
    v_season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.stadium_expansion_orders (
    club_short_name,
    season_id_ordered,
    quote_id,
    seats_ordered,
    total_cost_paid,
    cost_per_seat,
    capacity_at_order,
    base_capacity_at_order,
    max_capacity_at_order,
    status,
    ledger_payment_id
  )
  VALUES (
    v_club,
    v_season_id,
    p_quote_id,
    v_quote.seats,
    v_quote.total_cost,
    v_quote.cost_per_seat,
    v_current,
    v_base,
    v_max,
    'pre_build',
    v_ledger_id
  )
  RETURNING id INTO v_order_id;

  UPDATE public.stadium_expansion_quotes
  SET consumed_at = now(), consumed_order_id = v_order_id
  WHERE id = p_quote_id;

  RETURN v_order_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.stadium_expansion_pre_build_cancel(p_order_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_row public.stadium_expansion_orders;
BEGIN
  v_club := public.my_club_shortname();

  SELECT * INTO v_row
  FROM public.stadium_expansion_orders o
  WHERE o.id = p_order_id AND o.club_short_name = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_row.status NOT IN ('pre_build', 'awaiting_goahead') THEN
    RAISE EXCEPTION 'Cannot cancel at this stage';
  END IF;

  IF public.stadium_expansion_pre_build_day(v_row.ordered_at) >= 7 THEN
    RAISE EXCEPTION 'Use day-7 cancel (penalty applies) instead';
  END IF;

  PERFORM public.post_club_ledger(
    v_club,
    'infra_expansion_refund',
    v_row.total_cost_paid,
    format('Stadium expansion cancelled — full refund (%s seats)', v_row.seats_ordered),
    jsonb_build_object('order_id', p_order_id),
    v_row.season_id_ordered,
    NULL,
    true,
    true
  );

  UPDATE public.stadium_expansion_orders
  SET status = 'cancelled', cancelled_at = now()
  WHERE id = p_order_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.stadium_expansion_day7_decision(
  p_order_id bigint,
  p_continue boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_row public.stadium_expansion_orders;
  v_penalty numeric;
  v_refund numeric;
BEGIN
  v_club := public.my_club_shortname();

  PERFORM public.stadium_expansion_sync_progress(v_club);

  SELECT * INTO v_row
  FROM public.stadium_expansion_orders o
  WHERE o.id = p_order_id AND o.club_short_name = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_row.status <> 'awaiting_goahead' THEN
    RAISE EXCEPTION 'Not awaiting day-7 decision (status %)', v_row.status;
  END IF;

  IF now() >= public.stadium_expansion_day7_deadline_uk(v_row.ordered_at) THEN
    RAISE EXCEPTION 'Day-7 decision window has closed';
  END IF;

  IF p_continue THEN
    UPDATE public.stadium_expansion_orders
    SET
      status = 'building',
      build_started_at = now(),
      goahead_decision = 'continue'
    WHERE id = p_order_id;
    RETURN;
  END IF;

  SELECT coalesce(stadium_expansion_cancel_penalty, 1000000)
  INTO v_penalty
  FROM public.global_settings
  WHERE id = 1;

  v_refund := greatest(v_row.total_cost_paid - v_penalty, 0);

  IF v_penalty > 0 THEN
    PERFORM public.post_club_ledger(
      v_club,
      'infra_expansion_penalty',
      -v_penalty,
      'Rapid Build Co cancellation fee',
      jsonb_build_object('order_id', p_order_id),
      v_row.season_id_ordered,
      NULL,
      true,
      true
    );
  END IF;

  IF v_refund > 0 THEN
    PERFORM public.post_club_ledger(
      v_club,
      'infra_expansion_refund',
      v_refund,
      format('Stadium expansion cancelled — partial refund (%s seats)', v_row.seats_ordered),
      jsonb_build_object('order_id', p_order_id, 'penalty', v_penalty),
      v_row.season_id_ordered,
      NULL,
      true,
      true
    );
  END IF;

  UPDATE public.stadium_expansion_orders
  SET status = 'cancelled', cancelled_at = now(), goahead_decision = 'cancel'
  WHERE id = p_order_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.stadium_expansion_cancel_build(p_order_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_row public.stadium_expansion_orders;
BEGIN
  v_club := public.my_club_shortname();

  PERFORM public.stadium_expansion_sync_progress(v_club);

  SELECT * INTO v_row
  FROM public.stadium_expansion_orders o
  WHERE o.id = p_order_id AND o.club_short_name = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_row.status <> 'building' THEN
    RAISE EXCEPTION 'Build is not active';
  END IF;

  IF v_row.seats_delivered > 0 OR v_row.build_weeks_applied > 0 THEN
    RAISE EXCEPTION 'Cannot cancel after the first build week has completed';
  END IF;

  PERFORM public.post_club_ledger(
    v_club,
    'infra_expansion_refund',
    v_row.total_cost_paid,
    format('Stadium build cancelled — full refund (%s seats)', v_row.seats_ordered),
    jsonb_build_object('order_id', p_order_id),
    v_row.season_id_ordered,
    NULL,
    true,
    true
  );

  UPDATE public.stadium_expansion_orders
  SET status = 'cancelled', cancelled_at = now()
  WHERE id = p_order_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_try_award_period_bonus(
  p_season_id bigint,
  p_club_short_name text,
  p_window_phase text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_total int;
  v_done int;
  v_bonus numeric;
  v_deadline text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.competition_challenge_period_bonus_awarded
    WHERE season_id = p_season_id
      AND window_phase = p_window_phase
  ) THEN
    RETURN false;
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.competition_challenge_config
  WHERE season_id = p_season_id
    AND window_phase = p_window_phase
    AND is_active = true;

  IF v_total = 0 THEN
    RETURN false;
  END IF;

  SELECT count(*)::int INTO v_done
  FROM public.competition_challenge_awarded a
  JOIN public.competition_challenge_config c ON c.id = a.challenge_id
  WHERE a.season_id = p_season_id
    AND a.club_short_name = p_club_short_name
    AND c.window_phase = p_window_phase
    AND c.is_active = true;

  IF v_done < v_total THEN
    RETURN false;
  END IF;

  SELECT max(c.gpsl_month_to) INTO v_deadline
  FROM public.competition_challenge_config c
  WHERE c.season_id = p_season_id
    AND c.window_phase = p_window_phase
    AND c.is_active = true;

  IF NOT public.competition_challenge_window_open(p_season_id, p_window_phase, v_deadline) THEN
    RETURN false;
  END IF;

  v_bonus := (SELECT challenge_period_bonus FROM public.global_settings WHERE id = 1);

  IF v_bonus IS NULL OR v_bonus <= 0 THEN
    RETURN false;
  END IF;

  PERFORM public.post_club_ledger(
    p_club_short_name,
    'prize_challenge',
    v_bonus,
    format('Challenge bonus — first to complete all %s targets', p_window_phase),
    jsonb_build_object(
      'window_phase', p_window_phase,
      'bonus', true,
      'challenges_completed', v_done
    ),
    p_season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.competition_challenge_period_bonus_awarded (
    season_id, window_phase, club_short_name, amount
  )
  VALUES (p_season_id, p_window_phase, p_club_short_name, v_bonus);

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- EOS: 0.5% interest on positive club balances (paid by central bank)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_eos_balance_interest(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_interest numeric;
  v_paid int := 0;
  v_rate constant numeric := 0.005;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  FOR v_club IN
    SELECT f.club_name AS club_short_name, f.balance
    FROM public."Club_Finances" f
    WHERE f.balance > 0
      AND f.club_name <> 'FOREIGN'
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = p_season_id
        AND club_short_name = v_club.club_short_name
        AND charge_type = 'eos_balance_interest'
    ) THEN
      CONTINUE;
    END IF;

    v_interest := round(v_club.balance * v_rate, 0);
    IF v_interest <= 0 THEN
      CONTINUE;
    END IF;

    PERFORM public.post_club_ledger(
      v_club.club_short_name,
      'eos_balance_interest',
      v_interest,
      format(
        'End of season balance interest — 0.5%% on ₿%s',
        to_char(v_club.balance, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'balance_snapshot', v_club.balance,
        'rate_pct', v_rate * 100
      ),
      p_season_id,
      NULL,
      true,
      true
    );

    INSERT INTO public.competition_season_charge_paid (
      season_id, club_short_name, charge_type, amount, metadata
    )
    VALUES (
      p_season_id,
      v_club.club_short_name,
      'eos_balance_interest',
      v_interest,
      jsonb_build_object('balance_snapshot', v_club.balance)
    );

    v_paid := v_paid + 1;
  END LOOP;

  RETURN v_paid;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Backfill: mirror existing club ledger rows to bank_ledger (no balance change)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.backfill_central_bank_legs(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_count int := 0;
  v_reserves_delta numeric := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_row IN
    SELECT l.*
    FROM public.competition_finance_ledger l
    WHERE (
      public.finance_entry_via_central_bank(l.entry_type)
      OR (
        l.entry_type = 'transfer_purchase'
        AND (
          coalesce(l.metadata->>'manager_draft', '') = 'true'
          OR EXISTS (
            SELECT 1
            FROM public."Transfer_History" h
            WHERE h.id = (l.metadata->>'transfer_history_id')::bigint
              AND (h.seller_club_id IS NULL OR btrim(h.seller_club_id::text) = '')
          )
        )
      )
      OR (
        l.entry_type = 'infra_expansion_refund'
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = l.id
    )
    ORDER BY l.id
  LOOP
    v_count := v_count + 1;
    v_reserves_delta := v_reserves_delta - v_row.amount;

    IF NOT p_dry_run THEN
      UPDATE public.gpsl_bank_account
      SET reserves = reserves - v_row.amount,
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
        v_row.entry_type,
        -v_row.amount,
        v_row.description,
        v_row.club_short_name,
        v_row.id,
        coalesce(v_row.metadata, '{}'::jsonb) || jsonb_build_object('backfill', true)
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run', p_dry_run,
    'rows_mirrored', v_count,
    'reserves_delta', v_reserves_delta
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.backfill_central_bank_legs(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_eos_balance_interest(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finance_entry_via_central_bank(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
