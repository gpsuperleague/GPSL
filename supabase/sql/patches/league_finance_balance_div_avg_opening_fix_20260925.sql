-- =============================================================================
-- League finance balance: season-start Opening + per-division averages
--
-- Opening was preferring prior-season closing_balance (cash after transfers),
-- so many clubs showed ≫ ₿650m. Ecosystem Opening should be season-start cash:
--   1) this season archive opening_balance
--   2) infra_purchase metadata.starting_budget
--   3) club_auction_default_starting_balance() (₿650m)
-- prior closing is still returned as prior_close for reference.
--
-- Also returns by_division: avg / median / gap vs target per division
-- (on top of league-wide ops_net_avg).
--
-- Safe re-run (includes fines + stadium-purchase ops exclusions).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_league_finance_balance(
  p_season_id bigint DEFAULT NULL,
  p_target_avg_ops_profit numeric DEFAULT 10000000
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons%rowtype;
  v_season_id bigint;
  v_target numeric(14, 2);
  v_clubs text[];
  v_club text;
  v_rows jsonb := '[]'::jsonb;
  v_cat_league jsonb := '{}'::jsonb;
  v_by_division jsonb := '[]'::jsonb;
  v_club_count int := 0;
  v_ops_sum numeric(14, 2) := 0;
  v_ops_vals numeric[] := ARRAY[]::numeric[];
  v_avg numeric(14, 2);
  v_median numeric(14, 2);
  v_gap_avg numeric(14, 2);
  v_gap_total numeric(14, 2);
  v_verdict text;
  v_opening numeric(14, 2);
  v_prior_close numeric(14, 2);
  v_balance numeric(14, 2);
  v_division text;
  v_gates numeric(14, 2);
  v_prizes numeric(14, 2);
  v_tv numeric(14, 2);
  v_subsidies numeric(14, 2);
  v_wages numeric(14, 2);
  v_stadium numeric(14, 2);
  v_stadium_purchase numeric(14, 2);
  v_tax_fines numeric(14, 2);
  v_fines numeric(14, 2);
  v_staff numeric(14, 2);
  v_eos numeric(14, 2);
  v_admin_adj numeric(14, 2);
  v_other_ops numeric(14, 2);
  v_transfers numeric(14, 2);
  v_loans numeric(14, 2);
  v_ops_income numeric(14, 2);
  v_ops_cost numeric(14, 2);
  v_ops_net numeric(14, 2);
  v_ledger_net numeric(14, 2);
  v_n int;
  v_mid int;
  v_sorted numeric[];
  v_prior_id bigint;
  v_div text;
  v_div_order text[] := ARRAY[
    'superleague', 'championship_a', 'championship_b'
  ];
  v_div_extra text[];
  v_div_vals numeric[];
  v_div_count int;
  v_div_sum numeric(14, 2);
  v_div_avg numeric(14, 2);
  v_div_median numeric(14, 2);
  v_div_gap numeric(14, 2);
  v_default_start numeric(14, 2);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  v_target := coalesce(p_target_avg_ops_profit, 10000000);

  IF to_regprocedure('public.club_auction_default_starting_balance()') IS NOT NULL THEN
    v_default_start := greatest(coalesce(public.club_auction_default_starting_balance(), 650000000), 0);
  ELSE
    v_default_start := 650000000;
  END IF;

  IF p_season_id IS NOT NULL THEN
    v_season_id := p_season_id;
  ELSIF to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
    v_season_id := public.competition_finances_current_season_id();
  ELSE
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current
    ORDER BY CASE WHEN s.status = 'active' THEN 0 ELSE 1 END, s.id DESC
    LIMIT 1;
  END IF;

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE id = v_season_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  v_clubs := public.admin_finance_resolve_target_clubs(v_season_id, NULL);

  SELECT s.id INTO v_prior_id
  FROM public.competition_seasons s
  WHERE s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  FOREACH v_club IN ARRAY v_clubs
  LOOP
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = v_club
    LIMIT 1;

    SELECT cf.balance INTO v_balance
    FROM public."Club_Finances" cf
    WHERE cf.club_name = v_club
    LIMIT 1;

    -- Prior close kept for reference only (includes transfers — not ecosystem Opening)
    v_prior_close := NULL;
    IF v_prior_id IS NOT NULL THEN
      SELECT a.closing_balance INTO v_prior_close
      FROM public.competition_club_finance_season_archive a
      WHERE a.season_id = v_prior_id
        AND a.club_short_name = v_club
      LIMIT 1;
    END IF;

    -- Season-start Opening (assignment / archive open — typically ₿650m)
    v_opening := NULL;
    SELECT a.opening_balance INTO v_opening
    FROM public.competition_club_finance_season_archive a
    WHERE a.season_id = v_season_id
      AND a.club_short_name = v_club
    LIMIT 1;

    IF v_opening IS NULL THEN
      SELECT (l.metadata->>'starting_budget')::numeric INTO v_opening
      FROM public.competition_finance_ledger l
      WHERE l.season_id = v_season_id
        AND l.club_short_name = v_club
        AND l.entry_type = 'infra_purchase'
        AND l.metadata ? 'starting_budget'
        AND nullif(l.metadata->>'starting_budget', '') IS NOT NULL
      ORDER BY l.created_at ASC, l.id ASC
      LIMIT 1;
    END IF;

    IF v_opening IS NULL THEN
      v_opening := v_default_start;
    END IF;

    SELECT
      coalesce(sum(CASE WHEN l.entry_type LIKE 'gate_%' THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type IN (
          'prize', 'prize_league', 'prize_cup', 'prize_challenge', 'special_auction_prize'
        ) THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE WHEN l.entry_type = 'tv_revenue' THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type IN (
          'gov_hg_subsidy', 'gov_youth_subsidy', 'gov_bnb_subsidy'
        ) THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE WHEN l.entry_type LIKE 'wage_%' THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type LIKE 'infra_%' AND l.entry_type <> 'infra_purchase'
        THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE WHEN l.entry_type = 'infra_purchase' THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type IN ('gov_income_tax', 'gov_emergency_tax')
        THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type = 'gov_fine_compensation' THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type IN (
          'staff_manager_salary',
          'medical_doctor_hire',
          'medical_physio_hire',
          'contract_signing_offer',
          'contract_release_comp',
          'contract_release_comp_received',
          'contract_termination',
          'contract_expiry_champ_signing_fee',
          'season_loan_fee',
          'season_loan_refund',
          'voluntary_contract_release'
        ) THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE WHEN l.entry_type LIKE 'eos_%' THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type IN (
          'adjustment', 'admin_one_off_injection', 'admin_purchase_payment'
        ) THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE
        WHEN l.entry_type IN (
          'transfer_sale',
          'transfer_purchase',
          'transfer_agent_fee',
          'transfer_foreign_sale',
          'transfer_overflow_release',
          'special_auction_fee',
          'contract_expiry_compensation',
          'new_owner_release'
        ) THEN l.amount ELSE 0 END), 0),
      coalesce(sum(CASE WHEN l.entry_type LIKE 'loan_%' THEN l.amount ELSE 0 END), 0),
      coalesce(sum(l.amount), 0)
    INTO
      v_gates, v_prizes, v_tv, v_subsidies, v_wages,
      v_stadium, v_stadium_purchase,
      v_tax_fines, v_fines,
      v_staff, v_eos, v_admin_adj, v_transfers, v_loans, v_ledger_net
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_season_id
      AND l.club_short_name = v_club;

    v_other_ops :=
      v_ledger_net
      - v_gates - v_prizes - v_tv - v_subsidies - v_wages - v_stadium
      - v_stadium_purchase
      - v_tax_fines - v_fines - v_staff - v_eos - v_admin_adj
      - v_transfers - v_loans;

    v_ops_net :=
      v_gates + v_prizes + v_tv + v_subsidies + v_wages + v_stadium
      + v_tax_fines + v_staff + v_eos + v_admin_adj + v_other_ops;

    v_ops_income :=
      greatest(v_gates, 0) + greatest(v_prizes, 0) + greatest(v_tv, 0)
      + greatest(v_subsidies, 0) + greatest(v_wages, 0) + greatest(v_stadium, 0)
      + greatest(v_tax_fines, 0) + greatest(v_staff, 0) + greatest(v_eos, 0)
      + greatest(v_admin_adj, 0) + greatest(v_other_ops, 0);

    v_ops_cost :=
      least(v_gates, 0) + least(v_prizes, 0) + least(v_tv, 0)
      + least(v_subsidies, 0) + least(v_wages, 0) + least(v_stadium, 0)
      + least(v_tax_fines, 0) + least(v_staff, 0) + least(v_eos, 0)
      + least(v_admin_adj, 0) + least(v_other_ops, 0);

    v_rows := v_rows || jsonb_build_array(
      jsonb_build_object(
        'club', v_club,
        'division', v_division,
        'opening_balance', v_opening,
        'prior_close', v_prior_close,
        'balance_now', v_balance,
        'gates', v_gates,
        'prizes', v_prizes,
        'tv', v_tv,
        'subsidies', v_subsidies,
        'wages', v_wages,
        'stadium', v_stadium,
        'stadium_purchase', v_stadium_purchase,
        'tax_fines', v_tax_fines,
        'fines', v_fines,
        'staff', v_staff,
        'eos', v_eos,
        'admin_adj', v_admin_adj,
        'other_ops', v_other_ops,
        'ops_income', v_ops_income,
        'ops_cost', v_ops_cost,
        'ops_net', v_ops_net,
        'transfers_net', v_transfers,
        'loans_net', v_loans,
        'ledger_net_all', v_ledger_net
      )
    );

    v_ops_sum := v_ops_sum + v_ops_net;
    v_ops_vals := array_append(v_ops_vals, v_ops_net);
    v_club_count := v_club_count + 1;

    v_cat_league := jsonb_build_object(
      'gates', coalesce((v_cat_league->>'gates')::numeric, 0) + v_gates,
      'prizes', coalesce((v_cat_league->>'prizes')::numeric, 0) + v_prizes,
      'tv', coalesce((v_cat_league->>'tv')::numeric, 0) + v_tv,
      'subsidies', coalesce((v_cat_league->>'subsidies')::numeric, 0) + v_subsidies,
      'wages', coalesce((v_cat_league->>'wages')::numeric, 0) + v_wages,
      'stadium', coalesce((v_cat_league->>'stadium')::numeric, 0) + v_stadium,
      'stadium_purchase', coalesce((v_cat_league->>'stadium_purchase')::numeric, 0) + v_stadium_purchase,
      'tax_fines', coalesce((v_cat_league->>'tax_fines')::numeric, 0) + v_tax_fines,
      'fines', coalesce((v_cat_league->>'fines')::numeric, 0) + v_fines,
      'staff', coalesce((v_cat_league->>'staff')::numeric, 0) + v_staff,
      'eos', coalesce((v_cat_league->>'eos')::numeric, 0) + v_eos,
      'admin_adj', coalesce((v_cat_league->>'admin_adj')::numeric, 0) + v_admin_adj,
      'other_ops', coalesce((v_cat_league->>'other_ops')::numeric, 0) + v_other_ops,
      'transfers', coalesce((v_cat_league->>'transfers')::numeric, 0) + v_transfers,
      'loans', coalesce((v_cat_league->>'loans')::numeric, 0) + v_loans
    );
  END LOOP;

  IF v_club_count = 0 THEN
    v_avg := 0;
    v_median := 0;
  ELSE
    v_avg := round(v_ops_sum / v_club_count, 2);
    SELECT array_agg(x ORDER BY x) INTO v_sorted FROM unnest(v_ops_vals) AS x;
    v_n := coalesce(array_length(v_sorted, 1), 0);
    IF v_n = 0 THEN
      v_median := 0;
    ELSIF v_n % 2 = 1 THEN
      v_median := v_sorted[(v_n + 1) / 2];
    ELSE
      v_mid := v_n / 2;
      v_median := round((v_sorted[v_mid] + v_sorted[v_mid + 1]) / 2.0, 2);
    END IF;
  END IF;

  v_gap_avg := round(v_target - v_avg, 2);
  v_gap_total := round(v_gap_avg * v_club_count, 2);

  IF abs(v_gap_avg) <= 1000000 THEN
    v_verdict := 'near_target';
  ELSIF v_gap_avg > 0 THEN
    v_verdict := 'under_target';
  ELSE
    v_verdict := 'over_target';
  END IF;

  -- Extra divisions beyond the main three (keep ordered after core)
  SELECT coalesce(array_agg(d ORDER BY d), ARRAY[]::text[])
  INTO v_div_extra
  FROM (
    SELECT DISTINCT coalesce(nullif(x->>'division', ''), 'unassigned') AS d
    FROM jsonb_array_elements(v_rows) x
    WHERE coalesce(nullif(x->>'division', ''), 'unassigned') <> ALL (v_div_order)
  ) s;

  FOREACH v_div IN ARRAY (v_div_order || v_div_extra)
  LOOP
    SELECT array_agg((x->>'ops_net')::numeric)
    INTO v_div_vals
    FROM jsonb_array_elements(v_rows) x
    WHERE coalesce(nullif(x->>'division', ''), 'unassigned') = v_div;

    v_div_count := coalesce(array_length(v_div_vals, 1), 0);
    IF v_div_count = 0 THEN
      CONTINUE;
    END IF;

    SELECT coalesce(sum(x), 0) INTO v_div_sum FROM unnest(v_div_vals) AS x;
    v_div_avg := round(v_div_sum / v_div_count, 2);

    SELECT array_agg(x ORDER BY x) INTO v_sorted FROM unnest(v_div_vals) AS x;
    v_n := coalesce(array_length(v_sorted, 1), 0);
    IF v_n = 0 THEN
      v_div_median := 0;
    ELSIF v_n % 2 = 1 THEN
      v_div_median := v_sorted[(v_n + 1) / 2];
    ELSE
      v_mid := v_n / 2;
      v_div_median := round((v_sorted[v_mid] + v_sorted[v_mid + 1]) / 2.0, 2);
    END IF;

    v_div_gap := round(v_target - v_div_avg, 2);

    v_by_division := v_by_division || jsonb_build_array(
      jsonb_build_object(
        'division', v_div,
        'club_count', v_div_count,
        'ops_net_avg', v_div_avg,
        'ops_net_median', v_div_median,
        'ops_net_total', v_div_sum,
        'gap_vs_target_avg', v_div_gap
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', v_season.label,
    'season_status', v_season.status,
    'target_avg_ops_profit', v_target,
    'default_starting_balance', v_default_start,
    'club_count', v_club_count,
    'ops_net_total', v_ops_sum,
    'ops_net_avg', v_avg,
    'ops_net_median', v_median,
    'gap_vs_target_avg', v_gap_avg,
    'gap_vs_target_total', v_gap_total,
    'verdict', v_verdict,
    'tuning_hint', CASE
      WHEN v_verdict = 'near_target' THEN
        'League ops P&L is within ~₿1m of the target average. Fine-tune prizes/TV/subsidies only if you want a tighter band.'
      WHEN v_verdict = 'under_target' THEN
        format(
          'Average ops profit is ₿%s below target. To hit the target, inject about ₿%s league-wide via prizes, TV, subsidies, or lower wage/tax pressure (≈ ₿%s per club).',
          to_char(abs(v_gap_avg), 'FM999,999,999,999'),
          to_char(abs(v_gap_total), 'FM999,999,999,999'),
          to_char(abs(v_gap_avg), 'FM999,999,999,999')
        )
      ELSE
        format(
          'Average ops profit is ₿%s above target. To cool the ecosystem, reduce prizes/TV/subsidies or raise wage/tax pressure by about ₿%s league-wide (≈ ₿%s per club).',
          to_char(abs(v_gap_avg), 'FM999,999,999,999'),
          to_char(abs(v_gap_total), 'FM999,999,999,999'),
          to_char(abs(v_gap_avg), 'FM999,999,999,999')
        )
    END,
    'excluded', jsonb_build_array(
      'transfer_sale', 'transfer_purchase', 'transfer_agent_fee',
      'transfer_foreign_sale', 'transfer_overflow_release', 'special_auction_fee',
      'contract_expiry_compensation', 'new_owner_release',
      'loan_drawdown', 'loan_repayment_principal', 'loan_interest_payment',
      'gov_fine_compensation',
      'infra_purchase'
    ),
    'category_totals', v_cat_league,
    'by_division', v_by_division,
    'clubs', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_league_finance_balance(bigint, numeric)
  TO authenticated;

COMMENT ON FUNCTION public.competition_admin_league_finance_balance(bigint, numeric) IS
  'Admin league P&L: ops excludes transfers/loans/fines/stadium buys; Opening = season-start cash; includes by_division averages.';

NOTIFY pgrst, 'reload schema';
