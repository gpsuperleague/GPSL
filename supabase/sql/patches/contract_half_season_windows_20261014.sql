-- =============================================================================
-- Contract selling windows by half-season (2026-10-14)
-- =============================================================================
-- Every contract is 3 years from the window the player joined in.
--
--   Summer contract (joined June–December, first half of the GPSL season):
--     season 1  locked (signed this season)
--     season 2  sellable
--     season 3  final year: sellable until GPSL January unlocks, then locked;
--               expiry wage bids open from GPSL January; resolves at the
--               summer rollover (unchanged).
--
--   January contract (joined from GPSL January to the end of the season):
--     contract_end_window = 'january', starts on 4 "seasons remaining" so it
--     still ticks at every summer rollover:
--       4  rest of the joining season — locked (signed this season)
--       3  next season — locked until GPSL January (one full season), then sellable
--       2  sellable (final contract year starts at GPSL January)
--       1  first half of the season — locked; expiry wage bids open;
--          resolves when GPSL January unlocks (contract_january_switch_run).
--
--   Renewals keep the contract's end window and use the existing renew RPCs.
--   Only a move to a new club (not a renewal) can start a January contract or
--   the extra half-season lock.
--
-- Pieces:
--   Players.contract_end_window ('summer' | 'january')
--   Players.contract_join_second_half (joined club after GPSL January unlocked)
--   gpsl_season_second_half()          — GPSL January unlocked, season not over
--   gpsl_contract_phase()              — client helper (half + season labels)
--   player_contract_sell_lock_reason() — single sell rule
--   assert_player_transferable()       — listing / sale / bid gate uses it
--   player_expiry_bidding_open()       — expiry bids only in the final half
--   contract_january_switch_run()      — January expiry for January contracts
--   contract_close_locked_listings()   — closes listings once a player locks
--   cron 'gpsl-contract-half-switch'   — every 15 min
--   summer rollover steps only touch summer contracts.
-- Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS contract_end_window text NOT NULL DEFAULT 'summer';

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS contract_join_second_half boolean NOT NULL DEFAULT false;

DO $c$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'players_contract_end_window_check'
  ) THEN
    ALTER TABLE public."Players"
      ADD CONSTRAINT players_contract_end_window_check
      CHECK (contract_end_window IN ('summer', 'january'));
  END IF;
END;
$c$;

COMMENT ON COLUMN public."Players".contract_end_window IS
  'summer = contract ends at the summer rollover; january = ends when GPSL January unlocks.';
COMMENT ON COLUMN public."Players".contract_join_second_half IS
  'Joined the club after GPSL January unlocked — locked until GPSL January of the next season.';

-- ---------------------------------------------------------------------------
-- 2. Season half helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_season_second_half(p_at timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.current_gpsl_season_id();
  v_jan timestamptz;
  v_end timestamptz;
BEGIN
  IF v_season IS NULL THEN
    RETURN false;
  END IF;

  SELECT m.unlock_at INTO v_jan
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season AND m.gpsl_month = 'january';

  IF v_jan IS NULL OR p_at < v_jan THEN
    RETURN false;
  END IF;

  SELECT max(m.lock_at) INTO v_end
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season;

  RETURN v_end IS NULL OR p_at < v_end;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_season_second_half(timestamptz) IS
  'True from GPSL January unlock until the current season''s last month locks.';

CREATE OR REPLACE FUNCTION public.gpsl_previous_season_label()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT nullif(btrim(s.label), '')
  FROM public.competition_seasons s
  WHERE s.id < public.current_gpsl_season_id()
    AND coalesce(s.status, '') <> 'setup'
  ORDER BY s.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_contract_phase()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'second_half', public.gpsl_season_second_half(),
    'current_season_id', public.current_gpsl_season_id(),
    'current_label', public.current_gpsl_season_label(),
    'previous_label', public.gpsl_previous_season_label()
  );
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_season_second_half(timestamptz) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_previous_season_label() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_contract_phase() TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- 3. New club → summer or January contract (renewals keep their window)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_players_contract_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_january_run boolean :=
    coalesce(nullif(current_setting('gpsl.expiry_end_window', true), ''), '') = 'january';
  v_second boolean;
