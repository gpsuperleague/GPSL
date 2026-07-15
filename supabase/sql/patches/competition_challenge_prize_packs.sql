-- =============================================================================
-- Challenge period bonus prize packs
--
-- Non-cash prizes for first club to complete all Start / Mid challenges:
--   • medical_token   — reduce injury by 2/4/6/8/10 matches (needs doctor)
--   • fee_discount    — % off fee paid (seller still gets full; bank tops up)
--   • appeal_card     — request red-card suspension overturn (admin review)
--
-- Run after competition_challenges.sql + competition_challenges_june_transfers.sql
-- + club_medical_room.sql + central_bank_model_a_flows.sql.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Ledger + inbox types (union live rows so we never shrink the lists)
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
      'prize_challenge',
      'prize_fee_discount_subsidy',
      'gate_league_home', 'gate_cup_share', 'prize', 'prize_league', 'prize_cup',
      'tv_revenue', 'gov_hg_subsidy', 'gov_youth_subsidy', 'gov_bnb_subsidy',
      'gov_fine_compensation', 'gov_emergency_tax', 'gov_income_tax',
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'adjustment',
      'admin_one_off_injection', 'admin_purchase_payment',
      'transfer_sale', 'transfer_purchase', 'transfer_agent_fee',
      'transfer_foreign_sale', 'transfer_overflow_release',
      'loan_drawdown', 'loan_repayment_principal', 'loan_interest_payment',
      'infra_maintenance', 'infra_purchase', 'infra_expansion',
      'infra_expansion_refund', 'infra_expansion_penalty',
      'contract_release_comp', 'contract_release_comp_received',
      'contract_termination', 'contract_signing_offer',
      'staff_manager_salary', 'eos_debt_interest', 'eos_ffp_charge',
      'eos_balance_interest', 'eos_injection',
      'special_auction_fee', 'special_auction_prize',
      'season_loan_fee', 'season_loan_refund',
      'new_owner_release', 'voluntary_contract_release',
      'medical_physio_hire', 'medical_doctor_hire'
    ])
  ) s;

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

DO $inbox_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'welcome_gpsl', 'result_submitted', 'result_to_confirm', 'result_rejected',
      'result_confirmed', 'transfer_signed', 'transfer_sold', 'transfer_upcoming',
      'underperformance_transfer', 'draft_scheduled', 'special_auction_scheduled',
      'fine_applied', 'loan_drawdown', 'loan_repayment', 'loan_interest',
      'points_deduction', 'nation_pick_turn', 'nation_selection_open',
      'season_expectations', 'season_overview', 'player_awards', 'monthly_fixtures',
      'match_time_proposed', 'match_time_countered', 'match_time_proposal_sent',
      'match_time_counter_sent', 'match_time_accepted', 'match_rescheduled',
      'match_emergency_drop', 'match_forfeit_applied', 'match_checkin_open',
      'match_mutual_override_requested', 'match_mutual_override_applied',
      'challenge_period_bonus', 'prize_appeal_submitted', 'prize_appeal_resolved'
    ])
  ) s;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

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
    'special_auction_prize'
  ]);
$$;

