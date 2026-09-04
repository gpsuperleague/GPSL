-- =============================================================================
-- Expiring contracts: exclude emergency / season loans
--
-- Stop-gap loans (club_emergency_loans + club_season_loans) are drafted in for
-- minimum-squad compliance. They use contract_seasons_remaining = 1 but are not
-- real expiry auctions — nobody should bid on them.
--
-- Fixes player_expiry_auction_applies() so list_expiring_contract_market() and
-- bid RPCs all skip loaned players.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.player_is_active_stopgap_loan(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(coalesce(p_player_id, ''));
BEGIN
  IF v_pid = '' THEN
    RETURN false;
  END IF;

  IF to_regclass('public.club_emergency_loans') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.club_emergency_loans l
      WHERE l.player_id = v_pid
        AND l.status = 'active'
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF to_regclass('public.club_season_loans') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.club_season_loans l
      WHERE l.player_id = v_pid
        AND l.status = 'active'
    ) THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$function$;

COMMENT ON FUNCTION public.player_is_active_stopgap_loan(text) IS
  'True when player is on an active emergency or August season loan (not an expiry auction candidate).';

GRANT EXECUTE ON FUNCTION public.player_is_active_stopgap_loan(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.player_expiry_auction_applies(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_seasons int;
  v_unavail boolean := false;
  v_team text;
  v_pid text := btrim(coalesce(p_player_id, ''));
BEGIN
  IF v_pid = '' THEN
    RETURN false;
  END IF;

  -- Emergency / season stop-gap loans never enter the expiry market
  IF public.player_is_active_stopgap_loan(v_pid) THEN
    RETURN false;
  END IF;

  SELECT
    p."Contracted_Team",
    coalesce(p.contract_seasons_remaining, 0)
  INTO v_team, v_seasons
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  BEGIN
    EXECUTE
      'SELECT coalesce(pesdb_unavailable, false)
       FROM public."Players"
       WHERE "Konami_ID"::text = $1'
    INTO v_unavail
    USING v_pid;
  EXCEPTION
    WHEN OTHERS THEN
      v_unavail := false;
  END;

  IF v_unavail THEN
    RETURN false;
  END IF;

  IF v_seasons <> 1 THEN
    RETURN false;
  END IF;

  BEGIN
    v_club := public.player_contracted_club_key(v_team);
  EXCEPTION
    WHEN OTHERS THEN
      v_club := nullif(btrim(coalesce(v_team, '')), '');
  END;

  IF v_club IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    IF public.is_player_expiry_auction_exempt(v_pid, v_club) THEN
      RETURN false;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RETURN false;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_expiry_auction_applies(text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
