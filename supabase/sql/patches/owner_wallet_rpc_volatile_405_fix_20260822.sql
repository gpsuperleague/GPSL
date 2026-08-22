-- =============================================================================
-- Fix: owner_wallet_statement_self / get_self 405 (Method Not Allowed)
--
-- Cause: functions were STABLE but call owner_wallet_ensure (writes).
-- PostgREST then only accepts GET; supabase-js rpc() sends POST → 405.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_wallet_get_self()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_bal numeric(14, 2);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;
  PERFORM public.owner_wallet_ensure(v_uid);
  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = v_uid;
  RETURN jsonb_build_object(
    'owner_id', v_uid,
    'balance', coalesce(v_bal, 0)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_wallet_statement_self(p_limit int DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_bal numeric(14, 2);
  v_rows jsonb;
  v_lim int := greatest(1, least(coalesce(p_limit, 100), 500));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  PERFORM public.owner_wallet_ensure(v_uid);
  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = v_uid;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC, x.id DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      l.id,
      l.entry_type,
      l.amount,
      l.description,
      l.metadata,
      l.season_id,
      l.created_at
    FROM public.owner_finance_ledger l
    WHERE l.owner_id = v_uid
    ORDER BY l.created_at DESC, l.id DESC
    LIMIT v_lim
  ) x;

  RETURN jsonb_build_object(
    'owner_id', v_uid,
    'balance', coalesce(v_bal, 0),
    'starting_amount', public.owner_wallet_starting_amount(),
    'entries', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_wallet_get_self() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_wallet_statement_self(int) TO authenticated;

NOTIFY pgrst, 'reload schema';