-- ---------------------------------------------------------------------------
-- Pack config (separate Start / Mid)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.competition_challenge_period_pack (
  window_phase text PRIMARY KEY CHECK (window_phase IN ('start', 'mid')),
  cash_amount numeric(14, 2) NOT NULL DEFAULT 0 CHECK (cash_amount >= 0),
  -- pack jsonb example:
  -- {
  --   "medical_tokens": [2, 4, 6],
  --   "fee_discounts": [10, 15],
  --   "appeal_cards": 1
  -- }
  pack jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.competition_challenge_period_pack (window_phase, cash_amount, pack)
VALUES
  ('start', coalesce((SELECT challenge_period_bonus FROM public.global_settings WHERE id = 1), 5000000),
   '{"medical_tokens":[4,6],"fee_discounts":[10],"appeal_cards":1}'::jsonb),
  ('mid', coalesce((SELECT challenge_period_bonus FROM public.global_settings WHERE id = 1), 5000000),
   '{"medical_tokens":[2,4],"fee_discounts":[5],"appeal_cards":0}'::jsonb)
ON CONFLICT (window_phase) DO NOTHING;

ALTER TABLE public.competition_challenge_period_pack ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_challenge_period_pack_select ON public.competition_challenge_period_pack;
CREATE POLICY competition_challenge_period_pack_select
  ON public.competition_challenge_period_pack FOR SELECT TO authenticated USING (true);

-- Allow cash=0 when pack has non-cash only
ALTER TABLE public.competition_challenge_period_bonus_awarded
  DROP CONSTRAINT IF EXISTS competition_challenge_period_bonus_awarded_amount_check;

ALTER TABLE public.competition_challenge_period_bonus_awarded
  ADD CONSTRAINT competition_challenge_period_bonus_awarded_amount_check
  CHECK (amount >= 0);

ALTER TABLE public.competition_challenge_period_bonus_awarded
  ADD COLUMN IF NOT EXISTS pack_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- Club prize inventory
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.club_prize_inventory (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName"),
  prize_type text NOT NULL CHECK (prize_type IN ('medical_token', 'fee_discount', 'appeal_card')),
  -- medical_token: matches to remove (2/4/6/8/10)
  -- fee_discount: percent off fee paid (e.g. 10)
  -- appeal_card: unused (NULL)
  param_int int,
  status text NOT NULL DEFAULT 'available'
    CHECK (status IN ('available', 'locked', 'consumed', 'pending_review', 'rejected')),
  source text,
  season_id bigint REFERENCES public.competition_seasons (id) ON DELETE SET NULL,
  window_phase text CHECK (window_phase IS NULL OR window_phase IN ('start', 'mid')),
  -- locked_context: { "kind": "listing"|"special_auction"|"draft_listing", "id": 123 }
  locked_context jsonb,
  consumed_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT club_prize_inventory_param_check CHECK (
    (prize_type = 'medical_token' AND param_int IN (2, 4, 6, 8, 10))
    OR (prize_type = 'fee_discount' AND param_int > 0 AND param_int <= 50)
    OR (prize_type = 'appeal_card' AND param_int IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS club_prize_inventory_club_status_idx
  ON public.club_prize_inventory (club_short_name, status, prize_type);

CREATE UNIQUE INDEX IF NOT EXISTS club_prize_inventory_one_locked_discount_idx
  ON public.club_prize_inventory (club_short_name)
  WHERE prize_type = 'fee_discount' AND status = 'locked';

ALTER TABLE public.club_prize_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_prize_inventory_select ON public.club_prize_inventory;
CREATE POLICY club_prize_inventory_select ON public.club_prize_inventory
  FOR SELECT TO authenticated
  USING (
    public.is_gpsl_admin()
    OR club_short_name = public.my_club_shortname()
  );

-- ---------------------------------------------------------------------------
-- Suspension appeals (admin review — DOGSO-safe)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.competition_suspension_appeals (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  season_id bigint REFERENCES public.competition_seasons (id) ON DELETE SET NULL,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName"),
  suspension_id bigint NOT NULL REFERENCES public.competition_player_suspensions (id) ON DELETE CASCADE,
  inventory_id bigint NOT NULL REFERENCES public.club_prize_inventory (id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected')),
  owner_note text,
  admin_note text,
  reviewed_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT competition_suspension_appeals_one_pending UNIQUE (suspension_id, status)
    DEFERRABLE INITIALLY IMMEDIATE
);

-- Unique pending per suspension (partial index is cleaner than deferrable unique with status)
DROP INDEX IF EXISTS competition_suspension_appeals_pending_uidx;
CREATE UNIQUE INDEX competition_suspension_appeals_pending_uidx
  ON public.competition_suspension_appeals (suspension_id)
  WHERE status = 'pending';

ALTER TABLE public.competition_suspension_appeals
  DROP CONSTRAINT IF EXISTS competition_suspension_appeals_one_pending;

ALTER TABLE public.competition_suspension_appeals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_suspension_appeals_select ON public.competition_suspension_appeals;
CREATE POLICY competition_suspension_appeals_select ON public.competition_suspension_appeals
  FOR SELECT TO authenticated
  USING (
    public.is_gpsl_admin()
    OR club_short_name = public.my_club_shortname()
  );

-- ---------------------------------------------------------------------------
-- Helpers: grant inventory items
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.prize_grant_inventory_item(
  p_club text,
  p_prize_type text,
  p_param_int int,
  p_source text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_window_phase text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_club text := btrim(p_club);
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  INSERT INTO public.club_prize_inventory (
    club_short_name, prize_type, param_int, source, season_id, window_phase, metadata
  )
  VALUES (
    v_club,
    p_prize_type,
    CASE WHEN p_prize_type = 'appeal_card' THEN NULL ELSE p_param_int END,
    p_source,
    p_season_id,
    p_window_phase,
    coalesce(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.prize_grant_period_pack(
  p_club text,
  p_window_phase text,
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pack public.competition_challenge_period_pack%rowtype;
  v_med int;
  v_disc int;
  v_appeals int := 0;
  v_granted jsonb := '[]'::jsonb;
  v_id bigint;
  v_i int;
BEGIN
  SELECT * INTO v_pack
  FROM public.competition_challenge_period_pack
  WHERE window_phase = p_window_phase;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('granted', '[]'::jsonb, 'cash_amount', 0);
  END IF;

  FOR v_med IN
    SELECT jsonb_array_elements_text(coalesce(v_pack.pack->'medical_tokens', '[]'::jsonb))::int
  LOOP
    IF v_med IN (2, 4, 6, 8, 10) THEN
      v_id := public.prize_grant_inventory_item(
        p_club, 'medical_token', v_med,
        'challenge_period_bonus', p_season_id, p_window_phase,
        jsonb_build_object('matches_removed', v_med)
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('id', v_id, 'type', 'medical_token', 'param', v_med)
      );
    END IF;
  END LOOP;

  FOR v_disc IN
    SELECT jsonb_array_elements_text(coalesce(v_pack.pack->'fee_discounts', '[]'::jsonb))::int
  LOOP
    IF v_disc > 0 AND v_disc <= 50 THEN
      v_id := public.prize_grant_inventory_item(
        p_club, 'fee_discount', v_disc,
        'challenge_period_bonus', p_season_id, p_window_phase,
        jsonb_build_object('discount_pct', v_disc)
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('id', v_id, 'type', 'fee_discount', 'param', v_disc)
      );
    END IF;
  END LOOP;

  v_appeals := coalesce((v_pack.pack->>'appeal_cards')::int, 0);
  FOR v_i IN 1..greatest(v_appeals, 0) LOOP
    v_id := public.prize_grant_inventory_item(
      p_club, 'appeal_card', NULL,
      'challenge_period_bonus', p_season_id, p_window_phase,
      '{}'::jsonb
    );
    v_granted := v_granted || jsonb_build_array(
      jsonb_build_object('id', v_id, 'type', 'appeal_card', 'param', NULL)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'cash_amount', coalesce(v_pack.cash_amount, 0),
    'pack', v_pack.pack,
    'granted', v_granted
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Period bonus award (cash + pack)
-- ---------------------------------------------------------------------------

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
  v_deadline text;
  v_grant jsonb;
  v_cash numeric;
  v_fallback numeric;
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

  v_grant := public.prize_grant_period_pack(p_club_short_name, p_window_phase, p_season_id);
  v_cash := coalesce((v_grant->>'cash_amount')::numeric, 0);

  -- Fallback to legacy global setting if pack cash is 0 and pack empty
  IF v_cash <= 0 AND jsonb_array_length(coalesce(v_grant->'granted', '[]'::jsonb)) = 0 THEN
    v_fallback := (SELECT challenge_period_bonus FROM public.global_settings WHERE id = 1);
    IF v_fallback IS NULL OR v_fallback <= 0 THEN
      RETURN false;
    END IF;
    v_cash := v_fallback;
  END IF;

  IF v_cash > 0 THEN
    PERFORM public.post_club_ledger(
      p_club_short_name,
      'prize_challenge',
      v_cash,
      format('Challenge bonus — first to complete all %s targets', p_window_phase),
      jsonb_build_object(
        'window_phase', p_window_phase,
        'bonus', true,
        'challenges_completed', v_done,
        'pack', v_grant->'pack'
      ),
      p_season_id,
      NULL,
      true,
      true
    );
  END IF;

  INSERT INTO public.competition_challenge_period_bonus_awarded (
    season_id, window_phase, club_short_name, amount, pack_snapshot
  )
  VALUES (
    p_season_id,
    p_window_phase,
    p_club_short_name,
    coalesce(v_cash, 0),
    coalesce(v_grant, '{}'::jsonb)
  );

  PERFORM public.owner_inbox_send(
    'challenge_period_bonus',
    format('Challenge period bonus — %s window', p_window_phase),
    format(
      'You were first to complete all %s challenges.%s%s',
      p_window_phase,
      CASE WHEN v_cash > 0 THEN format(E'\nCash: ₿%s', to_char(v_cash, 'FM999,999,999,999')) ELSE '' END,
      CASE
        WHEN jsonb_array_length(coalesce(v_grant->'granted', '[]'::jsonb)) > 0
        THEN E'\nPrize items were added to Club prizes.'
        ELSE ''
      END
    ),
    p_club_short_name,
    NULL, NULL, NULL, NULL, NULL,
    'club_prizes.html',
    format('challenge_period_bonus:%s:%s:%s', p_season_id, p_window_phase, p_club_short_name),
    NULL,
    p_season_id
  );

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin pack settings
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_update_challenge_period_packs(p_packs jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_phase text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_packs IS NULL OR jsonb_typeof(p_packs) <> 'array' THEN
    RAISE EXCEPTION 'packs must be a JSON array';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_packs)
  LOOP
    v_phase := v_row->>'window_phase';
    IF v_phase NOT IN ('start', 'mid') THEN
      RAISE EXCEPTION 'Invalid window_phase';
    END IF;

    INSERT INTO public.competition_challenge_period_pack (window_phase, cash_amount, pack, updated_at)
    VALUES (
      v_phase,
      coalesce((v_row->>'cash_amount')::numeric, 0),
      coalesce(v_row->'pack', '{}'::jsonb),
      now()
    )
    ON CONFLICT (window_phase) DO UPDATE
    SET
      cash_amount = excluded.cash_amount,
      pack = excluded.pack,
      updated_at = now();
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_challenge_settings(p_settings jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.global_settings
  SET
    challenge_default_prize = coalesce(
      (p_settings->>'challenge_default_prize')::numeric,
      challenge_default_prize
    ),
    challenge_period_bonus = coalesce(
      (p_settings->>'challenge_period_bonus')::numeric,
      challenge_period_bonus
    ),
    updated_at = now()
  WHERE id = 1;

  -- Optional nested packs: { packs: [ {window_phase, cash_amount, pack}, ... ] }
  IF p_settings ? 'packs' THEN
    PERFORM public.admin_update_challenge_period_packs(p_settings->'packs');
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Owner: list inventory
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_prize_inventory_state(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_items jsonb;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club';
  END IF;
  IF NOT public.is_gpsl_admin() AND v_club IS DISTINCT FROM public.my_club_shortname() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM public.club_prize_inventory i
  WHERE i.club_short_name = v_club
    AND i.status IN ('available', 'locked', 'pending_review');

  RETURN jsonb_build_object('club_short_name', v_club, 'items', v_items);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fee discount: lock one at a time
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.prize_lock_fee_discount(
  p_inventory_id bigint,
  p_context_kind text,
  p_context_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_row public.club_prize_inventory%rowtype;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked'; END IF;
  IF p_context_kind NOT IN ('listing', 'special_auction', 'draft_listing') THEN
    RAISE EXCEPTION 'Invalid context kind';
  END IF;
  IF p_context_id IS NULL THEN
    RAISE EXCEPTION 'Context id required';
  END IF;

  -- Unlock any existing lock for this club
  UPDATE public.club_prize_inventory
  SET status = 'available',
      locked_context = NULL,
      updated_at = now()
  WHERE club_short_name = v_club
    AND prize_type = 'fee_discount'
    AND status = 'locked';

  SELECT * INTO v_row
  FROM public.club_prize_inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  IF NOT FOUND OR v_row.club_short_name IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Discount token not found';
  END IF;
  IF v_row.prize_type <> 'fee_discount' OR v_row.status <> 'available' THEN
    RAISE EXCEPTION 'Token not available';
  END IF;

  UPDATE public.club_prize_inventory
  SET status = 'locked',
      locked_context = jsonb_build_object(
        'kind', p_context_kind,
        'id', p_context_id
      ),
      updated_at = now()
  WHERE id = p_inventory_id;

  RETURN jsonb_build_object(
    'ok', true,
    'inventory_id', p_inventory_id,
    'discount_pct', v_row.param_int,
    'context_kind', p_context_kind,
    'context_id', p_context_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.prize_unlock_fee_discount(p_inventory_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_n int;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked'; END IF;

  UPDATE public.club_prize_inventory
  SET status = 'available',
      locked_context = NULL,
      updated_at = now()
  WHERE club_short_name = v_club
    AND prize_type = 'fee_discount'
    AND status = 'locked'
    AND (p_inventory_id IS NULL OR id = p_inventory_id);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'unlocked', v_n);
END;
$function$;

CREATE OR REPLACE FUNCTION public.prize_find_locked_fee_discount(
  p_club text,
  p_context_kind text,
  p_context_id bigint
)
RETURNS public.club_prize_inventory
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.club_prize_inventory%rowtype;
BEGIN
  SELECT * INTO v_row
  FROM public.club_prize_inventory
  WHERE club_short_name = p_club
    AND prize_type = 'fee_discount'
    AND status = 'locked'
    AND locked_context->>'kind' = p_context_kind
    AND (locked_context->>'id')::bigint = p_context_id
  LIMIT 1;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.prize_apply_fee_discount_settlement(
  p_club text,
  p_context_kind text,
  p_context_id bigint,
  p_full_fee numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.club_prize_inventory%rowtype;
  v_pct int;
  v_full numeric := abs(coalesce(p_full_fee, 0));
  v_club_pays numeric;
  v_gap numeric;
BEGIN
  IF v_full <= 0 OR p_club IS NULL THEN
    RETURN jsonb_build_object(
      'applied', false,
      'club_pays', v_full,
      'bank_gap', 0,
      'discount_pct', 0
    );
  END IF;

  v_row := public.prize_find_locked_fee_discount(p_club, p_context_kind, p_context_id);
  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object(
      'applied', false,
      'club_pays', v_full,
      'bank_gap', 0,
      'discount_pct', 0
    );
  END IF;

  v_pct := coalesce(v_row.param_int, 0);
  v_club_pays := round(v_full * (1 - v_pct / 100.0), 2);
  v_gap := round(v_full - v_club_pays, 2);

  UPDATE public.club_prize_inventory
  SET status = 'consumed',
      consumed_at = now(),
      updated_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'consumed_fee', v_full,
        'club_pays', v_club_pays,
        'bank_gap', v_gap
      )
  WHERE id = v_row.id;

  RETURN jsonb_build_object(
    'applied', true,
    'inventory_id', v_row.id,
    'discount_pct', v_pct,
    'club_pays', v_club_pays,
    'bank_gap', v_gap,
    'full_fee', v_full
  );
END;
$function$;

-- Unlock locked discounts that never applied (e.g. lost auction)
CREATE OR REPLACE FUNCTION public.prize_release_locked_discounts_for_context(
  p_context_kind text,
  p_context_id bigint,
  p_except_club text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
BEGIN
  UPDATE public.club_prize_inventory
  SET status = 'available',
      locked_context = NULL,
      updated_at = now()
  WHERE prize_type = 'fee_discount'
    AND status = 'locked'
    AND locked_context->>'kind' = p_context_kind
    AND (locked_context->>'id')::bigint = p_context_id
    AND (p_except_club IS NULL OR club_short_name IS DISTINCT FROM p_except_club);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;
