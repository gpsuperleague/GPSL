-- =============================================================================
-- Month-lock side effects: durable registry (stop soft-wire wipeouts)
-- 2026-10-29
--
-- Problem: patches string-replaced snippets into competition_run_month_lock_jobs.
-- Any later CREATE OR REPLACE of that function silently dropped interest,
-- balance snapshots, friendlies, etc.
--
-- Fix:
--   1) competition_run_month_lock_side_effects() — owned list of finance hooks
--   2) Registry table for optional extra hooks (add rows; do not soft-wire)
--   3) competition_admin_run_month_lock_jobs ALWAYS runs side effects after core
--   4) competition_run_month_lock_jobs_complete() wrapper for other callers
--   5) Soft-wire ONLY the single side_effects call into core (idempotent), so
--      direct callers still get interest even if admin wrapper is bypassed
--
-- Going forward: add a hook row or edit side_effects — never splice into core.
-- Safe re-run.
-- =============================================================================

-- Ensure balance snapshot exists (was soft-wired historically; may be missing)
CREATE TABLE IF NOT EXISTS public.club_month_end_balances (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  gpsl_month text NOT NULL,
  club_short_name text NOT NULL,
  balance numeric(14, 2) NOT NULL,
  source text,
  checkpoint_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, gpsl_month, club_short_name)
);

