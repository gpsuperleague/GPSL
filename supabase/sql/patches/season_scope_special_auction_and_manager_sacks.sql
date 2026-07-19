-- =============================================================================
-- Season scope: special auction settled results + manager sack quota on activate
--
-- 1) Owner "active" special auction no longer surfaces Season N-1 settled/revealed
--    results after Start season (pending prize for the winner still always shows).
-- 2) manager_reset_season_quotas() hooked into competition_reset_club_season_quotas()
--    so sack allowance resets with voluntary releases / foreign interest.
--
-- Safe re-run. Requires is_gpsl_admin SQL-editor friendly for catch-up SELECT.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_fetch_owner_active()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions;
  v_club text := public.my_club_shortname();
  v_season_start timestamptz;
BEGIN
  SELECT coalesce(s.started_at, s.created_at)
  INTO v_season_start
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  -- 1) Live / upcoming
  SELECT * INTO a
  FROM public.special_auctions
  WHERE status IN ('scheduled', 'active')
  ORDER BY start_time ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  -- 2) Settled with prize still pending for this club (any season — must resolve)
  IF v_club IS NOT NULL AND btrim(v_club) <> '' THEN
    SELECT * INTO a
    FROM public.special_auctions
    WHERE status = 'settled'
      AND coalesce(winner_prize_pending, false) = true
      AND upper(btrim(winning_club_id)) = upper(btrim(v_club))
    ORDER BY id DESC
    LIMIT 1;

    IF FOUND THEN
      RETURN public.special_auction_owner_json(a);
    END IF;
  END IF;

  -- 3) Recent settled — current season only
  SELECT * INTO a
  FROM public.special_auctions
  WHERE status = 'settled'
    AND coalesce(end_time, start_time, updated_at) > (now() - interval '7 days')
    AND (
      v_season_start IS NULL
      OR coalesce(end_time, start_time, updated_at) >= v_season_start
    )
  ORDER BY id DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  -- 4) Recent revealed — current season only
  SELECT * INTO a
  FROM public.special_auctions
  WHERE status = 'revealed'
    AND coalesce(end_time, start_time) > (now() - interval '7 days')
    AND (
      v_season_start IS NULL
      OR coalesce(end_time, start_time) >= v_season_start
    )
  ORDER BY id DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  RETURN NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_fetch_owner_active() TO authenticated;

COMMENT ON FUNCTION public.special_auction_fetch_owner_active() IS
  'Owner auction: live first; pending prize for winner; then current-season recent settled/revealed.';

-- Extend club season quota reset with manager sacks (1 per season)
CREATE OR REPLACE FUNCTION public.competition_reset_club_season_quotas()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_voluntary int;
  v_foreign int;
  v_manager boolean := false;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.club_reset_voluntary_contract_releases();
  PERFORM public.club_reset_foreign_interest_season();

  IF to_regprocedure('public.manager_reset_season_quotas()') IS NOT NULL THEN
    PERFORM public.manager_reset_season_quotas();
    v_manager := true;
  END IF;

  SELECT count(*)::int
  INTO v_voluntary
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
    AND coalesce(c.voluntary_contract_releases_remaining, 0) = 3;

  SELECT count(*)::int
  INTO v_foreign
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
    AND coalesce(c.foreign_interest_remaining, 0) = 3;

  RETURN jsonb_build_object(
    'ok', true,
    'clubs_voluntary_at_3', v_voluntary,
    'clubs_foreign_interest_at_3', v_foreign,
    'manager_sacks_reset', v_manager
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_reset_club_season_quotas() TO authenticated;

-- Catch-up manager sacks for the live season (safe if already 1)
SELECT public.competition_reset_club_season_quotas();

NOTIFY pgrst, 'reload schema';
