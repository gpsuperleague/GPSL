-- =============================================================================
-- Bookies → owner wallet + GPFL cash prizes → owner wallet
--
-- Prerequisites: owners_shop_wallet_catalogue_20260822.sql (_post_owner_ledger_internal)
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Bookies: debit/credit owner_wallets (keep club on bet row for context)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bookies_place_bet(
  p_selection_id bigint,
  p_stake numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_sel public.bookies_selections%rowtype;
  v_mkt public.bookies_markets%rowtype;
  v_stake numeric := round(coalesce(p_stake, 0)::numeric, 2);
  v_bet_id bigint;
  v_ledger bigint;
  v_ret numeric;
  v_desc text;
  v_frac text;
  v_bal numeric(14, 2);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF v_stake IS NULL OR v_stake <= 0 THEN
    RAISE EXCEPTION 'Stake must be greater than zero';
  END IF;
  IF v_stake > 1000 THEN
    RAISE EXCEPTION 'Maximum stake is ₿1,000 per bet';
  END IF;

  SELECT * INTO v_sel FROM public.bookies_selections WHERE id = p_selection_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Selection not found';
  END IF;

  SELECT * INTO v_mkt FROM public.bookies_markets WHERE id = v_sel.market_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Market not found';
  END IF;

  IF v_mkt.status <> 'open' THEN
    RAISE EXCEPTION 'Market is not open for betting';
  END IF;
  IF v_mkt.closes_at IS NOT NULL AND v_mkt.closes_at <= now() THEN
    RAISE EXCEPTION 'Market betting window has closed';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bookies_bets b
    WHERE b.owner_id = v_uid
      AND b.market_id = v_mkt.id
      AND b.status IS DISTINCT FROM 'void'
  ) THEN
    RAISE EXCEPTION 'You already have a bet on this market (one bet per market)';
  END IF;

  PERFORM public.owner_wallet_ensure(v_uid);
  SELECT balance INTO v_bal
  FROM public.owner_wallets
  WHERE owner_id = v_uid
  FOR UPDATE;

  IF coalesce(v_bal, 0) < v_stake THEN
    RAISE EXCEPTION 'Insufficient owner balance (need %, have %)',
      v_stake, coalesce(v_bal, 0);
  END IF;

  v_ret := round(v_stake * v_sel.odds_decimal, 2);

  IF to_regprocedure('public.bookies_fractional_odds_label(numeric)') IS NOT NULL THEN
    v_frac := public.bookies_fractional_odds_label(v_sel.odds_decimal);
  ELSE
    v_frac := to_char(v_sel.odds_decimal, 'FM999999990.00');
  END IF;

  v_desc := format(
    'Bookies stake: %s — %s @ %s (stake ₿%s)',
    v_mkt.title,
    v_sel.label,
    v_frac,
    to_char(v_stake, 'FM999999990.00')
  );

  v_ledger := public._post_owner_ledger_internal(
    v_uid,
    'bookies_expenditure',
    -abs(v_stake),
    v_desc,
    jsonb_build_object(
      'bookies', true,
      'market_id', v_mkt.id,
      'selection_id', v_sel.id,
      'market_code', v_mkt.market_code,
      'odds', v_sel.odds_decimal,
      'odds_fractional', v_frac,
      'stake', v_stake,
      'club_short_name', v_club
    ),
    v_mkt.season_id
  );

  INSERT INTO public.bookies_bets (
    season_id, market_id, selection_id, owner_id, club_short_name,
    stake, odds_decimal, potential_return, status, ledger_stake_id, metadata
  )
  VALUES (
    v_mkt.season_id, v_mkt.id, v_sel.id, v_uid, v_club,
    v_stake, v_sel.odds_decimal, v_ret, 'open', v_ledger,
    jsonb_build_object(
      'selection_label', v_sel.label,
      'market_title', v_mkt.title,
      'odds_fractional', v_frac,
      'wallet', 'owner'
    )
  )
  RETURNING id INTO v_bet_id;

  IF to_regprocedure('public.bookies_apply_odds_from_weights(bigint)') IS NOT NULL THEN
    PERFORM public.bookies_apply_odds_from_weights(v_mkt.id);
  END IF;

  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = v_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'bet_id', v_bet_id,
    'stake', v_stake,
    'odds', v_sel.odds_decimal,
    'odds_fractional', v_frac,
    'potential_return', v_ret,
    'ledger_id', v_ledger,
    'owner_balance', coalesce(v_bal, 0),
    'board_moved', true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.bookies_settle_market(
  p_market_id bigint,
  p_result_selection_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mkt public.bookies_markets%rowtype;
  v_bet record;
  v_won int := 0;
  v_lost int := 0;
  v_paid numeric := 0;
  v_ledger bigint;
  v_desc text;
  v_key text := btrim(coalesce(p_result_selection_key, ''));
  v_frac text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_key = '' THEN
    RAISE EXCEPTION 'Result selection key required';
  END IF;

  SELECT * INTO v_mkt FROM public.bookies_markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Market not found';
  END IF;
  IF v_mkt.status = 'settled' THEN
    RETURN jsonb_build_object('ok', true, 'already_settled', true, 'market_id', p_market_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.bookies_selections
    WHERE market_id = p_market_id AND selection_key = v_key
  ) THEN
    RAISE EXCEPTION 'Result key % is not a selection on this market', v_key;
  END IF;

  FOR v_bet IN
    SELECT b.*, s.label AS sel_label, s.selection_key
    FROM public.bookies_bets b
    JOIN public.bookies_selections s ON s.id = b.selection_id
    WHERE b.market_id = p_market_id AND b.status = 'open'
    ORDER BY b.id
    FOR UPDATE OF b
  LOOP
    IF v_bet.selection_key = v_key THEN
      IF to_regprocedure('public.bookies_fractional_odds_label(numeric)') IS NOT NULL THEN
        v_frac := public.bookies_fractional_odds_label(v_bet.odds_decimal);
      ELSE
        v_frac := to_char(v_bet.odds_decimal, 'FM999999990.00');
      END IF;

      v_desc := format(
        'Bookies win: %s — %s @ %s (stake ₿%s, return ₿%s)',
        v_mkt.title,
        v_bet.sel_label,
        v_frac,
        to_char(v_bet.stake, 'FM999999990.00'),
        to_char(v_bet.potential_return, 'FM999999990.00')
      );
      v_ledger := public._post_owner_ledger_internal(
        v_bet.owner_id,
        'bookies_income',
        abs(v_bet.potential_return),
        v_desc,
        jsonb_build_object(
          'bookies', true,
          'bet_id', v_bet.id,
          'market_id', v_mkt.id,
          'won', true,
          'club_short_name', v_bet.club_short_name
        ),
        v_mkt.season_id
      );
      UPDATE public.bookies_bets
      SET status = 'won',
          settled_at = now(),
          ledger_payout_id = v_ledger,
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('wallet', 'owner')
      WHERE id = v_bet.id;
      v_won := v_won + 1;
      v_paid := v_paid + v_bet.potential_return;
    ELSE
      UPDATE public.bookies_bets
      SET status = 'lost', settled_at = now()
      WHERE id = v_bet.id;
      v_lost := v_lost + 1;
    END IF;
  END LOOP;

  UPDATE public.bookies_markets
  SET status = 'settled',
      result_selection_key = v_key,
      settled_at = now(),
      updated_at = now()
  WHERE id = p_market_id;

  RETURN jsonb_build_object(
    'ok', true,
    'market_id', p_market_id,
    'result', v_key,
    'won', v_won,
    'lost', v_lost,
    'paid_out', v_paid
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_place_bet(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_settle_market(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- GPFL cash prizes (owner wallet)
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpfl_settings
  ADD COLUMN IF NOT EXISTS prize_season_1 numeric(14, 2) NOT NULL DEFAULT 5000,
  ADD COLUMN IF NOT EXISTS prize_season_2 numeric(14, 2) NOT NULL DEFAULT 3000,
  ADD COLUMN IF NOT EXISTS prize_season_3 numeric(14, 2) NOT NULL DEFAULT 2000,
  ADD COLUMN IF NOT EXISTS prize_month_1 numeric(14, 2) NOT NULL DEFAULT 1000,
  ADD COLUMN IF NOT EXISTS prize_month_2 numeric(14, 2) NOT NULL DEFAULT 600,
  ADD COLUMN IF NOT EXISTS prize_month_3 numeric(14, 2) NOT NULL DEFAULT 400,
  ADD COLUMN IF NOT EXISTS cash_prizes_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.gpfl_settings.prize_season_1 IS
  'Owner-wallet ₿ for GPFL season 1st place (0 = skip).';
COMMENT ON COLUMN public.gpfl_settings.prize_month_1 IS
  'Owner-wallet ₿ for GPFL month 1st place (0 = skip).';

CREATE TABLE IF NOT EXISTS public.gpfl_prize_payouts (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  gpfl_season_id bigint NOT NULL REFERENCES public.gpfl_seasons (id) ON DELETE CASCADE,
  scope text NOT NULL CHECK (scope IN ('season', 'month')),
  gpsl_month text,
  place int NOT NULL CHECK (place BETWEEN 1 AND 3),
  owner_id uuid NOT NULL,
  entry_id bigint,
  amount numeric(14, 2) NOT NULL CHECK (amount > 0),
  owner_ledger_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  CONSTRAINT gpfl_prize_payouts_month_chk CHECK (
    (scope = 'season' AND gpsl_month IS NULL)
    OR (scope = 'month' AND gpsl_month IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS gpfl_prize_payouts_season_place_uidx
  ON public.gpfl_prize_payouts (gpfl_season_id, place)
  WHERE scope = 'season';

CREATE UNIQUE INDEX IF NOT EXISTS gpfl_prize_payouts_month_place_uidx
  ON public.gpfl_prize_payouts (gpfl_season_id, gpsl_month, place)
  WHERE scope = 'month';

ALTER TABLE public.gpfl_prize_payouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpfl_prize_payouts_select ON public.gpfl_prize_payouts;
CREATE POLICY gpfl_prize_payouts_select ON public.gpfl_prize_payouts
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR public.is_gpsl_admin());

CREATE OR REPLACE FUNCTION public.admin_gpfl_pay_season_prizes(
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_cfg public.gpfl_settings%rowtype;
  v_paid int := 0;
  v_skipped int := 0;
  v_total numeric := 0;
  r record;
  v_amt numeric(14, 2);
  v_ledger bigint;
  v_amounts numeric[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RAISE EXCEPTION 'No GPFL season';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.cash_prizes_enabled, true) THEN
    RAISE EXCEPTION 'GPFL cash prizes disabled in settings';
  END IF;

  v_amounts := ARRAY[
    coalesce(v_cfg.prize_season_1, 0),
    coalesce(v_cfg.prize_season_2, 0),
    coalesce(v_cfg.prize_season_3, 0)
  ];

  FOR r IN
    SELECT
      row_number() OVER (ORDER BY e.total_points DESC, e.joined_at)::int AS place,
      e.id AS entry_id,
      e.owner_id,
      e.team_name,
      e.total_points
    FROM public.gpfl_entries e
    WHERE e.gpfl_season_id = v_gs_id
      AND e.status IN ('active', 'building')
    ORDER BY e.total_points DESC, e.joined_at
    LIMIT 3
  LOOP
    v_amt := round(coalesce(v_amounts[r.place], 0)::numeric, 2);
    IF v_amt <= 0 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.gpfl_prize_payouts p
      WHERE p.gpfl_season_id = v_gs_id AND p.scope = 'season' AND p.place = r.place
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_ledger := public._post_owner_ledger_internal(
      r.owner_id,
      'gpfl_prize',
      v_amt,
      format('GPFL season prize — %s place (%s, %s pts)',
        CASE r.place WHEN 1 THEN '1st' WHEN 2 THEN '2nd' ELSE '3rd' END,
        coalesce(r.team_name, 'entry'),
        to_char(r.total_points, 'FM999990.0')),
      jsonb_build_object(
        'source', 'gpfl_season_prize',
        'gpfl_season_id', v_gs_id,
        'place', r.place,
        'entry_id', r.entry_id
      )
    );

    INSERT INTO public.gpfl_prize_payouts (
      gpfl_season_id, scope, gpsl_month, place, owner_id, entry_id,
      amount, owner_ledger_id, created_by
    )
    VALUES (
      v_gs_id, 'season', NULL, r.place, r.owner_id, r.entry_id,
      v_amt, v_ledger, auth.uid()
    );

    v_paid := v_paid + 1;
    v_total := v_total + v_amt;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'scope', 'season',
    'gpfl_season_id', v_gs_id,
    'paid', v_paid,
    'skipped', v_skipped,
    'total_amount', v_total
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpfl_pay_month_prizes(
  p_gpsl_month text,
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_cfg public.gpfl_settings%rowtype;
  v_paid int := 0;
  v_skipped int := 0;
  v_total numeric := 0;
  r record;
  v_amt numeric(14, 2);
  v_ledger bigint;
  v_amounts numeric[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_month = '' THEN
    RAISE EXCEPTION 'gpsl_month required';
  END IF;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RAISE EXCEPTION 'No GPFL season';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.cash_prizes_enabled, true) THEN
    RAISE EXCEPTION 'GPFL cash prizes disabled in settings';
  END IF;

  v_amounts := ARRAY[
    coalesce(v_cfg.prize_month_1, 0),
    coalesce(v_cfg.prize_month_2, 0),
    coalesce(v_cfg.prize_month_3, 0)
  ];

  FOR r IN
    SELECT
      row_number() OVER (ORDER BY mp.points DESC, e.joined_at)::int AS place,
      e.id AS entry_id,
      e.owner_id,
      e.team_name,
      mp.points
    FROM public.gpfl_entry_month_points mp
    JOIN public.gpfl_entries e ON e.id = mp.entry_id
    WHERE e.gpfl_season_id = v_gs_id
      AND lower(mp.gpsl_month) = v_month
      AND e.status IN ('active', 'building')
    ORDER BY mp.points DESC, e.joined_at
    LIMIT 3
  LOOP
    v_amt := round(coalesce(v_amounts[r.place], 0)::numeric, 2);
    IF v_amt <= 0 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.gpfl_prize_payouts p
      WHERE p.gpfl_season_id = v_gs_id
        AND p.scope = 'month'
        AND p.gpsl_month = v_month
        AND p.place = r.place
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_ledger := public._post_owner_ledger_internal(
      r.owner_id,
      'gpfl_prize',
      v_amt,
      format('GPFL %s month prize — %s place (%s, %s pts)',
        v_month,
        CASE r.place WHEN 1 THEN '1st' WHEN 2 THEN '2nd' ELSE '3rd' END,
        coalesce(r.team_name, 'entry'),
        to_char(r.points, 'FM999990.0')),
      jsonb_build_object(
        'source', 'gpfl_month_prize',
        'gpfl_season_id', v_gs_id,
        'gpsl_month', v_month,
        'place', r.place,
        'entry_id', r.entry_id
      )
    );

    INSERT INTO public.gpfl_prize_payouts (
      gpfl_season_id, scope, gpsl_month, place, owner_id, entry_id,
      amount, owner_ledger_id, created_by
    )
    VALUES (
      v_gs_id, 'month', v_month, r.place, r.owner_id, r.entry_id,
      v_amt, v_ledger, auth.uid()
    );

    v_paid := v_paid + 1;
    v_total := v_total + v_amt;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'scope', 'month',
    'gpsl_month', v_month,
    'gpfl_season_id', v_gs_id,
    'paid', v_paid,
    'skipped', v_skipped,
    'total_amount', v_total
  );
END;
$function$;

-- Extend admin_gpfl_settings_set with prize fields (keeps existing knobs)
CREATE OR REPLACE FUNCTION public.admin_gpfl_settings_set(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_div text[];
  v_ctypes text[];
  v_old_budget numeric;
  v_new_budget numeric;
  v_mode text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  SELECT budget INTO v_old_budget FROM public.gpfl_settings WHERE id = 1;

  IF p_settings ? 'divisions' AND jsonb_typeof(p_settings->'divisions') = 'array' THEN
    SELECT array_agg(x) INTO v_div
    FROM jsonb_array_elements_text(p_settings->'divisions') t(x);
  END IF;
  IF p_settings ? 'competition_types' AND jsonb_typeof(p_settings->'competition_types') = 'array' THEN
    SELECT array_agg(x) INTO v_ctypes
    FROM jsonb_array_elements_text(p_settings->'competition_types') t(x);
  END IF;

  v_mode := lower(btrim(coalesce(p_settings->>'deadline_mode', '')));
  IF v_mode NOT IN ('month_unlock', 'none') THEN
    v_mode := NULL;
  END IF;

  UPDATE public.gpfl_settings SET
    enabled = coalesce((p_settings->>'enabled')::boolean, enabled),
    opt_in_only = coalesce((p_settings->>'opt_in_only')::boolean, opt_in_only),
    budget = greatest(1000000, coalesce((p_settings->>'budget')::numeric, budget)),
    squad_size = greatest(11, least(20, coalesce((p_settings->>'squad_size')::int, squad_size))),
    starters = greatest(11, least(11, coalesce((p_settings->>'starters')::int, starters))),
    max_per_club = greatest(1, least(5, coalesce((p_settings->>'max_per_club')::int, max_per_club))),
    slot_gk = greatest(1, least(3, coalesce((p_settings->>'slot_gk')::int, slot_gk))),
    slot_def = greatest(3, least(6, coalesce((p_settings->>'slot_def')::int, slot_def))),
    slot_mid = greatest(3, least(6, coalesce((p_settings->>'slot_mid')::int, slot_mid))),
    slot_fwd = greatest(1, least(4, coalesce((p_settings->>'slot_fwd')::int, slot_fwd))),
    price_round_to = greatest(100000, coalesce((p_settings->>'price_round_to')::numeric, price_round_to)),
    price_floor = greatest(0, coalesce((p_settings->>'price_floor')::numeric, price_floor)),
    free_transfers_per_month = greatest(0, least(15, coalesce((p_settings->>'free_transfers_per_month')::int, free_transfers_per_month))),
    divisions = coalesce(v_div, divisions),
    competition_types = coalesce(v_ctypes, competition_types),
    require_stats_to_score = coalesce((p_settings->>'require_stats_to_score')::boolean, require_stats_to_score),
    pts_appear = coalesce((p_settings->>'pts_appear')::numeric, pts_appear),
    pts_goal_gk = coalesce((p_settings->>'pts_goal_gk')::numeric, pts_goal_gk),
    pts_goal_def = coalesce((p_settings->>'pts_goal_def')::numeric, pts_goal_def),
    pts_goal_mid = coalesce((p_settings->>'pts_goal_mid')::numeric, pts_goal_mid),
    pts_goal_fwd = coalesce((p_settings->>'pts_goal_fwd')::numeric, pts_goal_fwd),
    pts_assist = coalesce((p_settings->>'pts_assist')::numeric, pts_assist),
    pts_cs_gk = coalesce((p_settings->>'pts_cs_gk')::numeric, pts_cs_gk),
    pts_cs_def = coalesce((p_settings->>'pts_cs_def')::numeric, pts_cs_def),
    pts_cs_mid = coalesce((p_settings->>'pts_cs_mid')::numeric, pts_cs_mid),
    pts_cs_fwd = coalesce((p_settings->>'pts_cs_fwd')::numeric, pts_cs_fwd),
    pts_yellow = coalesce((p_settings->>'pts_yellow')::numeric, pts_yellow),
    pts_red = coalesce((p_settings->>'pts_red')::numeric, pts_red),
    pts_potm = coalesce((p_settings->>'pts_potm')::numeric, pts_potm),
    captain_multiplier = greatest(1, coalesce((p_settings->>'captain_multiplier')::numeric, captain_multiplier)),
    transfer_hit_points = CASE
      WHEN p_settings ? 'transfer_hit_points'
        THEN -abs(coalesce((p_settings->>'transfer_hit_points')::numeric, transfer_hit_points))
      ELSE transfer_hit_points
    END,
    deadline_mode = coalesce(v_mode, deadline_mode),
    chips_enabled = coalesce((p_settings->>'chips_enabled')::boolean, chips_enabled),
    chip_wildcard_enabled = coalesce((p_settings->>'chip_wildcard_enabled')::boolean, chip_wildcard_enabled),
    chip_triple_captain_enabled = coalesce((p_settings->>'chip_triple_captain_enabled')::boolean, chip_triple_captain_enabled),
    chip_bench_boost_enabled = coalesce((p_settings->>'chip_bench_boost_enabled')::boolean, chip_bench_boost_enabled),
    cash_prizes_enabled = coalesce((p_settings->>'cash_prizes_enabled')::boolean, cash_prizes_enabled),
    prize_season_1 = greatest(0, coalesce((p_settings->>'prize_season_1')::numeric, prize_season_1)),
    prize_season_2 = greatest(0, coalesce((p_settings->>'prize_season_2')::numeric, prize_season_2)),
    prize_season_3 = greatest(0, coalesce((p_settings->>'prize_season_3')::numeric, prize_season_3)),
    prize_month_1 = greatest(0, coalesce((p_settings->>'prize_month_1')::numeric, prize_month_1)),
    prize_month_2 = greatest(0, coalesce((p_settings->>'prize_month_2')::numeric, prize_month_2)),
    prize_month_3 = greatest(0, coalesce((p_settings->>'prize_month_3')::numeric, prize_month_3)),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = 1;

  UPDATE public.gpfl_settings
  SET squad_size = slot_gk + slot_def + slot_mid + slot_fwd
  WHERE id = 1;

  SELECT budget INTO v_new_budget FROM public.gpfl_settings WHERE id = 1;

  IF v_new_budget IS DISTINCT FROM v_old_budget
     AND to_regprocedure('public.gpfl_rebase_entry_budgets(bigint)') IS NOT NULL THEN
    PERFORM public.gpfl_rebase_entry_budgets(NULL);
  END IF;

  RETURN public.gpfl_settings_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpfl_settings_set(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_pay_season_prizes(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_pay_month_prizes(text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
