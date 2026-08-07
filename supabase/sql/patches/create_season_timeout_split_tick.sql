-- =============================================================================
-- Create Season timeout: split contract tick + batch zero-year releases
--
-- Symptom: competition_create_season → statement timeout / 500
-- Cause: create ran contract_tick_season_rollover() in the same RPC; releasing
--   many expired players one-by-one exceeded the API gateway timeout (~60s).
--
-- Fix:
--   1) competition_create_season does NOT tick contracts (fast create only)
--   2) contract_release_zero_year_players is set-based (FOREIGN buyer)
--   3) contract_tick_season_rollover raises local statement_timeout to 180s
-- Admin UI calls tick as a second step after create.
--
-- Run in Supabase SQL Editor, then retry Create Pre-Season.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Fast create season (no contract tick)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_create_season(p_label text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text := trim(p_label);
  v_season_id bigint;
  v_club_count bigint;
  v_prev bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_label IS NULL OR v_label = '' THEN
    RAISE EXCEPTION 'Season label is required';
  END IF;

  -- Idempotent-ish: refuse duplicate label
  IF EXISTS (
    SELECT 1 FROM public.competition_seasons s
    WHERE lower(btrim(s.label)) = lower(v_label)
  ) THEN
    RAISE EXCEPTION 'A season with label "%" already exists', v_label;
  END IF;

  INSERT INTO public.competition_seasons (label, status, is_current)
  VALUES (v_label, 'preseason', false)
  RETURNING id INTO v_season_id;

  INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
  SELECT v_season_id, c."ShortName", 'unassigned'
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
  ORDER BY c."ShortName";

  GET DIAGNOSTICS v_club_count = ROW_COUNT;

  IF v_club_count <> 60 THEN
    RAISE EXCEPTION 'Expected 60 clubs, found %', v_club_count;
  END IF;

  SELECT s.id INTO v_prev
  FROM public.competition_seasons s
  WHERE s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev IS NOT NULL THEN
    IF to_regprocedure('public.admin_gpdb_copy_season_exclusions(bigint, bigint)') IS NOT NULL
       AND (
         EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_players ep WHERE ep.season_id = v_prev
         )
         OR EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_nations en WHERE en.season_id = v_prev
         )
       )
    THEN
      PERFORM public.admin_gpdb_copy_season_exclusions(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_cup_prizes(bigint, bigint)') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_cup_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_cup_prizes(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_league_prizes(bigint, bigint)') IS NOT NULL
       AND to_regclass('public.competition_league_prize_config') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_league_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_league_prizes(v_prev, v_season_id);
    END IF;
  END IF;

  -- Contract tick is intentionally NOT here — call contract_tick_season_rollover()
  -- as a separate admin step (avoids API gateway timeouts).

  RETURN v_season_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_create_season(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Batch release expired contracts (FOREIGN buyer)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.contract_release_zero_year_players()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int := 0;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  CREATE TEMP TABLE IF NOT EXISTS _contract_expire_batch (
    player_id text PRIMARY KEY,
    club text NOT NULL,
    fee numeric NOT NULL DEFAULT 0
  ) ON COMMIT DROP;

  -- WHERE true: Supabase rejects DELETE without a WHERE clause
  DELETE FROM _contract_expire_batch WHERE true;

  INSERT INTO _contract_expire_batch (player_id, club, fee)
  SELECT
    p."Konami_ID"::text,
    public.player_contracted_club_key(p."Contracted_Team"),
    greatest(coalesce(p.market_value::numeric, 0), 0)
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining <= 0;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN 0;
  END IF;

  UPDATE public."Club_Finances" cf
  SET balance = cf.balance + x.total_fee
  FROM (
    SELECT club, sum(fee)::numeric AS total_fee
    FROM _contract_expire_batch
    GROUP BY club
  ) x
  WHERE cf.club_name = x.club;

  UPDATE public."Players" p
  SET
    "Contracted_Team" = NULL,
    "Season_Signed" = NULL,
    contract_seasons_remaining = NULL,
    contract_wage = NULL
  FROM _contract_expire_batch e
  WHERE p."Konami_ID"::text = e.player_id;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  SELECT
    e.player_id,
    e.club,
    'FOREIGN',
    e.fee,
    0,
    now(),
    NULL,
    'Contract expired (free agent)',
    'contract_expiry'
  FROM _contract_expire_batch e;

  RETURN v_count;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3) Contract tick with longer timeout
-- ---------------------------------------------------------------------------

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
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  UPDATE public."Players" p
  SET contract_seasons_remaining = contract_seasons_remaining - 1
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining >= 2;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

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

  v_released := public.contract_release_zero_year_players();

  SELECT count(*)::int
  INTO v_final
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'expiry_resolved', v_resolve,
    'players_decremented', v_updated,
    'players_contract_ended_no_bid', v_ended,
    'players_released_zero_years', v_released,
    'players_final_year', v_final
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_release_zero_year_players() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_season_rollover() TO authenticated;

NOTIFY pgrst, 'reload schema';
