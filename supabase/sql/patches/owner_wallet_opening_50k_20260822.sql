-- =============================================================================
-- Owner wallet: ₿50,000 opening for new owners + statement RPC
-- Prerequisites: owners_shop_wallet_catalogue_20260822.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_wallet_starting_amount()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 50000::numeric;
$$;

CREATE OR REPLACE FUNCTION public.owner_wallet_ensure(p_owner_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inserted uuid;
  v_has_ledger boolean;
  v_bal numeric(14, 2);
  v_start numeric := public.owner_wallet_starting_amount();
BEGIN
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'Owner required';
  END IF;

  INSERT INTO public.owner_wallets (owner_id, balance)
  VALUES (p_owner_id, 0)
  ON CONFLICT (owner_id) DO NOTHING
  RETURNING owner_id INTO v_inserted;

  SELECT EXISTS (
    SELECT 1 FROM public.owner_finance_ledger l WHERE l.owner_id = p_owner_id
  ) INTO v_has_ledger;

  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = p_owner_id;

  -- Brand-new wallet, or empty legacy wallet with no history → opening credit once
  IF (v_inserted IS NOT NULL OR (NOT v_has_ledger AND coalesce(v_bal, 0) = 0))
     AND NOT EXISTS (
       SELECT 1 FROM public.owner_finance_ledger l
       WHERE l.owner_id = p_owner_id AND l.entry_type = 'opening_balance'
     )
  THEN
    PERFORM public._post_owner_ledger_internal(
      p_owner_id,
      'opening_balance',
      v_start,
      format('Owner starting balance (₿%s)', to_char(v_start, 'FM999,999,990')),
      jsonb_build_object('source', 'owner_wallet_opening', 'amount', v_start)
    );
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_gpsl_owner_registry_wallet_opening()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.owner_wallet_ensure(NEW.owner_id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS gpsl_owner_registry_wallet_opening ON public.gpsl_owner_registry;
CREATE TRIGGER gpsl_owner_registry_wallet_opening
  AFTER INSERT ON public.gpsl_owner_registry
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_gpsl_owner_registry_wallet_opening();

-- Optional: grant opening to existing registry owners who still have an empty wallet
CREATE OR REPLACE FUNCTION public.admin_owner_wallet_backfill_opening()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR r IN
    SELECT owner_id FROM public.gpsl_owner_registry
  LOOP
    PERFORM public.owner_wallet_ensure(r.owner_id);
    IF EXISTS (
      SELECT 1 FROM public.owner_finance_ledger l
      WHERE l.owner_id = r.owner_id
        AND l.entry_type = 'opening_balance'
        AND l.created_at > now() - interval '2 seconds'
    ) THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'granted_approx', v_n);
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_wallet_statement_self(p_limit int DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
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

GRANT EXECUTE ON FUNCTION public.owner_wallet_starting_amount() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.owner_wallet_ensure(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_wallet_backfill_opening() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_wallet_statement_self(int) TO authenticated;

-- Seed opening for current registry owners with empty wallets (one-shot on apply)
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT owner_id FROM public.gpsl_owner_registry LOOP
    PERFORM public.owner_wallet_ensure(r.owner_id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
