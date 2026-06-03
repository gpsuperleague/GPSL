-- =============================================================================
-- Player signing / release hooks — Season_Signed + contract phase 1
-- Run in Supabase SQL Editor after competition_seasons + player_wage_settings.sql.
-- Then re-run (or run patches in) transferengine_*.sql, sell_to_foreign_club.sql,
-- special_auctions.sql if those functions were deployed before this file.
-- =============================================================================

-- Phase 1 contract fields on Players (full renew/expiry market = later phases)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Players'
      AND column_name = 'contract_seasons_remaining'
  ) THEN
    ALTER TABLE public."Players"
      ADD COLUMN contract_seasons_remaining smallint
      CHECK (
        contract_seasons_remaining IS NULL
        OR (contract_seasons_remaining >= 0 AND contract_seasons_remaining <= 3)
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Players'
      AND column_name = 'contract_wage'
  ) THEN
    ALTER TABLE public."Players"
      ADD COLUMN contract_wage numeric;
  END IF;
END $$;

-- Current GPSL season label (competition season marked current + active)
CREATE OR REPLACE FUNCTION public.current_gpsl_season_label()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text;
BEGIN
  SELECT s.label
  INTO v_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status = 'active'
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_label IS NOT NULL AND btrim(v_label) <> '' THEN
    RETURN btrim(v_label);
  END IF;

  SELECT s.label
  INTO v_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN NULLIF(btrim(coalesce(v_label, '')), '');
END;
$function$;

-- Assign player to club: current season, fresh 3-year contract, standard wage
CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_club_short_name);
  v_season text;
  v_wage numeric;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  v_season := public.current_gpsl_season_label();
  v_wage := public.calculate_player_wage_for_club(v_pid, v_club);

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season,
    contract_seasons_remaining = 3,
    contract_wage = v_wage
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

-- Release player from club: clear club, season signed, contract fields
CREATE OR REPLACE FUNCTION public.player_release_from_club(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_release_from_club: player_id is required';
  END IF;

  UPDATE public."Players"
  SET
    "Contracted_Team" = NULL,
    "Season_Signed" = NULL,
    contract_seasons_remaining = NULL,
    contract_wage = NULL
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

-- Same-season transfer lock (signed this season → no sale/list/offers until next season)
CREATE OR REPLACE FUNCTION public.player_signed_this_season(p_season_signed text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT btrim(coalesce(p_season_signed, '')) <> ''
    AND btrim(coalesce(p_season_signed, '')) = coalesce(public.current_gpsl_season_label(), '');
$$;

CREATE OR REPLACE FUNCTION public.assert_player_transferable(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_signed text;
BEGIN
  SELECT p."Season_Signed"
  INTO v_signed
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_signed_this_season(v_signed) THEN
    RAISE EXCEPTION
      'This player was signed in the current season and cannot be sold or listed until the next season.';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_listing_block_same_season_sale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.player_id IS NULL OR btrim(NEW.player_id::text) = '' THEN
    RETURN NEW;
  END IF;
  PERFORM public.assert_player_transferable(btrim(NEW.player_id::text));
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_transfer_bid_block_same_season_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
BEGIN
  v_player_id := btrim(coalesce(NEW.player_id, NEW.direct_bid_id::text, ''));

  IF v_player_id = '' AND NEW.listing_id IS NOT NULL THEN
    SELECT btrim(l.player_id::text)
    INTO v_player_id
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_player_id IS NULL OR v_player_id = '' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(v_player_id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_listings_same_season_block ON public."Player_Transfer_Listings";
CREATE TRIGGER player_transfer_listings_same_season_block
  BEFORE INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_listing_block_same_season_sale();

DROP TRIGGER IF EXISTS player_transfer_bids_same_season_block ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_same_season_block
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_transfer_bid_block_same_season_player();

GRANT EXECUTE ON FUNCTION public.current_gpsl_season_label() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_assign_to_club(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_release_from_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_signed_this_season(text) TO authenticated;