BEGIN
  IF nullif(btrim(coalesce(NEW."Contracted_Team", '')), '') IS NULL THEN
    NEW.contract_end_window := 'summer';
    NEW.contract_join_second_half := false;
    RETURN NEW;
  END IF;

  IF btrim(coalesce(NEW."Contracted_Team", '')) IS DISTINCT FROM btrim(coalesce(OLD."Contracted_Team", '')) THEN
    v_second := v_january_run OR public.gpsl_season_second_half();
    NEW.contract_join_second_half := v_second;
    IF NEW.contract_seasons_remaining = 3 THEN
      IF v_second THEN
        NEW.contract_end_window := 'january';
        NEW.contract_seasons_remaining := 4;
      ELSE
        NEW.contract_end_window := 'summer';
      END IF;
    END IF;
  ELSIF NEW."Season_Signed" IS DISTINCT FROM OLD."Season_Signed" THEN
    NEW.contract_join_second_half := false;
    -- Holder wins its own January-contract player on the expiry market: fresh 3-year deal
    IF v_january_run
       AND NEW.contract_end_window = 'january'
       AND NEW.contract_seasons_remaining = 3 THEN
      NEW.contract_seasons_remaining := 4;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS players_contract_window ON public."Players";
CREATE TRIGGER players_contract_window
  BEFORE UPDATE OF "Contracted_Team", "Season_Signed", contract_seasons_remaining
  ON public."Players"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_players_contract_window();

