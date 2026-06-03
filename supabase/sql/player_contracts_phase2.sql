-- =============================================================================
-- Player contracts — phase 2 (C2 rollover tick + C3 renew / expire)
-- Run in Supabase SQL Editor AFTER player_contract_hooks.sql + player_wage_settings.sql
-- + squad_composition_rules.sql (is_player_homegrown).
-- =============================================================================

-- Extend transfer guard: final contract year (1 season left) cannot be listed/sold
CREATE OR REPLACE FUNCTION public.assert_player_transferable(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_signed   text;
  v_seasons  smallint;
BEGIN
  SELECT p."Season_Signed", p.contract_seasons_remaining
  INTO v_signed, v_seasons
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_signed_this_season(v_signed) THEN
    RAISE EXCEPTION
      'This player was signed in the current season and cannot be sold or listed until the next season.';
  END IF;

  IF v_seasons IS NOT NULL AND v_seasons <= 1 THEN
    RAISE EXCEPTION
      'Player is in the final year of their contract and cannot be sold or listed. Renew or expire the contract from your squad page.';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_player_homegrown_u23(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_player_homegrown(p_player_id, p_club_short_name)
    AND EXISTS (
      SELECT 1
      FROM public."Players" p
      WHERE p."Konami_ID"::text = p_player_id
        AND p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 23
    );
$$;

-- Decrement contract years for all contracted players (call after rollover_season)
CREATE OR REPLACE FUNCTION public.contract_tick_season_rollover()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_updated int;
  v_final   int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public."Players" p
  SET contract_seasons_remaining = contract_seasons_remaining - 1
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining > 0;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT count(*)::int
  INTO v_final
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'players_decremented', v_updated,
    'players_final_year', v_final
  );
END;
$function$;

-- Owner renew: final year only → new 3-year deal
CREATE OR REPLACE FUNCTION public.player_contract_renew(
  p_player_id text,
  p_wage numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club    text;
  v_player  public."Players"%rowtype;
  v_pid     text := btrim(p_player_id);
  v_wage    numeric;
  v_hg_u23  boolean;
  v_season  text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RAISE EXCEPTION 'Renewal is only available in the final contract year (1 season remaining)';
  END IF;

  v_hg_u23 := public.is_player_homegrown_u23(v_pid, v_club);
  v_wage := coalesce(p_wage, v_player.contract_wage);

  IF v_hg_u23 THEN
    v_wage := coalesce(v_player.contract_wage, v_wage);
  ELSE
    IF v_wage IS NULL OR v_wage < coalesce(v_player.contract_wage, 0) THEN
      RAISE EXCEPTION
        'Renewal wage must be at least the current contract wage (₿ %)',
        coalesce(v_player.contract_wage, 0);
    END IF;
  END IF;

  v_season := public.current_gpsl_season_label();

  UPDATE public."Players"
  SET
    contract_seasons_remaining = 3,
    contract_wage = round(v_wage, 0),
    "Season_Signed" = v_season
  WHERE "Konami_ID"::text = v_pid;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'contract_seasons_remaining', 3,
    'contract_wage', round(v_wage, 0),
    'homegrown_u23', v_hg_u23
  );
END;
$function$;

-- Owner expire: final year → MV credit + free agent
CREATE OR REPLACE FUNCTION public.player_contract_expire(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_pid            text := btrim(p_player_id);
  v_fee            numeric;
  v_seller_balance numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RAISE EXCEPTION 'Contract expiry is only available in the final contract year (1 season remaining)';
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    NULL,
    v_fee,
    0,
    now(),
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player."Konami_ID",
    'player_name', v_player."Name",
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_tick_season_rollover() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_contract_renew(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_contract_expire(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_player_homegrown_u23(text, text) TO authenticated;
