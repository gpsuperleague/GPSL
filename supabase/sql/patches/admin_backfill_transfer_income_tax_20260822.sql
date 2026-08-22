-- =============================================================================
-- Backfill income tax on transfer purchases that already have a purchase ledger
-- line but no gov_income_tax for the same transfer_history_id.
--
-- Use when older draft/auction batches were posted before tax was restored, or
-- while gov_income_tax_pct was effectively not hooked.
--
-- After apply:
--   SELECT * FROM public.admin_transfer_income_tax_gaps_summary();
--   SELECT public.admin_backfill_transfer_income_tax(true);   -- dry-run
--   SELECT public.admin_backfill_transfer_income_tax(false);  -- apply + debit
-- Safe re-run (idempotent on metadata.transfer_history_id).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_transfer_income_tax_gaps_summary(
  p_club_short_name text DEFAULT NULL
)
RETURNS TABLE (
  buyer_club_id text,
  missing_tax_rows int,
  taxable_spend numeric,
  estimated_tax numeric,
  live_balance numeric,
  tax_pct numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club_short_name, '')), '');
  v_pct numeric := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(g.gov_income_tax_pct, 0) INTO v_pct
  FROM public.global_settings g WHERE g.id = 1;

  RETURN QUERY
  WITH gaps AS (
    SELECT
      h.buyer_club_id::text AS club,
      (
        abs(coalesce((lp.metadata->>'club_pays')::numeric, h.fee, 0))
        + abs(coalesce(h.agent_fee, 0))
      )::numeric AS spend
    FROM public."Transfer_History" h
    JOIN public.competition_finance_ledger lp
      ON lp.metadata->>'transfer_history_id' = h.id::text
     AND lp.entry_type = 'transfer_purchase'
     AND lp.club_short_name = h.buyer_club_id
    WHERE h.buyer_club_id IS NOT NULL
      AND btrim(h.buyer_club_id::text) <> ''
      AND h.buyer_club_id <> 'FOREIGN'
      AND (v_club IS NULL OR h.buyer_club_id = v_club)
      AND abs(coalesce(h.fee, 0)) + abs(coalesce(h.agent_fee, 0)) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger t
        WHERE t.club_short_name = h.buyer_club_id
          AND t.entry_type = 'gov_income_tax'
          AND t.metadata->>'transfer_history_id' = h.id::text
      )
  )
  SELECT
    g.club,
    count(*)::int,
    coalesce(sum(g.spend), 0)::numeric,
    round(coalesce(sum(g.spend), 0) * v_pct / 100.0, 2)::numeric,
    cf.balance::numeric,
    v_pct
  FROM gaps g
  LEFT JOIN public."Club_Finances" cf ON cf.club_name = g.club
  GROUP BY g.club, cf.balance
  ORDER BY estimated_tax DESC, g.club;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_backfill_transfer_income_tax(
  p_dry_run boolean DEFAULT true,
  p_club_short_name text DEFAULT NULL,
  p_apply_balance boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club_short_name, '')), '');
  v_pct numeric := 0;
  v_row record;
  v_spend numeric;
  v_player_name text;
  v_posted int := 0;
  v_skipped int := 0;
  v_tax_total numeric := 0;
  v_errors jsonb := '[]'::jsonb;
  v_ids bigint[] := ARRAY[]::bigint[];
  v_sample jsonb := '[]'::jsonb;
  v_ledger_id bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(g.gov_income_tax_pct, 0) INTO v_pct
  FROM public.global_settings g WHERE g.id = 1;

  IF coalesce(v_pct, 0) <= 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'gov_income_tax_pct is 0 — set tax % on Admin Tax page first'
    );
  END IF;

  IF to_regprocedure(
    'public.post_gov_income_tax_on_player_spend(text, numeric, text, jsonb, boolean)'
  ) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'post_gov_income_tax_on_player_spend missing');
  END IF;

  FOR v_row IN
    SELECT
      h.id AS history_id,
      h.buyer_club_id,
      h.fee,
      h.agent_fee,
      h.player_id,
      lp.metadata AS purchase_meta
    FROM public."Transfer_History" h
    JOIN public.competition_finance_ledger lp
      ON lp.metadata->>'transfer_history_id' = h.id::text
     AND lp.entry_type = 'transfer_purchase'
     AND lp.club_short_name = h.buyer_club_id
    WHERE h.buyer_club_id IS NOT NULL
      AND btrim(h.buyer_club_id::text) <> ''
      AND h.buyer_club_id <> 'FOREIGN'
      AND (v_club IS NULL OR h.buyer_club_id = v_club)
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger t
        WHERE t.club_short_name = h.buyer_club_id
          AND t.entry_type = 'gov_income_tax'
          AND t.metadata->>'transfer_history_id' = h.id::text
      )
    ORDER BY h.transfer_time, h.id
  LOOP
    BEGIN
      v_spend :=
        abs(coalesce((v_row.purchase_meta->>'club_pays')::numeric, v_row.fee, 0))
        + abs(coalesce(v_row.agent_fee, 0));

      IF v_spend <= 0 THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      SELECT p."Name" INTO v_player_name
      FROM public."Players" p
      WHERE p."Konami_ID"::text = v_row.player_id::text
      LIMIT 1;
      v_player_name := coalesce(v_player_name, 'Player ' || v_row.player_id::text);

      IF p_dry_run THEN
        v_posted := v_posted + 1;
        v_tax_total := v_tax_total + round(v_spend * v_pct / 100.0, 2);
        v_ids := v_ids || v_row.history_id;
        IF jsonb_array_length(v_sample) < 40 THEN
          v_sample := v_sample || jsonb_build_array(jsonb_build_object(
            'history_id', v_row.history_id,
            'buyer', v_row.buyer_club_id,
            'player', v_player_name,
            'taxable_spend', v_spend,
            'estimated_tax', round(v_spend * v_pct / 100.0, 2)
          ));
        END IF;
      ELSE
        v_ledger_id := public.post_gov_income_tax_on_player_spend(
          v_row.buyer_club_id,
          v_spend,
          'Income tax — ' || v_player_name,
          jsonb_build_object(
            'transfer_history_id', v_row.history_id,
            'player_id', v_row.player_id,
            'income_tax_source', 'transfer',
            'backfill', true
          ),
          coalesce(p_apply_balance, true)
        );
        IF v_ledger_id IS NOT NULL THEN
          v_posted := v_posted + 1;
          v_tax_total := v_tax_total + round(v_spend * v_pct / 100.0, 2);
          v_ids := v_ids || v_row.history_id;
        ELSE
          v_skipped := v_skipped + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      IF jsonb_array_length(v_errors) < 25 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'history_id', v_row.history_id,
          'buyer', v_row.buyer_club_id,
          'error', SQLERRM
        ));
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'club', v_club,
    'tax_pct', v_pct,
    'apply_balance', coalesce(p_apply_balance, true),
    'would_or_did_post', v_posted,
    'skipped_or_failed', v_skipped,
    'estimated_or_posted_tax_total', v_tax_total,
    'history_ids', to_jsonb(v_ids),
    'sample', v_sample,
    'errors', v_errors,
    'hint', CASE
      WHEN p_dry_run THEN
        'Re-run admin_backfill_transfer_income_tax(false) to post tax and debit balances.'
      ELSE
        'Income tax lines posted for purchases that previously lacked them.'
    END
  );
END;
$function$;

COMMENT ON FUNCTION public.admin_transfer_income_tax_gaps_summary(text) IS
  'Admin: clubs with transfer purchases missing gov_income_tax for the same history id.';
COMMENT ON FUNCTION public.admin_backfill_transfer_income_tax(boolean, text, boolean) IS
  'Admin: backfill gov_income_tax on existing transfer_purchase rows (idempotent).';

GRANT EXECUTE ON FUNCTION public.admin_transfer_income_tax_gaps_summary(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_backfill_transfer_income_tax(boolean, text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
