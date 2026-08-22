-- =============================================================================
-- GPFL: auto cash prizes on GPSL month lock
--
-- • Regular month lock (Aug–May): finalize GPFL month scores, then pay month top-3
-- • Playoffs month lock: pay season top-3 (after optional provisional finalize)
-- • Idempotent (same as manual admin pay) — safe if End Month jobs re-run
-- • Soft-wired into competition_run_month_lock_jobs (tables / all / gpfl stages)
--
-- Requires: bookies_gpfl_owner_wallet_20260822.sql (prize tables + pay logic)
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Internal pays (no admin gate — called from month-lock SECURITY DEFINER)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_pay_season_prizes_internal(
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
  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season');
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.cash_prizes_enabled, true) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'disabled');
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
        'entry_id', r.entry_id,
        'auto', true
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

CREATE OR REPLACE FUNCTION public.gpfl_pay_month_prizes_internal(
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
  IF v_month = '' OR v_month = 'playoffs' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'not_a_prize_month', 'gpsl_month', v_month);
  END IF;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season');
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.cash_prizes_enabled, true) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'disabled');
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
        'entry_id', r.entry_id,
        'auto', true
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

-- Admin wrappers (manual repair / catch-up)
CREATE OR REPLACE FUNCTION public.admin_gpfl_pay_season_prizes(
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpfl_pay_season_prizes_internal(p_gpfl_season_id);
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
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpfl_pay_month_prizes_internal(p_gpsl_month, p_gpfl_season_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Month-lock entry point
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_on_gpsl_month_lock(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_gs_id bigint;
  v_score jsonb := NULL;
  v_pay jsonb := NULL;
  v_prov record;
  v_finalized text[] := ARRAY[]::text[];
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_month');
  END IF;

  SELECT gs.id INTO v_gs_id
  FROM public.gpfl_seasons gs
  WHERE gs.competition_season_id = p_season_id
  ORDER BY gs.id DESC
  LIMIT 1;

  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_gpfl_season');
  END IF;

  -- Playoffs lock → season prizes (finalize any leftover provisional months first)
  IF v_month = 'playoffs' THEN
    IF to_regprocedure('public.gpfl_score_month(text,bigint)') IS NOT NULL THEN
      FOR v_prov IN
        SELECT DISTINCT lower(mp.gpsl_month) AS gpsl_month
        FROM public.gpfl_entry_month_points mp
        JOIN public.gpfl_entries e ON e.id = mp.entry_id
        WHERE e.gpfl_season_id = v_gs_id
          AND mp.is_provisional = true
          AND lower(mp.gpsl_month) IS DISTINCT FROM 'playoffs'
      LOOP
        BEGIN
          PERFORM public.gpfl_score_month(v_prov.gpsl_month, v_gs_id);
          v_finalized := array_append(v_finalized, v_prov.gpsl_month);
        EXCEPTION
          WHEN OTHERS THEN
            NULL;
        END;
      END LOOP;
    END IF;

    v_pay := public.gpfl_pay_season_prizes_internal(v_gs_id);
    RETURN jsonb_build_object(
      'ok', true,
      'gpsl_month', v_month,
      'gpfl_season_id', v_gs_id,
      'action', 'season_prizes',
      'finalized_provisional_months', to_jsonb(v_finalized),
      'payout', v_pay
    );
  END IF;

  -- Regular month → finalize scores then pay month top-3
  IF to_regprocedure('public.gpfl_score_month(text,bigint)') IS NOT NULL THEN
    BEGIN
      v_score := public.gpfl_score_month(v_month, v_gs_id);
    EXCEPTION
      WHEN OTHERS THEN
        RETURN jsonb_build_object(
          'ok', false,
          'gpsl_month', v_month,
          'gpfl_season_id', v_gs_id,
          'action', 'month_prizes',
          'score_error', SQLERRM
        );
    END;
  END IF;

  v_pay := public.gpfl_pay_month_prizes_internal(v_month, v_gs_id);

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpfl_season_id', v_gs_id,
    'action', 'month_prizes',
    'score', v_score,
    'payout', v_pay
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_pay_season_prizes_internal(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_pay_month_prizes_internal(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_pay_season_prizes(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_pay_month_prizes(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_on_gpsl_month_lock(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_on_gpsl_month_lock(bigint, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Soft-wire into month-lock jobs (before RETURN v_out)
-- ---------------------------------------------------------------------------
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'gpfl_on_gpsl_month_lock';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs(4-arg) missing — GPFL prize wire skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'GPFL prizes already wired into month-lock jobs';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out in month-lock jobs — GPFL prize wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  -- GPFL: score + month prizes (regular lock) / season prizes (playoffs lock)\n'
    || E'  IF (\n'
    || E'       v_month = ''playoffs''\n'
    || E'       AND coalesce(nullif(v_stage, ''''), ''all'') IN (''all'', ''playoffs'', ''tables'', ''league_tables'', ''awards'', ''gpfl'')\n'
    || E'     )\n'
    || E'     OR (\n'
    || E'       coalesce(v_month, '''') IS DISTINCT FROM ''playoffs''\n'
    || E'       AND coalesce(nullif(v_stage, ''''), ''all'') IN (''all'', ''tables'', ''league_tables'', ''awards'', ''gpfl'')\n'
    || E'     )\n'
    || E'  THEN\n'
    || E'    BEGIN\n'
    || E'      IF to_regprocedure(''public.gpfl_on_gpsl_month_lock(bigint,text)'') IS NOT NULL THEN\n'
    || E'        v_out := v_out || jsonb_build_object(\n'
    || E'          ''gpfl_prizes'',\n'
    || E'          public.gpfl_on_gpsl_month_lock(p_season_id, v_month)\n'
    || E'        );\n'
    || E'      END IF;\n'
    || E'    EXCEPTION\n'
    || E'      WHEN OTHERS THEN\n'
    || E'        v_out := v_out || jsonb_build_object(\n'
    || E'          ''gpfl_prizes'',\n'
    || E'          jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'        );\n'
    || E'    END;\n'
    || E'  END IF;\n\n'
    || E'  RETURN v_out;\nEND;';

  v_def := replace(v_def, v_old, v_new);

  BEGIN
    EXECUTE v_def;
    RAISE NOTICE 'Wired GPFL auto prizes into competition_run_month_lock_jobs';
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'GPFL month-lock wire failed (%); call gpfl_on_gpsl_month_lock manually', SQLERRM;
  END;
END;
$wire$;

NOTIFY pgrst, 'reload schema';
