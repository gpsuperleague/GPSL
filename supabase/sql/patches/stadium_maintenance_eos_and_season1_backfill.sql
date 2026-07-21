-- =============================================================================
-- Stadium maintenance (infra_maintenance) — EOS post + Season 1 backfill
--
-- Formula: round(capacity × ₿1,500 × 12.5%)
-- Was never posted: only projected in season accounts (planned line).
--
-- This patch:
--   A) Allows charge_type infra_maintenance
--   B) Routes infra_maintenance via Central Bank (like stadium purchase)
--   C) competition_post_infra_maintenance(season) — idempotent
--   D) Wires into competition_admin_close_finances (after wages, before debt)
--   E) Season 1 ledger backfill (NO Club_Finances cash change) + re-archive
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Then hard-refresh finances_accounts.html?season=1
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A) charge_paid types
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_season_charge_paid
  DROP CONSTRAINT IF EXISTS competition_season_charge_paid_charge_type_check;

ALTER TABLE public.competition_season_charge_paid
  ADD CONSTRAINT competition_season_charge_paid_charge_type_check
  CHECK (
    charge_type IN (
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'staff_manager_salary',
      'gov_emergency_tax',
      'gov_income_tax',
      'eos_ffp_charge',
      'eos_debt_interest',
      'eos_balance_interest',
      'infra_maintenance'
    )
  );

