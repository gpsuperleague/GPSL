-- =============================================================================
-- Fix contract tick ORDER (critical before any catch-up)
--
-- Bug: tick did 2→1 first, then immediately set remaining=1 → 0 and released.
-- That wiped the new final-year cohort in the same rollover — expiring market
-- never had a season to collect bids.
--
-- Correct order when entering Season N+1:
--   1) Resolve / end players who ALREADY spent Season N at remaining=1
--   2) THEN decrement 3→2 and 2→1 (new final-year cohort for Season N+1)
--
-- Run this, then:
--   SELECT public.admin_catchup_player_contract_tick();
--   SELECT public.admin_season_contract_tick_status();
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_tick_season_rollover()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_resolve jsonb;
  v_updated int;
  v_ended   int;
  v_final   int;
  v_released int;
  v_out jsonb;
  v_newest record;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  -- 1) Finish the PRIOR final-year cohort (spent last season at remaining=1)
  IF to_regprocedure('public.contract_resolve_all_expiry_bids()') IS NOT NULL THEN
    v_resolve := public.contract_resolve_all_expiry_bids();
  ELSE
    v_resolve := jsonb_build_object('skipped', true);
  END IF;

  IF to_regprocedure('public.player_expiry_auction_applies(text)') IS NOT NULL THEN
    UPDATE public."Players" p
    SET contract_seasons_remaining = 0
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND p.contract_seasons_remaining = 1
      AND public.player_expiry_auction_applies(p."Konami_ID"::text);
  ELSE
    UPDATE public."Players" p
    SET contract_seasons_remaining = 0
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND p.contract_seasons_remaining = 1;
  END IF;

  GET DIAGNOSTICS v_ended = ROW_COUNT;

  v_released := 0;
  IF to_regprocedure('public.contract_release_zero_year_players()') IS NOT NULL THEN
    v_released := public.contract_release_zero_year_players();
  END IF;

  -- 2) Open the NEW final-year cohort for the season being entered (2→1, 3→2)
  UPDATE public."Players" p
  SET contract_seasons_remaining = contract_seasons_remaining - 1
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining >= 2;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT count(*)::int
  INTO v_final
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_out := jsonb_build_object(
    'ok', true,
    'expiry_resolved', v_resolve,
    'players_contract_ended_no_bid', v_ended,
    'players_released_zero_years', v_released,
    'players_decremented', v_updated,
    'players_final_year', v_final,
    'note', 'Resolve/release prior final-year first; then decrement so new final-year stay on market.'
  );

  SELECT s.id, s.label INTO v_newest
  FROM public.competition_seasons s
  ORDER BY s.id DESC
  LIMIT 1;

  IF to_regclass('public.competition_contract_tick_log') IS NOT NULL
     AND v_newest.id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.competition_contract_tick_log l
       WHERE l.for_season_id = v_newest.id
     )
  THEN
    INSERT INTO public.competition_contract_tick_log (for_season_id, for_season_label, result)
    VALUES (v_newest.id, v_newest.label, v_out);
  END IF;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_tick_season_rollover() TO authenticated;

NOTIFY pgrst, 'reload schema';
