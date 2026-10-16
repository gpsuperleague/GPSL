-- =============================================================================
-- Admin-only: GPSL Building Society balances for every owner
--
--   admin_owner_wallets_overview()           list tag / club / balance
--   admin_owner_wallet_statement(owner, lim) one owner's statement
--
-- GPSL admin only (not mods). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_wallets_overview()
RETURNS TABLE (
  owner_id uuid,
  owner_tag text,
  email text,
  club_short_name text,
  club_name text,
  registry_status text,
  balance numeric,
  wallet_updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  WITH owner_ids AS (
    SELECT r.owner_id FROM public.gpsl_owner_registry r
    WHERE coalesce(r.status, '') <> 'archived'
    UNION
    SELECT c.owner_id FROM public."Clubs" c WHERE c.owner_id IS NOT NULL
  )
  SELECT
    o.owner_id,
    public.owner_registry_resolve_tag(o.owner_id),
    u.email::text,
    c."ShortName"::text,
    c."Club"::text,
    coalesce(
      reg.status,
      CASE WHEN c.owner_id IS NOT NULL THEN 'active' ELSE 'on_break' END
    )::text,
    coalesce(w.balance, 0)::numeric,
    w.updated_at
  FROM owner_ids o
  JOIN auth.users u ON u.id = o.owner_id
  LEFT JOIN public."Clubs" c ON c.owner_id = o.owner_id
  LEFT JOIN public.gpsl_owner_registry reg ON reg.owner_id = o.owner_id
  LEFT JOIN public.owner_wallets w ON w.owner_id = o.owner_id
  ORDER BY coalesce(w.balance, 0) DESC, coalesce(c."Club", u.email);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_wallet_statement(
  p_owner_id uuid,
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_bal numeric(14, 2);
  v_rows jsonb;
  v_lim int := greatest(1, least(coalesce(p_limit, 100), 500));
  v_tag text;
  v_club text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'Owner required';
  END IF;

  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = p_owner_id;
  v_tag := public.owner_registry_resolve_tag(p_owner_id);
  SELECT c."Club" INTO v_club FROM public."Clubs" c WHERE c.owner_id = p_owner_id LIMIT 1;

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
    WHERE l.owner_id = p_owner_id
    ORDER BY l.created_at DESC, l.id DESC
    LIMIT v_lim
  ) x;

  RETURN jsonb_build_object(
    'owner_id', p_owner_id,
    'owner_tag', v_tag,
    'club_name', v_club,
    'balance', coalesce(v_bal, 0),
    'entries', v_rows
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_owner_wallets_overview() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_owner_wallet_statement(uuid, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_wallets_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_wallet_statement(uuid, int) TO authenticated;

COMMENT ON FUNCTION public.admin_owner_wallets_overview() IS
  'GPSL admin only: every non-archived owner Building Society balance.';
COMMENT ON FUNCTION public.admin_owner_wallet_statement(uuid, int) IS
  'GPSL admin only: one owner Building Society statement.';

NOTIFY pgrst, 'reload schema';

-- Report
SELECT owner_tag, club_name, balance
FROM public.admin_owner_wallets_overview()
ORDER BY balance DESC
LIMIT 20;
