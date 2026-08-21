-- =============================================================================
-- One of our Own (OooO) final-year contracts
-- - Young OooO (HG≤23 / non-HG≤21): unchanged uncontested same-wage renew
-- - OooO who would otherwise be contested: skip expiry auction; renew at +2.5%
--   (fresh 3-season deal). Same +2.5% each later final year while still OooO.
-- Safe re-run. Requires club_ooo_player_id() (squad designations).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_ooo_renew_uplift_pct()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 2.5::numeric;
$$;

COMMENT ON FUNCTION public.contract_ooo_renew_uplift_pct() IS
  'Wage uplift % when renewing a One of our Own who would otherwise be contested.';

-- Age / HG brackets only (no OooO).
CREATE OR REPLACE FUNCTION public.is_player_expiry_age_exempt(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid   text := btrim(p_player_id);
  v_club  text := btrim(p_club_short_name);
  v_age   numeric;
  v_hg    boolean;
BEGIN
  IF v_pid IS NULL OR v_pid = '' OR v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  SELECT
    CASE
      WHEN p."Age" IS NULL OR btrim(p."Age"::text) = '' THEN NULL
      ELSE btrim(p."Age"::text)::numeric
    END
  INTO v_age
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND OR v_age IS NULL THEN
    RETURN false;
  END IF;

  v_hg := public.is_player_homegrown(v_pid, v_club);

  IF v_hg AND v_age <= 23 THEN
    RETURN true;
  END IF;

  IF (NOT v_hg) AND v_age <= 21 THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

COMMENT ON FUNCTION public.is_player_expiry_age_exempt(text, text) IS
  'Uncontested same-wage path: (HG and age≤23) OR (not HG and age≤21).';

-- Auction exempt = age brackets OR current club One of our Own.
CREATE OR REPLACE FUNCTION public.is_player_expiry_auction_exempt(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid  text := btrim(p_player_id);
  v_club text := btrim(p_club_short_name);
  v_ooo  text;
BEGIN
  IF v_pid IS NULL OR v_pid = '' OR v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  IF public.is_player_expiry_age_exempt(v_pid, v_club) THEN
    RETURN true;
  END IF;

  IF to_regprocedure('public.club_ooo_player_id(text)') IS NOT NULL THEN
    v_ooo := public.club_ooo_player_id(v_club);
    IF v_ooo IS NOT NULL AND btrim(v_ooo) = v_pid THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END;
$function$;

COMMENT ON FUNCTION public.is_player_expiry_auction_exempt(text, text) IS
  'Skip contested expiry market: age brackets (HG≤23 / non-HG≤21) OR club One of our Own.';

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
  v_club       text;
  v_player     public."Players"%rowtype;
  v_pid        text := btrim(p_player_id);
  v_wage       numeric;
  v_age_exempt boolean;
  v_is_ooo     boolean := false;
  v_exempt     boolean;
  v_ooo_uplift boolean := false;
  v_uplift_pct numeric;
  v_season     text;
  v_ooo        text;
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

  v_age_exempt := public.is_player_expiry_age_exempt(v_pid, v_club);

  IF to_regprocedure('public.club_ooo_player_id(text)') IS NOT NULL THEN
    v_ooo := public.club_ooo_player_id(v_club);
    v_is_ooo := (v_ooo IS NOT NULL AND btrim(v_ooo) = v_pid);
  END IF;

  v_exempt := v_age_exempt OR v_is_ooo OR coalesce(v_player.pesdb_unavailable, false);

  -- Contested final-year (not exempt): must use expiry wage auction
  IF NOT v_exempt THEN
    RAISE EXCEPTION
      'This player is on the contested expiry wage market. '
      'Place a wage bid on Expiring Contracts — contracts resolve at season rollover.';
  END IF;

  v_uplift_pct := public.contract_ooo_renew_uplift_pct();

  -- Young uncontested / legacy: same wage. OooO who would be contested: +2.5%.
  IF coalesce(v_player.pesdb_unavailable, false) OR v_age_exempt THEN
    v_wage := coalesce(v_player.contract_wage, p_wage, 0);
    v_ooo_uplift := false;
  ELSIF v_is_ooo THEN
    v_wage := round(coalesce(v_player.contract_wage, 0) * (1 + v_uplift_pct / 100.0), 0);
    v_ooo_uplift := true;
  ELSE
    v_wage := coalesce(v_player.contract_wage, p_wage, 0);
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
    'expiry_auction_exempt', true,
    'expiry_age_exempt', v_age_exempt,
    'one_of_our_own', v_is_ooo,
    'ooo_wage_uplift', v_ooo_uplift,
    'ooo_uplift_pct', CASE WHEN v_ooo_uplift THEN v_uplift_pct ELSE NULL END,
    'homegrown_u23', public.is_player_homegrown_u23(v_pid, v_club)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_ooo_renew_uplift_pct() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_player_expiry_age_exempt(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_player_expiry_auction_exempt(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_contract_renew(text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