-- ---------------------------------------------------------------------------
-- 4. Single sell rule
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.player_contract_sell_lock_reason(p_player_id text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_p record;
  v_second boolean;
BEGIN
  SELECT
    nullif(btrim(p."Contracted_Team"::text), '') AS club,
    nullif(btrim(p."Season_Signed"), '') AS signed,
    p.contract_seasons_remaining AS rem,
    coalesce(p.contract_end_window, 'summer') AS end_window,
    coalesce(p.contract_join_second_half, false) AS joined_second_half,
    coalesce(p.pesdb_unavailable, false) AS legacy
  INTO v_p
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;
  IF v_p.legacy THEN
    RETURN 'legacy';
  END IF;
  IF v_p.club IS NULL THEN
    RETURN NULL;
  END IF;
  IF public.player_is_active_stopgap_loan(v_pid) THEN
    RETURN 'loan';
  END IF;
  IF public.player_signed_this_season(v_p.signed) THEN
    RETURN 'signed_this_season';
  END IF;

  v_second := public.gpsl_season_second_half();

  IF v_p.joined_second_half
     AND NOT v_second
     AND v_p.signed IS NOT DISTINCT FROM public.gpsl_previous_season_label() THEN
    RETURN 'signed_last_season_half';
  END IF;

  IF v_p.rem IS NOT NULL AND v_p.rem <= 0 THEN
    RETURN 'contract_ended';
  END IF;

  IF v_p.rem = 1 AND (v_p.end_window = 'january' OR v_second) THEN
    RETURN 'final_half';
  END IF;

  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.player_contract_sell_lock_reason(text) IS
  'NULL when the player may be listed/sold now; otherwise legacy / loan / signed_this_season / signed_last_season_half / contract_ended / final_half.';

GRANT EXECUTE ON FUNCTION public.player_contract_sell_lock_reason(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.assert_player_transferable(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_reason text := public.player_contract_sell_lock_reason(p_player_id);
BEGIN
  IF v_reason IS NULL THEN
    RETURN;
  END IF;

  CASE v_reason
    WHEN 'not_found' THEN
      RAISE EXCEPTION 'Player not found';
    WHEN 'legacy' THEN
      RAISE EXCEPTION
        'This player card is no longer on pesdb.net (legacy card). It cannot be sold, listed, or signed until it returns on a PESDB sync.';
    WHEN 'loan' THEN
      RAISE EXCEPTION 'Emergency / season loan players cannot be sold or listed.';
    WHEN 'signed_this_season' THEN
      RAISE EXCEPTION
        'This player was signed this season and cannot be sold or listed yet (one-season lock after signing).';
    WHEN 'signed_last_season_half' THEN
      RAISE EXCEPTION
        'This player joined after GPSL January last season — one-season lock until GPSL January.';
    WHEN 'contract_ended' THEN
      RAISE EXCEPTION 'This player''s contract has ended and cannot be sold or listed.';
    WHEN 'final_half' THEN
      RAISE EXCEPTION
        'Player is in the final half of their contract and cannot be sold or listed. Renew (if eligible) or use the expiry wage market.';
    ELSE
      RAISE EXCEPTION 'This player cannot be sold or listed right now (%).', v_reason;
  END CASE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.assert_player_transferable(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Expiry wage bids only in the final half
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.player_expiry_bidding_open(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_window text;
BEGIN
  IF NOT public.player_expiry_auction_applies(p_player_id) THEN
    RETURN false;
  END IF;

  SELECT coalesce(p.contract_end_window, 'summer') INTO v_window
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  RETURN v_window = 'january' OR public.gpsl_season_second_half();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_expiry_bidding_open(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.trg_expiry_wage_bid_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(nullif(current_setting('gpsl.expiry_bid_bypass', true), ''), '') = 'on' THEN
    RETURN NEW;
  END IF;

  IF NOT public.player_expiry_bidding_open(NEW.player_id) THEN
    RAISE EXCEPTION
      'Expiry wage bids for this player are not open yet — they open for the final half of the contract (from GPSL January for summer contracts).';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS contract_expiry_wage_bid_window ON public.contract_expiry_wage_bids;
CREATE TRIGGER contract_expiry_wage_bid_window
  BEFORE INSERT ON public.contract_expiry_wage_bids
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_expiry_wage_bid_window();

-- Expiring Contracts market: flag whether bids are open yet
DO $mkt$
DECLARE
  v_sig regprocedure := to_regprocedure('public.list_expiring_contract_market()');
  v_def text;
  v_old text := '''season_label'', v_season';
  v_new text := '''season_label'', v_season,
          ''bidding_open'', public.player_expiry_bidding_open(v_row.player_id),
          ''contract_end_window'', (
            SELECT coalesce(px.contract_end_window, ''summer'')
            FROM public."Players" px
            WHERE px."Konami_ID"::text = v_row.player_id
          )';
BEGIN
  IF v_sig IS NULL THEN
    RAISE NOTICE 'list_expiring_contract_market not found — skipped';
    RETURN;
  END IF;
  v_def := pg_get_functiondef(v_sig);
  IF position('bidding_open' IN v_def) > 0 THEN
    RAISE NOTICE 'list_expiring_contract_market already patched';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'list_expiring_contract_market: marker not found — skipped';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$mkt$;

-- ---------------------------------------------------------------------------
-- 6. Summer rollover only handles summer contracts
-- ---------------------------------------------------------------------------
DO $roll$
DECLARE
  v_fn text;
  v_sig regprocedure;
  v_def text;
  v_old text := 'p.contract_seasons_remaining = 1';
  v_new text := 'p.contract_seasons_remaining = 1 AND coalesce(p.contract_end_window, ''summer'') = ''summer''';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'contract_tick_rollover_step_fa',
    'contract_tick_rollover_step_decrement',
    'contract_tick_rollover_step_contested',
    'contract_tick_season_rollover'
  ]
  LOOP
    v_sig := to_regprocedure(format('public.%s()', v_fn));
    IF v_sig IS NULL THEN
      RAISE NOTICE '% not found — skipped', v_fn;
      CONTINUE;
    END IF;
    v_def := pg_get_functiondef(v_sig);
    IF position('contract_end_window' IN v_def) > 0 THEN
      RAISE NOTICE '% already summer-only', v_fn;
      CONTINUE;
    END IF;
    IF position(v_old IN v_def) = 0 THEN
      RAISE NOTICE '% has no final-year predicate — skipped', v_fn;
      CONTINUE;
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
    RAISE NOTICE '% now summer-only', v_fn;
  END LOOP;
END;
$roll$;

-- Expiry resolver: filter by end window (default summer; January run sets the GUC)
DO $res$
DECLARE
  v_sig regprocedure := to_regprocedure('public.contract_resolve_all_expiry_bids(bigint,text)');
  v_def text;
  v_old text := 'WHERE public.player_expiry_auction_applies(p."Konami_ID"::text)';
  v_new text := 'WHERE public.player_expiry_auction_applies(p."Konami_ID"::text)
      AND coalesce(p.contract_end_window, ''summer'')
        = coalesce(nullif(current_setting(''gpsl.expiry_end_window'', true), ''''), ''summer'')';
BEGIN
  IF v_sig IS NULL THEN
    RAISE EXCEPTION 'contract_resolve_all_expiry_bids(bigint,text) not found';
  END IF;
  v_def := pg_get_functiondef(v_sig);
  IF position('gpsl.expiry_end_window' IN v_def) > 0 THEN
    RAISE NOTICE 'contract_resolve_all_expiry_bids already window-aware';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'contract_resolve_all_expiry_bids: loop marker not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$res$;

-- ---------------------------------------------------------------------------
-- 7. Close listings for players who have become locked
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_close_locked_listings()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
BEGIN
  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = NULL,
      winning_club = NULL
  WHERE l.status IN ('Active', 'Pending Window')
    AND lower(coalesce(l.listing_type::text, '')) <> 'draft'
    AND nullif(btrim(coalesce(l.seller_club_id::text, '')), '') IS NOT NULL
    AND NOT coalesce(l.new_owner_slot, false)
    AND NOT coalesce(l.perpetual_renew, false)
    AND l.current_highest_bid IS NULL
    AND public.player_contract_sell_lock_reason(l.player_id::text) IS NOT NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. January switch: expiry for January contracts
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.contract_january_switch_log (
  season_id bigint PRIMARY KEY,
  season_label text,
  ran_at timestamptz NOT NULL DEFAULT now(),
  result jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE public.contract_january_switch_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contract_january_switch_log_read ON public.contract_january_switch_log;
CREATE POLICY contract_january_switch_log_read ON public.contract_january_switch_log
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

CREATE OR REPLACE FUNCTION public.contract_january_switch_run(p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.current_gpsl_season_id();
  v_label text := public.current_gpsl_season_label();
  v_fa int := 0;
  v_released int := 0;
  v_released_left int := 0;
  v_resolve jsonb := '{}'::jsonb;
  v_closed int := 0;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL OR v_label IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF NOT p_force AND NOT public.gpsl_season_second_half() THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'gpsl_january_not_unlocked');
  END IF;

  IF NOT p_force AND EXISTS (
    SELECT 1 FROM public.contract_january_switch_log WHERE season_id = v_season
  ) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_ran');
  END IF;

  PERFORM set_config('statement_timeout', '300s', true);
  PERFORM set_config('gpsl.expiry_end_window', 'january', true);

  -- Unrenewed, no wage bids → free agent (holder gets market value)
  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1
    AND coalesce(p.contract_end_window, 'summer') = 'january'
    AND NOT public.player_is_active_stopgap_loan(p."Konami_ID"::text)
    AND NOT EXISTS (
      SELECT 1 FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = p."Konami_ID"::text
    );
  GET DIAGNOSTICS v_fa = ROW_COUNT;

  IF v_fa > 0 THEN
    v_released := public.contract_release_zero_year_players(v_season);
  END IF;

  v_resolve := public.contract_resolve_all_expiry_bids(v_season, v_label);

  -- Anything still on a finished January contract → free agent
  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1
    AND coalesce(p.contract_end_window, 'summer') = 'january'
    AND NOT public.player_is_active_stopgap_loan(p."Konami_ID"::text);
  IF FOUND THEN
    v_released_left := public.contract_release_zero_year_players(v_season);
  END IF;

  PERFORM set_config('gpsl.expiry_end_window', '', true);

  v_closed := public.contract_close_locked_listings();

  v_result := jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'season_label', v_label,
    'free_agents_no_bids', v_released,
    'expiry_resolved', v_resolve,
    'free_agents_leftover', v_released_left,
    'listings_closed', v_closed
  );

  INSERT INTO public.contract_january_switch_log (season_id, season_label, ran_at, result)
  VALUES (v_season, v_label, now(), v_result)
  ON CONFLICT (season_id) DO UPDATE
    SET ran_at = excluded.ran_at, result = excluded.result, season_label = excluded.season_label;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.contract_january_switch_run(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.contract_january_switch_run(boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.contract_half_switch_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_jan jsonb := NULL;
  v_closed int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF public.gpsl_season_second_half()
     AND NOT EXISTS (
       SELECT 1 FROM public.contract_january_switch_log
       WHERE season_id = public.current_gpsl_season_id()
     ) THEN
    v_jan := public.contract_january_switch_run(false);
  END IF;

  v_closed := public.contract_close_locked_listings();

  RETURN jsonb_build_object('ok', true, 'january_switch', v_jan, 'listings_closed', v_closed);
END;
$function$;

REVOKE ALL ON FUNCTION public.contract_half_switch_tick() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.contract_half_switch_tick() TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-contract-half-switch') THEN
      PERFORM cron.unschedule('gpsl-contract-half-switch');
    END IF;
    PERFORM cron.schedule(
      'gpsl-contract-half-switch',
      '*/15 * * * *',
      $job$SELECT public.contract_half_switch_tick();$job$
    );
  ELSE
    RAISE NOTICE 'pg_cron not installed — run SELECT public.contract_half_switch_tick(); after GPSL January unlocks';
  END IF;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------
SELECT 'phase' AS section, public.gpsl_contract_phase()::text AS detail, NULL::bigint AS players
UNION ALL
SELECT 'contracts by end window / seasons left',
       coalesce(p.contract_end_window, 'summer') || ' · ' || coalesce(p.contract_seasons_remaining::text, 'null'),
       count(*)
FROM public."Players" p
WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
GROUP BY coalesce(p.contract_end_window, 'summer'), coalesce(p.contract_seasons_remaining::text, 'null')
UNION ALL
SELECT 'sell lock reason',
       coalesce(public.player_contract_sell_lock_reason(p."Konami_ID"::text), 'sellable'),
       count(*)
FROM public."Players" p
WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
GROUP BY coalesce(public.player_contract_sell_lock_reason(p."Konami_ID"::text), 'sellable')
UNION ALL
SELECT 'cron', jobname || ' ' || schedule, NULL
FROM cron.job WHERE jobname = 'gpsl-contract-half-switch'
ORDER BY 1, 2;
