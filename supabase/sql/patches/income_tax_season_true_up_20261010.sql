-- =============================================================================
-- Income tax true-up: put every club's purchases THIS SEASON on the CURRENT
-- income tax % (Admin → Tax %).
--
-- For each club:
--   taxable spend = player transfer purchases (fee the club paid + agent fee)
--                 + special auction fees            — same base as live tax
--   tax due       = each purchase × current % (rounded per purchase, like live)
--   tax charged   = every gov_income_tax line this season (incl. earlier true-ups)
--   difference    = due − charged → posted as one gov_income_tax line
--                   (positive = extra charge, negative = refund)
--
-- Preview changes nothing. Apply is safe to re-run: once a club is level the
-- difference is 0 and nothing more is posted.
--
-- Use from Admin → Tax % ("Season true-up"), or SQL:
--   SELECT public.admin_income_tax_true_up(true);   -- preview
--   SELECT public.admin_income_tax_true_up(false);  -- apply
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_income_tax_true_up(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_season_label text;
  v_pct numeric;
  v_rows jsonb := '[]'::jsonb;
  v_r record;
  v_changed int := 0;
  v_total_delta numeric := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id, s.label INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  SELECT coalesce(g.gov_income_tax_pct, 0) INTO v_pct
  FROM public.global_settings g
  WHERE g.id = 1;

  FOR v_r IN
    WITH transfer_spend AS (
      SELECT DISTINCT ON (lp.metadata->>'transfer_history_id')
        lp.club_short_name AS club,
        abs(coalesce((lp.metadata->>'club_pays')::numeric, h.fee, 0))
          + abs(coalesce(h.agent_fee, 0)) AS spend
      FROM public.competition_finance_ledger lp
      JOIN public."Transfer_History" h
        ON h.id::text = lp.metadata->>'transfer_history_id'
       AND h.buyer_club_id = lp.club_short_name
      WHERE lp.season_id = v_season_id
        AND lp.entry_type = 'transfer_purchase'
        AND lp.club_short_name <> 'FOREIGN'
      ORDER BY lp.metadata->>'transfer_history_id', lp.id
    ),
    special_spend AS (
      SELECT l.club_short_name AS club, abs(l.amount) AS spend
      FROM public.competition_finance_ledger l
      WHERE l.season_id = v_season_id
        AND l.entry_type = 'special_auction_fee'
        AND l.amount < 0
    ),
    purchases AS (
      SELECT club, spend FROM transfer_spend WHERE spend > 0
      UNION ALL
      SELECT club, spend FROM special_spend WHERE spend > 0
    ),
    due AS (
      SELECT club,
             count(*)::int AS purchases,
             sum(spend) AS taxable_spend,
             sum(round(spend * v_pct / 100.0, 2)) AS tax_due
      FROM purchases
      GROUP BY club
    ),
    charged AS (
      SELECT l.club_short_name AS club, sum(-l.amount) AS tax_charged
      FROM public.competition_finance_ledger l
      WHERE l.season_id = v_season_id
        AND l.entry_type = 'gov_income_tax'
      GROUP BY l.club_short_name
    )
    SELECT
      coalesce(d.club, c.club) AS club,
      coalesce(d.purchases, 0) AS purchases,
      coalesce(d.taxable_spend, 0) AS taxable_spend,
      coalesce(d.tax_due, 0) AS tax_due,
      coalesce(c.tax_charged, 0) AS tax_charged,
      round(coalesce(d.tax_due, 0) - coalesce(c.tax_charged, 0), 2) AS delta
    FROM due d
    FULL JOIN charged c ON c.club = d.club
    ORDER BY abs(coalesce(d.tax_due, 0) - coalesce(c.tax_charged, 0)) DESC, 1
  LOOP
    IF abs(v_r.delta) >= 1 THEN
      v_changed := v_changed + 1;
      v_total_delta := v_total_delta + v_r.delta;

      IF NOT p_dry_run THEN
        PERFORM public.post_club_ledger(
          v_r.club,
          'gov_income_tax',
          -v_r.delta,
          CASE WHEN v_r.delta > 0
            THEN format('Income tax adjustment — season purchases re-taxed at %s%%', v_pct)
            ELSE format('Income tax refund — season purchases re-taxed at %s%%', v_pct)
          END,
          jsonb_build_object(
            'income_tax_true_up', true,
            'income_tax_pct', v_pct,
            'taxable_spend', v_r.taxable_spend,
            'tax_due', v_r.tax_due,
            'tax_previously_charged', v_r.tax_charged
          ),
          v_season_id,
          NULL,
          public.finance_entry_via_central_bank('gov_income_tax'),
          true
        );
      END IF;
    END IF;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'club', v_r.club,
      'purchases', v_r.purchases,
      'taxable_spend', v_r.taxable_spend,
      'tax_due', v_r.tax_due,
      'tax_charged', v_r.tax_charged,
      'difference', CASE WHEN abs(v_r.delta) >= 1 THEN v_r.delta ELSE 0 END
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'tax_pct', v_pct,
    'clubs_changed', v_changed,
    'total_difference', v_total_delta,
    'rows', v_rows
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_income_tax_true_up(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_income_tax_true_up(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Preview (changes nothing)
SELECT
  r->>'club' AS club,
  (r->>'purchases')::int AS purchases,
  (r->>'taxable_spend')::numeric AS taxable_spend,
  (r->>'tax_charged')::numeric AS tax_charged_so_far,
  (r->>'tax_due')::numeric AS tax_at_current_pct,
  (r->>'difference')::numeric AS to_charge_or_refund,
  (p->>'tax_pct')::numeric AS current_pct
FROM (SELECT public.admin_income_tax_true_up(true) AS p) x
LEFT JOIN LATERAL jsonb_array_elements(p->'rows') r ON true
ORDER BY abs((r->>'difference')::numeric) DESC NULLS LAST;
