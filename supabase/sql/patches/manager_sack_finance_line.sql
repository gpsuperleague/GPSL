-- Manager sack ledger → show under Finances Staff / Contract termination (UI maps
-- positive contract_release_comp + kind=manager). Optional richer metadata for new sacks.

CREATE OR REPLACE FUNCTION public.manager_release_from_club(
  p_manager_id bigint,
  p_payout_club text DEFAULT NULL,
  p_payout_amount numeric DEFAULT NULL,
  p_ledger_type text DEFAULT 'transfer_sale',
  p_description text DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_club text;
  v_payout numeric;
  v_desc text;
  v_meta jsonb;
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  v_club := v_mgr.contracted_club;
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'Manager is a free agent';
  END IF;

  v_payout := coalesce(p_payout_amount, v_mgr.market_value::numeric);
  v_desc := coalesce(nullif(btrim(p_description), ''), format('Manager release — %s', v_mgr.name));
  v_meta := coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager');

  IF p_payout_club IS NOT NULL AND v_payout > 0 THEN
    PERFORM public.post_club_ledger(
      p_payout_club,
      p_ledger_type,
      abs(v_payout),
      v_desc,
      v_meta
    );
  END IF;

  -- Keep signed_season_id — season transfer history still needs the original season link.
  UPDATE public."Managers"
  SET contracted_club = NULL,
      contract_seasons_remaining = 0,
      weekly_wage = 0,
      updated_at = now()
  WHERE id = p_manager_id;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = v_club;

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Cancelled', updated_at = now()
  WHERE manager_id = p_manager_id AND status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'former_club', v_club,
    'payout', v_payout
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_sack()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_payout numeric;
  v_sacks smallint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT manager_sacks_remaining INTO v_sacks
  FROM public."Clubs"
  WHERE "ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_sacks, 0) < 1 THEN
    RAISE EXCEPTION 'Manager sack already used this season';
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE contracted_club = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No manager signed at your club';
  END IF;

  v_payout := round(greatest(v_mgr.market_value, 0)::numeric / 2.0, 0);

  UPDATE public."Clubs"
  SET manager_sacks_remaining = 0
  WHERE "ShortName" = v_club;

  RETURN public.manager_release_from_club(
    v_mgr.id,
    v_club,
    v_payout,
    'contract_release_comp',
    format('Manager sack — %s (half MV)', v_mgr.name),
    jsonb_build_object('manager_sack', true, 'gpsl_month', 'january')
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';

-- Existing manager sack lines (half MV credit) — tag for season accounts UI
UPDATE public.competition_finance_ledger l
SET metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object('manager_sack', true)
WHERE l.entry_type = 'contract_release_comp'
  AND l.amount > 0
  AND coalesce(l.metadata->>'kind', '') = 'manager'
  AND NOT coalesce((l.metadata->>'manager_sack')::boolean, false);