-- ---------------------------------------------------------------------------
-- B) Central Bank mirror for maintenance
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
    'tv_revenue',
    'infra_purchase',
    'infra_maintenance',
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
-- Helper: maintenance amount for a club
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_stadium_maintenance_cost(p_club_short_name text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT round(
    greatest(coalesce(c."Capacity", 0), 0)::numeric * 1500 * 0.125
  )
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;
$$;

COMMENT ON FUNCTION public.club_stadium_maintenance_cost(text) IS
  'Season stadium maintenance: 12.5% of stadium value (capacity × ₿1,500).';

GRANT EXECUTE ON FUNCTION public.club_stadium_maintenance_cost(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- C) Post maintenance for all season clubs (live cash debit)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_infra_maintenance(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_cost numeric;
  v_paid int := 0;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  -- Ensure ledger type allowed
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger
    WHERE entry_type = 'infra_maintenance'
    LIMIT 1
  ) THEN
    BEGIN
      ALTER TABLE public.competition_finance_ledger
        DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;
    EXCEPTION WHEN undefined_object THEN
      NULL;
    END;
  END IF;

  FOR v_club IN
    SELECT
      ccs.club_short_name,
      greatest(coalesce(c."Capacity", 0), 0)::int AS capacity
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND ccs.club_short_name <> 'FOREIGN'
    ORDER BY ccs.club_short_name
  LOOP
    v_cost := round(v_club.capacity::numeric * 1500 * 0.125);
    IF v_cost <= 0 THEN
      CONTINUE;
    END IF;

    IF public.competition_post_club_charge(
      p_season_id,
      v_club.club_short_name,
      'infra_maintenance',
      v_cost,
      format(
        'Stadium maintenance — %s seats × ₿1,500 × 12.5%%',
        to_char(v_club.capacity, 'FM999,999,999')
      ),
      jsonb_build_object(
        'capacity', v_club.capacity,
        'value_per_seat', 1500,
        'rate_pct', 12.5,
        'stadium_value', v_club.capacity * 1500
      )
    ) THEN
      v_paid := v_paid + 1;
    END IF;
  END LOOP;

  RETURN v_paid;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_post_infra_maintenance(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- D) Close Finances: wages → maintenance → debt → FFP → credit → archive
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_close_finances(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_wages jsonb;
  v_maint int := 0;
  v_debt int := 0;
  v_ffp int := 0;
  v_credit int := 0;
  v_finance_archived int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
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

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  -- 1) Season wage bills
  v_wages := public.competition_admin_post_season_wage_bills(v_season_id);

  -- 2) Stadium maintenance (capacity × ₿1,500 × 12.5%)
  v_maint := public.competition_post_infra_maintenance(v_season_id);

  -- 3) Debt interest on overdrawn accounts (after wages + maintenance)
  v_debt := public.competition_post_eos_debt_interest(v_season_id);

  -- 4) FFP
  v_ffp := public.competition_post_eos_ffp_charges(v_season_id);

  -- 5) Credit interest on positive balances
  v_credit := public.competition_post_eos_balance_interest(v_season_id);

  -- 6) Refresh finance archive
  IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_finance_archived := public.competition_archive_club_finances_for_season(v_season_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'wages', v_wages,
    'infra_maintenance_clubs', v_maint,
    'debt_interest_clubs', v_debt,
    'ffp_clubs', v_ffp,
    'balance_interest_clubs', v_credit,
    'finance_archive_clubs', v_finance_archived
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_close_finances(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- E) Season 1 backfill — ledger + archive only (no live cash debit)
-- ---------------------------------------------------------------------------

DO $s1_maint$
DECLARE
  v_sid bigint;
  v_label text;
  v_club record;
  v_cost numeric;
  v_n int := 0;
  v_archived int := 0;
  v_list text;
BEGIN
  SELECT s.id, s.label INTO v_sid, v_label
  FROM public.competition_seasons s
  WHERE s.label IN ('1', 'Season 1')
  ORDER BY CASE WHEN s.label = '1' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_sid IS NULL THEN
    RAISE NOTICE 'Season 1 not found — skipped maintenance backfill';
    RETURN;
  END IF;

  -- Allow infra_maintenance on ledger check
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT 'infra_maintenance'
  ) u;

  IF v_list IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.competition_finance_ledger DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check';
    EXECUTE format(
      'ALTER TABLE public.competition_finance_ledger ADD CONSTRAINT competition_finance_ledger_entry_type_check CHECK (entry_type IN (%s))',
      v_list
    );
  END IF;

  FOR v_club IN
    SELECT
      u.club_short_name,
      greatest(
        coalesce(
          (
            SELECT nullif((l.metadata->>'capacity')::int, 0)
            FROM public.competition_finance_ledger l
            WHERE l.club_short_name = u.club_short_name
              AND l.entry_type = 'infra_purchase'
              AND l.season_id = v_sid
            ORDER BY l.created_at
            LIMIT 1
          ),
          c.base_capacity,
          c."Capacity",
          0
        ),
        0
      )::int AS capacity
    FROM (
      SELECT DISTINCT x.club_short_name
      FROM (
        SELECT ccs.club_short_name
        FROM public.competition_club_seasons ccs
        WHERE ccs.season_id = v_sid
          AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
        UNION
        SELECT a.club_short_name
        FROM public.competition_club_finance_season_archive a
        WHERE a.season_id = v_sid
        UNION
        SELECT l.club_short_name
        FROM public.competition_finance_ledger l
        WHERE l.season_id = v_sid
      ) x
      WHERE x.club_short_name IS NOT NULL
        AND x.club_short_name <> 'FOREIGN'
    ) u
    LEFT JOIN public."Clubs" c ON c."ShortName" = u.club_short_name
    ORDER BY u.club_short_name
  LOOP
    v_cost := round(v_club.capacity::numeric * 1500 * 0.125);
    IF v_cost <= 0 THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid p
      WHERE p.season_id = v_sid
        AND p.club_short_name = v_club.club_short_name
        AND p.charge_type = 'infra_maintenance'
    ) THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.competition_finance_ledger l
      WHERE l.season_id = v_sid
        AND l.club_short_name = v_club.club_short_name
        AND l.entry_type = 'infra_maintenance'
    ) THEN
      -- Mark charge paid so live Close Finances won't double-post if re-run on S1
      INSERT INTO public.competition_season_charge_paid (
        season_id, club_short_name, charge_type, amount, metadata
      ) VALUES (
        v_sid, v_club.club_short_name, 'infra_maintenance', v_cost,
        jsonb_build_object('season1_backfill', true, 'cash_applied', false, 'existing_ledger', true)
      );
      CONTINUE;
    END IF;

    INSERT INTO public.competition_finance_ledger (
      season_id, club_short_name, entry_type, amount, description, metadata
    ) VALUES (
      v_sid,
      v_club.club_short_name,
      'infra_maintenance',
      -v_cost,
      format(
        'Stadium maintenance — %s seats × ₿1,500 × 12.5%% (Season 1 backfill)',
        to_char(v_club.capacity, 'FM999,999,999')
      ),
      jsonb_build_object(
        'capacity', v_club.capacity,
        'value_per_seat', 1500,
        'rate_pct', 12.5,
        'stadium_value', v_club.capacity * 1500,
        'season1_backfill', true,
        'cash_applied', false
      )
    );

    INSERT INTO public.competition_season_charge_paid (
      season_id, club_short_name, charge_type, amount, metadata
    ) VALUES (
      v_sid,
      v_club.club_short_name,
      'infra_maintenance',
      v_cost,
      jsonb_build_object(
        'capacity', v_club.capacity,
        'season1_backfill', true,
        'cash_applied', false
      )
    );

    v_n := v_n + 1;
  END LOOP;

  IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_archived := public.competition_archive_club_finances_for_season(v_sid);
  END IF;

  RAISE NOTICE
    'Season % stadium maintenance backfill: clubs_posted=% archive_clubs=%',
    v_label, v_n, v_archived;
END;
$s1_maint$;

NOTIFY pgrst, 'reload schema';

-- Quick check: Season 1 maintenance lines
SELECT
  l.club_short_name,
  round(sum(abs(l.amount)), 2) AS maintenance_total,
  count(*) AS lines
FROM public.competition_finance_ledger l
JOIN public.competition_seasons s ON s.id = l.season_id
WHERE s.label IN ('1', 'Season 1')
  AND l.entry_type = 'infra_maintenance'
GROUP BY l.club_short_name
ORDER BY l.club_short_name;
