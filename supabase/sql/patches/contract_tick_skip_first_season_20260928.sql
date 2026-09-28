-- =============================================================================
-- Contract tick: skip cleanly on the first season (no prior season)
--
-- Error after a test reset:
--   contract_tick_rollover_step_fa: No prior season found to read expiry wage
--   bids from (ledger season id 2).
--
-- The first pre-season has no finished year and no expiry bids, and contracts
-- signed during that pre-season must NOT be decremented. So:
--   • contract_rollover_finance_context() returns a NULL bid season instead of
--     raising when there is no earlier season.
--   • The staged steps (fa / decrement / contested) and the one-shot
--     contract_tick_season_rollover() return an ok "skipped" result when the
--     bid season is NULL (their live bodies are kept; only a guard is added).
--
-- Run once in Supabase SQL Editor, then click Tick contracts only (or ignore —
-- nothing needs ticking on the first season). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_rollover_finance_context()
RETURNS TABLE (
  ledger_season_id bigint,
  ledger_season_label text,
  bid_season_id bigint,
  bid_season_label text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ledger record;
  v_bid record;
  v_bid_label_from_bids text;
  v_bid_id_from_label bigint;
BEGIN
  SELECT s.id, s.label, s.status
  INTO v_ledger
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_ledger.id IS NULL THEN
    RAISE EXCEPTION
      'Create the next pre-season first — expiry transfers and FA releases must post to the new season (not the closed year).';
  END IF;

  SELECT s.id, s.label
  INTO v_bid
  FROM public.competition_seasons s
  WHERE s.id < v_ledger.id
    AND s.status IN ('complete', 'active')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_bid.id IS NULL THEN
    SELECT s.id, s.label
    INTO v_bid
    FROM public.competition_seasons s
    WHERE s.id < v_ledger.id
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  ledger_season_id := v_ledger.id;
  ledger_season_label := btrim(v_ledger.label);

  IF v_bid.id IS NULL THEN
    -- First season: nothing to read, nothing to tick
    bid_season_id := NULL;
    bid_season_label := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  bid_season_id := v_bid.id;
  bid_season_label := btrim(v_bid.label);

  SELECT b.season_label
  INTO v_bid_label_from_bids
  FROM public.contract_expiry_wage_bids b
  GROUP BY b.season_label
  ORDER BY count(*) DESC, max(b.created_at) DESC
  LIMIT 1;

  IF v_bid_label_from_bids IS NOT NULL
     AND btrim(v_bid_label_from_bids) <> ''
     AND btrim(v_bid_label_from_bids) IS DISTINCT FROM bid_season_label
  THEN
    SELECT s.id
    INTO v_bid_id_from_label
    FROM public.competition_seasons s
    WHERE lower(btrim(s.label)) = lower(btrim(v_bid_label_from_bids))
    ORDER BY s.id DESC
    LIMIT 1;

    bid_season_label := btrim(v_bid_label_from_bids);
    IF v_bid_id_from_label IS NOT NULL THEN
      bid_season_id := v_bid_id_from_label;
    END IF;
  END IF;

  RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_rollover_finance_context() TO authenticated;

-- ---------------------------------------------------------------------------
-- Guard the tick functions (inject after their context lookup)
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
  v_fn text;
  v_sig regprocedure;
  v_def text;
  v_new text;
  v_marker text := 'SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();';
  v_guard text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'contract_tick_rollover_step_fa',
    'contract_tick_rollover_step_decrement',
    'contract_tick_rollover_step_contested',
    'contract_tick_season_rollover'
  ]
  LOOP
    v_sig := to_regprocedure(format('public.%s()', v_fn));
    IF v_sig IS NULL THEN
      RAISE NOTICE '% not found — skipped', v_fn;
      CONTINUE;
    END IF;

    IF pg_get_function_result(v_sig) <> 'jsonb' THEN
      RAISE NOTICE '% does not return jsonb — skipped', v_fn;
      CONTINUE;
    END IF;

    v_def := pg_get_functiondef(v_sig);

    IF position('first_season_no_prior' IN v_def) > 0 THEN
      RAISE NOTICE '% already guarded', v_fn;
      CONTINUE;
    END IF;

    IF position(v_marker IN v_def) = 0 THEN
      RAISE NOTICE '% has no context lookup — skipped', v_fn;
      CONTINUE;
    END IF;

    v_guard := v_marker || E'\n\n'
      || E'  IF v_ctx.bid_season_id IS NULL THEN\n'
      || E'    RETURN jsonb_build_object(\n'
      || E'      ''ok'', true,\n'
      || E'      ''skipped'', true,\n'
      || E'      ''reason'', ''first_season_no_prior'',\n'
      || format(E'      ''step'', %L,\n', v_fn)
      || E'      ''ledger_season_id'', v_ctx.ledger_season_id,\n'
      || E'      ''ledger_season_label'', v_ctx.ledger_season_label,\n'
      || E'      ''players_released_zero_years'', 0,\n'
      || E'      ''players_decremented'', 0,\n'
      || E'      ''players_final_year'', 0,\n'
      || E'      ''players_contested_resolved'', 0,\n'
      || E'      ''note'', ''First season — no prior season or expiry bids; contracts not ticked.''\n'
      || E'    );\n'
      || E'  END IF;';

    v_new := replace(v_def, v_marker, v_guard);
    EXECUTE v_new;
    RAISE NOTICE '% guarded for first season', v_fn;
  END LOOP;
END;
$guard$;

NOTIFY pgrst, 'reload schema';
