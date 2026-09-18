-- =============================================================================
-- Vanilla / pre-launch test reset: wipe owner personal banks → opening ₿50k
--
-- Club_Finances were already zeroed by admin_test_reset_execute; owner_wallets
-- were not. This restores every personal wallet to the standard opening balance.
--
-- Run in Supabase SQL Editor after admin_prelaunch_test_reset.sql
-- (and ideally after owner_wallet_opening_50k_20260822.sql).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_test_reset_reset_owner_wallets()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ledger_deleted int := 0;
  v_wallets_zeroed int := 0;
  v_granted int := 0;
  v_backfill jsonb;
  r record;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF to_regclass('public.owner_finance_ledger') IS NULL
     OR to_regclass('public.owner_wallets') IS NULL THEN
    RETURN jsonb_build_object(
      'owner_wallets_reset', false,
      'reason', 'owner_wallets / owner_finance_ledger missing'
    );
  END IF;

  DELETE FROM public.owner_finance_ledger WHERE true;
  GET DIAGNOSTICS v_ledger_deleted = ROW_COUNT;

  UPDATE public.owner_wallets
  SET balance = 0,
      updated_at = now()
  WHERE true;
  GET DIAGNOSTICS v_wallets_zeroed = ROW_COUNT;

  -- Re-grant opening ₿50k (clears the "already opened" ledger gate).
  IF to_regprocedure('public.admin_owner_wallet_backfill_opening()') IS NOT NULL THEN
    v_backfill := public.admin_owner_wallet_backfill_opening();
    v_granted := coalesce((v_backfill ->> 'granted')::int, 0);
  ELSIF to_regprocedure('public.owner_wallet_grant_opening_if_needed(uuid)') IS NOT NULL THEN
    FOR r IN SELECT owner_id FROM public.owner_wallets
    LOOP
      IF public.owner_wallet_grant_opening_if_needed(r.owner_id) THEN
        v_granted := v_granted + 1;
      END IF;
    END LOOP;
    IF to_regclass('public.gpsl_owner_registry') IS NOT NULL THEN
      FOR r IN SELECT owner_id FROM public.gpsl_owner_registry
      LOOP
        IF public.owner_wallet_grant_opening_if_needed(r.owner_id) THEN
          v_granted := v_granted + 1;
        END IF;
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'owner_wallets_reset', true,
    'owner_ledger_deleted', v_ledger_deleted,
    'owner_wallets_zeroed', v_wallets_zeroed,
    'owner_opening_granted', v_granted
  );
END;
$function$;

COMMENT ON FUNCTION public.admin_test_reset_reset_owner_wallets() IS
  'Vanilla reset: wipe owner_finance_ledger + zero owner_wallets, then re-grant opening ₿50k.';

GRANT EXECUTE ON FUNCTION public.admin_test_reset_reset_owner_wallets() TO authenticated;

-- Hook into admin_test_reset_execute after club finances are zeroed (Phase E).
DO $hook$
DECLARE
  v_def text;
  v_new text;
  v_marker text := $m$
  UPDATE public."Club_Finances"
  SET balance = 0
  WHERE true;$m$;
  v_inject text := $i$
  UPDATE public."Club_Finances"
  SET balance = 0
  WHERE true;

  -- Phase E2: owner personal wallets → opening ₿50k
  v_result := v_result || public.admin_test_reset_reset_owner_wallets();
$i$;
BEGIN
  SELECT pg_get_functiondef('public.admin_test_reset_execute(text,jsonb)'::regprocedure)
  INTO v_def;

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'admin_test_reset_execute missing — run admin_prelaunch_test_reset.sql first';
  END IF;

  IF position('admin_test_reset_reset_owner_wallets' IN v_def) > 0 THEN
    RAISE NOTICE 'admin_test_reset_execute already hooks owner wallet reset';
    RETURN;
  END IF;

  IF position(v_marker IN v_def) = 0 THEN
    RAISE EXCEPTION
      'Could not find Club_Finances zero marker in admin_test_reset_execute — patch manually';
  END IF;

  v_new := replace(v_def, v_marker, v_inject);
  EXECUTE v_new;
  RAISE NOTICE 'admin_test_reset_execute: hooked owner wallet reset after Phase E';
END;
$hook$;

NOTIFY pgrst, 'reload schema';