CREATE OR REPLACE FUNCTION public.club_balance_snapshot_gpsl_month(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_rows int := 0;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id and gpsl_month required');
  END IF;

  INSERT INTO public.club_month_end_balances (
    season_id, gpsl_month, club_short_name, balance, source, checkpoint_at
  )
  SELECT p_season_id, v_month, f.club_name, coalesce(f.balance, 0), 'month_lock', now()
  FROM public."Club_Finances" f
  JOIN public.competition_club_seasons ccs
    ON ccs.club_short_name = f.club_name
   AND ccs.season_id = p_season_id
  WHERE f.club_name <> 'FOREIGN'
  ON CONFLICT (season_id, gpsl_month, club_short_name) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'gpsl_month', v_month, 'inserted', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.club_balance_snapshot_gpsl_month(bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.club_balance_snapshot_gpsl_month(bigint, text)
  TO service_role;

CREATE TABLE IF NOT EXISTS public.competition_month_lock_hooks (
  hook_key text PRIMARY KEY,
  sort_order int NOT NULL DEFAULT 100,
  enabled boolean NOT NULL DEFAULT true,
  -- Must be public.fn(bigint, text) RETURNS jsonb  (season_id, gpsl_month)
  proc_name text NOT NULL,
  notes text
);

COMMENT ON TABLE public.competition_month_lock_hooks IS
  'Optional month-lock side-effect hooks. Core finance hooks live in competition_run_month_lock_side_effects. Add rows here — do NOT soft-wire into competition_run_month_lock_jobs.';

ALTER TABLE public.competition_month_lock_hooks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS competition_month_lock_hooks_admin_select ON public.competition_month_lock_hooks;
CREATE POLICY competition_month_lock_hooks_admin_select
  ON public.competition_month_lock_hooks
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());
GRANT SELECT ON public.competition_month_lock_hooks TO authenticated;
GRANT ALL ON public.competition_month_lock_hooks TO service_role;

-- Built-in finance hooks are hardcoded below (must not depend on soft-wire).
-- Optional extras can be registered here later without touching core jobs.

CREATE OR REPLACE FUNCTION public.competition_run_month_lock_side_effects(
  p_season_id bigint,
  p_gpsl_month text,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_stage text := lower(btrim(coalesce(p_stage, 'all')));
  v_out jsonb := jsonb_build_object('ok', true, 'gpsl_month', nullif(v_month, ''));
  v_res jsonb;
  r record;
  v_reg text;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id required');
  END IF;

  -- Resolve month if caller omitted it
  IF v_month = '' THEN
    BEGIN
      v_month := lower(coalesce(
        public.competition_active_gpsl_month(p_season_id, now()), ''
      ));
    EXCEPTION WHEN OTHERS THEN
      v_month := '';
    END;
  END IF;
  v_out := v_out || jsonb_build_object('gpsl_month', nullif(v_month, ''));

  -- ---- Hardcoded must-run finance hooks (idempotent) --------------------
  IF v_month <> '' THEN
    BEGIN
      IF to_regprocedure('public.club_balance_snapshot_gpsl_month(bigint,text)') IS NOT NULL THEN
        v_res := public.club_balance_snapshot_gpsl_month(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('balance_snapshot', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'balance_snapshot', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.competition_post_monthly_interest(bigint,text)') IS NOT NULL THEN
        v_res := public.competition_post_monthly_interest(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('monthly_interest', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'monthly_interest', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.club_credit_probation_tick(bigint)') IS NOT NULL THEN
        -- Returns void/int depending on build — wrap as jsonb
        PERFORM public.club_credit_probation_tick(p_season_id);
        v_out := v_out || jsonb_build_object('credit_probation', jsonb_build_object('ok', true));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'credit_probation', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END IF;

  -- ---- Optional registry hooks (proc must be (bigint, text) → jsonb) ----
  FOR r IN
    SELECT hook_key, proc_name
    FROM public.competition_month_lock_hooks
    WHERE enabled
    ORDER BY sort_order, hook_key
  LOOP
    BEGIN
      v_reg := format('public.%I(bigint,text)', r.proc_name);
      IF to_regprocedure(v_reg) IS NULL THEN
        v_out := v_out || jsonb_build_object(
          r.hook_key, jsonb_build_object('ok', false, 'error', 'proc_missing')
        );
        CONTINUE;
      END IF;
      IF v_month = '' THEN
        CONTINUE;
      END IF;
      EXECUTE format('SELECT public.%I($1, $2)', r.proc_name)
        INTO v_res
        USING p_season_id, v_month;
      v_out := v_out || jsonb_build_object(r.hook_key, v_res);
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        r.hook_key, jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END LOOP;

  v_out := v_out || jsonb_build_object('stage', v_stage);
  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_run_month_lock_side_effects(bigint, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_side_effects(bigint, text, text)
  TO service_role, authenticated;

COMMENT ON FUNCTION public.competition_run_month_lock_side_effects(bigint, text, text) IS
  'Durable month-lock side effects (balance snapshot, monthly interest, credit probation + registry). Call from admin/entry points — do not soft-wire snippets into competition_run_month_lock_jobs.';

-- Wrapper: core jobs + side effects (use this from end-month / ticks)
CREATE OR REPLACE FUNCTION public.competition_run_month_lock_jobs_complete(
  p_season_id bigint,
  p_force_scheduling boolean DEFAULT false,
  p_locked_gpsl_month text DEFAULT NULL,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb;
  v_side jsonb;
  v_month text := nullif(lower(btrim(coalesce(p_locked_gpsl_month, ''))), '');
BEGIN
  v_out := public.competition_run_month_lock_jobs(
    p_season_id, p_force_scheduling, p_locked_gpsl_month, p_stage
  );

  -- Prefer month from jobs result if present
  IF v_month IS NULL THEN
    v_month := nullif(lower(btrim(coalesce(v_out->>'gpsl_month', ''))), '');
  END IF;

  v_side := public.competition_run_month_lock_side_effects(
    p_season_id, v_month, p_stage
  );
  RETURN coalesce(v_out, '{}'::jsonb) || jsonb_build_object('side_effects', v_side);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_run_month_lock_jobs_complete(bigint, boolean, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs_complete(bigint, boolean, text, text)
  TO service_role, authenticated;

-- Admin entry: ALWAYS append side effects after core (survives core rewrites)
CREATE OR REPLACE FUNCTION public.competition_admin_run_month_lock_jobs(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_force_scheduling boolean DEFAULT true,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '240s', true);

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  RETURN public.competition_run_month_lock_jobs_complete(
    v_season_id,
    coalesce(p_force_scheduling, true),
    p_gpsl_month,
    p_stage
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_run_month_lock_jobs(bigint, text, boolean, text)
  TO authenticated;

-- Soft-wire ONLY the durable side_effects call into core (single marker).
-- If a future rewrite drops it, admin/complete wrappers still run interest.
DO $wire$
DECLARE
  v_def text;
  v_oid oid;
  v_old text;
  v_new text;
  v_marker text := 'competition_run_month_lock_side_effects';
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)');
  IF v_oid IS NULL THEN
    RAISE WARNING 'competition_run_month_lock_jobs missing — side_effects not inlined';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;
  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'side_effects already inlined in month-lock jobs';
    RETURN;
  END IF;

  -- Remove legacy duplicated finance soft-wires (now owned by side_effects)
  v_def := regexp_replace(
    v_def,
    E'\\n  -- Month-end club balance snapshot.*?\\n  END;\\n',
    E'\n',
    'n'
  );
  v_def := regexp_replace(
    v_def,
    E'\\n  -- Monthly balance / overdraft interest.*?\\n  END;\\n',
    E'\n',
    'n'
  );

  v_new :=
    E'  -- Durable side effects (interest / snapshots / registry) — do not delete\n'
    || E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.competition_run_month_lock_side_effects(bigint,text,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''side_effects'',\n'
    || E'        public.competition_run_month_lock_side_effects(p_season_id, v_month, v_stage)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION WHEN OTHERS THEN\n'
    || E'    v_out := v_out || jsonb_build_object(\n'
    || E'      ''side_effects'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'    );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'\n'
    || E'END;';

  IF position(E'  RETURN v_out;\n\nEND;' IN v_def) > 0 THEN
    v_old := E'  RETURN v_out;\n\nEND;';
  ELSIF position(E'  RETURN v_out;\nEND;' IN v_def) > 0 THEN
    v_old := E'  RETURN v_out;\nEND;';
  ELSE
    RAISE WARNING 'Could not inline side_effects (RETURN pattern). Admin wrapper still covers interest.';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Inlined competition_run_month_lock_side_effects into month-lock jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'side_effects inline failed (admin wrapper still covers): %', SQLERRM;
END;
$wire$;

-- Health check for admins / future patches
CREATE OR REPLACE FUNCTION public.competition_month_lock_side_effects_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_def text := '';
BEGIN
  BEGIN
    v_def := pg_get_functiondef(
      'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
    );
  EXCEPTION WHEN OTHERS THEN
    v_def := '';
  END;

  RETURN jsonb_build_object(
    'side_effects_fn',
      to_regprocedure('public.competition_run_month_lock_side_effects(bigint,text,text)') IS NOT NULL,
    'complete_fn',
      to_regprocedure('public.competition_run_month_lock_jobs_complete(bigint,boolean,text,text)') IS NOT NULL,
    'inlined_in_core_jobs',
      position('competition_run_month_lock_side_effects' IN v_def) > 0,
    'monthly_interest_fn',
      to_regprocedure('public.competition_post_monthly_interest(bigint,text)') IS NOT NULL,
    'balance_snapshot_fn',
      to_regprocedure('public.club_balance_snapshot_gpsl_month(bigint,text)') IS NOT NULL,
    'registry_hooks',
      coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'hook_key', h.hook_key,
          'proc_name', h.proc_name,
          'enabled', h.enabled,
          'sort_order', h.sort_order
        ) ORDER BY h.sort_order, h.hook_key)
        FROM public.competition_month_lock_hooks h
      ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_month_lock_side_effects_status() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT public.competition_month_lock_side_effects_status() AS status;
