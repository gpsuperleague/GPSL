-- =============================================================================
-- Owner wallet: ₿50,000 opening for new owners + statement RPC
-- FIX: no recursion (ensure must not call _post which calls ensure again)
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

-- Row only — used by ledger poster (never grants opening)
CREATE OR REPLACE FUNCTION public.owner_wallet_ensure_row(p_owner_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'Owner required';
  END IF;
  INSERT INTO public.owner_wallets (owner_id, balance)
  VALUES (p_owner_id, 0)
  ON CONFLICT (owner_id) DO NOTHING;
END;
$function$;

-- Grant opening once (posts ledger inline — does NOT call _post_owner_ledger_internal)
CREATE OR REPLACE FUNCTION public.owner_wallet_grant_opening_if_needed(p_owner_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start numeric := public.owner_wallet_starting_amount();
  v_season_id bigint;
  v_has_opening boolean;
  v_has_any boolean;
  v_bal numeric(14, 2);
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN false;
  END IF;

  PERFORM public.owner_wallet_ensure_row(p_owner_id);

  SELECT EXISTS (
    SELECT 1 FROM public.owner_finance_ledger l
    WHERE l.owner_id = p_owner_id AND l.entry_type = 'opening_balance'
  ) INTO v_has_opening;

  IF v_has_opening THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.owner_finance_ledger l WHERE l.owner_id = p_owner_id
  ) INTO v_has_any;

  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = p_owner_id;

  -- Only seed empty wallets (no history). Skip if they already have other ledger activity.
  IF v_has_any OR coalesce(v_bal, 0) <> 0 THEN
    RETURN false;
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  INSERT INTO public.owner_finance_ledger (
    owner_id, entry_type, amount, description, metadata, season_id
  )
  VALUES (
    p_owner_id,
    'opening_balance',
    v_start,
    format('Owner starting balance (₿%s)', to_char(v_start, 'FM999,999,990')),
    jsonb_build_object('source', 'owner_wallet_opening', 'amount', v_start),
    v_season_id
  );

  UPDATE public.owner_wallets
  SET
    balance = round(balance + v_start, 2),
    updated_at = now()
  WHERE owner_id = p_owner_id;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_wallet_ensure(p_owner_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.owner_wallet_ensure_row(p_owner_id);
  PERFORM public.owner_wallet_grant_opening_if_needed(p_owner_id);
END;
$function$;

-- Poster: ensure row only (never recursion with opening grant)
CREATE OR REPLACE FUNCTION public._post_owner_ledger_internal(
  p_owner_id uuid,
  p_entry_type text,
  p_amount numeric,
  p_description text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_season_id bigint DEFAULT NULL,
  p_apply_balance boolean DEFAULT true
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_amt numeric(14, 2);
  v_ledger_id bigint;
  v_season_id bigint := p_season_id;
BEGIN
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'Owner required';
  END IF;
  IF p_entry_type IS NULL OR btrim(p_entry_type) = '' THEN
    RAISE EXCEPTION 'entry_type required';
  END IF;

  v_amt := round(coalesce(p_amount, 0)::numeric, 2);
  IF v_amt = 0 THEN
    RAISE EXCEPTION 'Ledger amount cannot be zero';
  END IF;

  PERFORM public.owner_wallet_ensure_row(p_owner_id);

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  INSERT INTO public.owner_finance_ledger (
    owner_id, entry_type, amount, description, metadata, season_id
  )
  VALUES (
    p_owner_id,
    btrim(p_entry_type),
    v_amt,
    nullif(btrim(coalesce(p_description, '')), ''),
    coalesce(p_metadata, '{}'::jsonb),
    v_season_id
  )
  RETURNING id INTO v_ledger_id;

  IF coalesce(p_apply_balance, true) THEN
    UPDATE public.owner_wallets
    SET
      balance = round(balance + v_amt, 2),
      updated_at = now()
    WHERE owner_id = p_owner_id;
  END IF;

  RETURN v_ledger_id;
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
    IF public.owner_wallet_grant_opening_if_needed(r.owner_id) THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'granted', v_n);
END;
$function$;

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

GRANT EXECUTE ON FUNCTION public.owner_wallet_starting_amount() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.owner_wallet_ensure_row(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_wallet_grant_opening_if_needed(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_wallet_ensure(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_wallet_backfill_opening() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_wallet_get_self() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_wallet_statement_self(int) TO authenticated;

-- One-shot seed for existing registry owners with empty wallets
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT owner_id FROM public.gpsl_owner_registry LOOP
    PERFORM public.owner_wallet_grant_opening_if_needed(r.owner_id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
