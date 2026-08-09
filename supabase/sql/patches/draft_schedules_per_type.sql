-- =============================================================================
-- Separate draft timers: player / manager / club
--
-- Player keeps draft_auction_start_time + draft_random_finish_time.
-- Manager/club get their own start/finish columns.
--
-- Run whole file in Supabase SQL Editor. Safe re-run.
-- Then hard-refresh admin + owner pages (APP_VERSION bump ships with JS).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Columns + backfill
-- ---------------------------------------------------------------------------
ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS manager_draft_auction_start_time timestamptz,
  ADD COLUMN IF NOT EXISTS manager_draft_random_finish_time timestamptz,
  ADD COLUMN IF NOT EXISTS club_auction_start_time timestamptz,
  ADD COLUMN IF NOT EXISTS club_auction_random_finish_time timestamptz;

UPDATE public.global_settings
SET
  manager_draft_auction_start_time = coalesce(
    manager_draft_auction_start_time,
    draft_auction_start_time
  ),
  manager_draft_random_finish_time = coalesce(
    manager_draft_random_finish_time,
    draft_random_finish_time
  ),
  club_auction_start_time = coalesce(
    club_auction_start_time,
    draft_auction_start_time
  ),
  club_auction_random_finish_time = coalesce(
    club_auction_random_finish_time,
    draft_random_finish_time
  ),
  updated_at = now()
WHERE id = 1;

-- ---------------------------------------------------------------------------
-- 2) global_settings_public (per-type open + revealed)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  manager_draft_auction_enabled,
  club_auction_enabled,
  draft_auction_start_time,
  manager_draft_auction_start_time,
  club_auction_start_time,
  updated_at,
  league_phase,
  wage_pct_superleague,
  wage_pct_championship,
  stadium_cost_tier1,
  stadium_cost_tier2,
  stadium_cost_tier3,
  stadium_capacity_tier_mid,
  stadium_capacity_tier_high,
  stadium_expansion_cancel_penalty,
  hg_sub_band1_max,
  hg_sub_band1_per_player,
  hg_sub_band2_max,
  hg_sub_band2_per_player,
  hg_sub_band3_per_player,
  youth_sub_band1_max,
  youth_sub_band1_per_player,
  youth_sub_band2_max,
  youth_sub_band2_per_player,
  youth_sub_band3_max,
  youth_sub_band3_per_player,
  youth_sub_band4_per_player,
  bnb_max_rating,
  bnb_min_players,
  bnb_per_player,
  tv_per_match_amount,
  tv_matches_per_month,
  tv_club_min_season,
  tv_club_max_season,
  tv_weight_top8_clash,
  tv_weight_title_race,
  tv_weight_promotion,
  tv_weight_relegation,
  tv_weight_super8,
  tv_weight_playoff,
  tv_weight_dry_spell,
  tv_weight_below_min,
  challenge_default_prize,
  challenge_period_bonus,
  wage_34plus_min_rating,
  wage_34plus_per_player,
  star_tax_min_rating,
  star_tax_per_player,
  emergency_tac_pct,
  emergency_tac_threshold,
  gov_income_tax_pct,
  (
    COALESCE(draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS draft_bidding_open,
  (
    COALESCE(manager_draft_auction_enabled, false)
    AND manager_draft_auction_start_time IS NOT NULL
    AND manager_draft_random_finish_time IS NOT NULL
    AND now() >= manager_draft_auction_start_time
    AND now() < manager_draft_random_finish_time
  ) AS manager_draft_bidding_open,
  (
    COALESCE(club_auction_enabled, false)
    AND club_auction_start_time IS NOT NULL
    AND club_auction_random_finish_time IS NOT NULL
    AND now() >= club_auction_start_time
    AND now() < club_auction_random_finish_time
  ) AS club_auction_bidding_open,
  CASE
    WHEN draft_random_finish_time IS NOT NULL
     AND now() >= draft_random_finish_time
    THEN draft_random_finish_time
    ELSE NULL
  END AS draft_random_finish_revealed,
  CASE
    WHEN manager_draft_random_finish_time IS NOT NULL
     AND now() >= manager_draft_random_finish_time
    THEN manager_draft_random_finish_time
    ELSE NULL
  END AS manager_draft_random_finish_revealed,
  CASE
    WHEN club_auction_random_finish_time IS NOT NULL
     AND now() >= club_auction_random_finish_time
    THEN club_auction_random_finish_time
    ELSE NULL
  END AS club_auction_random_finish_revealed
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

-- ---------------------------------------------------------------------------
-- 3) Kind-aware schedule RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_draft_schedule(
  p_kind text,
  p_start timestamptz,
  p_finish timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_kind text := lower(btrim(coalesce(p_kind, '')));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_kind NOT IN ('player', 'manager', 'club') THEN
    RAISE EXCEPTION 'p_kind must be player, manager, or club';
  END IF;

  IF v_kind = 'player' THEN
    UPDATE public.global_settings
    SET draft_auction_start_time = p_start,
        draft_random_finish_time = p_finish,
        updated_at = now()
    WHERE id = 1;
  ELSIF v_kind = 'manager' THEN
    UPDATE public.global_settings
    SET manager_draft_auction_start_time = p_start,
        manager_draft_random_finish_time = p_finish,
        updated_at = now()
    WHERE id = 1;
  ELSE
    UPDATE public.global_settings
    SET club_auction_start_time = p_start,
        club_auction_random_finish_time = p_finish,
        updated_at = now()
    WHERE id = 1;
  END IF;
END;
$function$;

-- Legacy wrapper → player clock only
CREATE OR REPLACE FUNCTION public.admin_set_draft_auction_schedule(
  p_start timestamptz,
  p_finish timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.admin_set_draft_schedule('player', p_start, p_finish);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_draft_schedule(text, timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_draft_auction_schedule(timestamptz, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_reset_draft_auction()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not authorized to reset draft auction';
  END IF;

  UPDATE public.global_settings
  SET draft_auction_enabled = false,
      manager_draft_auction_enabled = false,
      club_auction_enabled = false,
      draft_random_finish_time = null,
      draft_auction_start_time = null,
      manager_draft_auction_start_time = null,
      manager_draft_random_finish_time = null,
      club_auction_start_time = null,
      club_auction_random_finish_time = null,
      updated_at = now()
  WHERE id = 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_reset_draft_auction() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) Club bidding open + state RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_auction_bidding_open_now()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE(gs.club_auction_enabled, false)
    AND gs.club_auction_start_time IS NOT NULL
    AND gs.club_auction_random_finish_time IS NOT NULL
    AND now() >= gs.club_auction_start_time
    AND now() < gs.club_auction_random_finish_time
  FROM public.global_settings gs
  WHERE gs.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.club_auction_get_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs public.global_settings%rowtype;
BEGIN
  SELECT * INTO v_gs FROM public.global_settings WHERE id = 1;

  RETURN jsonb_build_object(
    'enabled', coalesce(v_gs.club_auction_enabled, false),
    'bidding_open', public.club_auction_bidding_open_now(),
    'start_time', v_gs.club_auction_start_time,
    'finish_time',
      CASE
        WHEN v_gs.club_auction_random_finish_time IS NOT NULL
         AND now() >= v_gs.club_auction_random_finish_time
        THEN v_gs.club_auction_random_finish_time
        ELSE NULL
      END,
    'bid_increment', public.club_auction_bid_increment(),
    'active_listings',
      (SELECT count(*)::int
       FROM public."Club_Auction_Listings" l
       WHERE l.status = 'Active')
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5) Manager bid guard → manager clock
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_manager_transfer_bids_draft_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
  v_start   timestamptz;
  v_finish  timestamptz;
  v_is_draft boolean;
  v_other_mid bigint;
BEGIN
  IF public.club_has_signed_manager(NEW.bidder_club_id) THEN
    RAISE EXCEPTION
      'Your club already has a manager — sack or transfer them before bidding on another';
  END IF;

  v_is_draft := (
    COALESCE(NEW.is_first_draft_bid, false)
    OR COALESCE(NEW.is_draft_join, false)
    OR (
      NEW.listing_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public."Manager_Transfer_Listings" l
        WHERE l.id = NEW.listing_id AND l.listing_type = 'draft'
      )
    )
  );

  IF NOT v_is_draft THEN
    RETURN NEW;
  END IF;

  SELECT
    manager_draft_auction_enabled,
    manager_draft_auction_start_time,
    manager_draft_random_finish_time
  INTO v_enabled, v_start, v_finish
  FROM public.global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'Manager draft auction is not enabled';
  END IF;

  IF v_start IS NOT NULL AND now() < v_start THEN
    RAISE EXCEPTION 'Manager draft auction has not started yet';
  END IF;

  IF v_start IS NOT NULL AND v_finish IS NULL THEN
    v_finish := v_start + interval '23 hours 59 minutes 59 seconds';
  END IF;

  IF v_finish IS NOT NULL AND now() >= v_finish THEN
    RAISE EXCEPTION 'Manager draft bidding has closed';
  END IF;

  PERFORM public.manager_assert_not_sack_blocked(NEW.bidder_club_id, NEW.manager_id);

  SELECT l.manager_id INTO v_other_mid
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
    AND l.manager_id <> NEW.manager_id
    AND l.current_highest_bidder = NEW.bidder_club_id
  LIMIT 1;

  IF v_other_mid IS NOT NULL THEN
    RAISE EXCEPTION 'You may only hold the highest bid on one manager draft auction at a time';
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6) Independent settle gates
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_settle_manager_draft_auctions_only()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
  v_mgr_listing public."Manager_Transfer_Listings"%rowtype;
  v_now timestamptz := now();
BEGIN
  SELECT manager_draft_random_finish_time INTO v_finish
  FROM public.global_settings
  WHERE id = 1;

  IF v_finish IS NULL OR v_now < v_finish THEN
    RETURN;
  END IF;

  FOR v_mgr_listing IN
    SELECT *
    FROM public."Manager_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active'
    ORDER BY id
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_manager_draft_sale(v_mgr_listing.id);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'Manager draft listing % failed: % (SQLSTATE %)',
          v_mgr_listing.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_settle_club_auctions_only()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_now timestamptz := now();
BEGIN
  SELECT club_auction_random_finish_time INTO v_finish
  FROM public.global_settings
  WHERE id = 1;

  -- Finish gate only (ignore enabled toggle so residue can settle after admin turns Off)
  IF v_finish IS NULL OR v_now < v_finish THEN
    RETURN;
  END IF;

  FOR v_listing IN
    SELECT *
    FROM public."Club_Auction_Listings"
    WHERE status = 'Active'
    ORDER BY id
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_club_auction_sale(v_listing.id);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING 'Club auction listing % failed: % (SQLSTATE %)',
          v_listing.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_now timestamptz := now();
  v_mgr_active int;
  v_club_active int;
  v_player_draft_active int;
  v_should_settle_players boolean;
  v_should_settle_managers boolean;
  v_should_settle_clubs boolean;
  v_any_work boolean := false;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time,
    manager_draft_random_finish_time,
    club_auction_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_mgr_active
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  SELECT count(*)::int INTO v_club_active
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  SELECT count(*)::int INTO v_player_draft_active
  FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  v_should_settle_managers :=
    v_mgr_active > 0
    AND v_settings.manager_draft_random_finish_time IS NOT NULL
    AND v_now >= v_settings.manager_draft_random_finish_time;

  v_should_settle_players :=
    v_player_draft_active > 0
    AND v_settings.draft_random_finish_time IS NOT NULL
    AND v_now >= v_settings.draft_random_finish_time
    AND NOT public.transferengine_standard_listings_block_draft_settlement(
      v_now,
      v_settings.draft_random_finish_time
    );

  v_should_settle_clubs :=
    v_club_active > 0
    AND v_settings.club_auction_random_finish_time IS NOT NULL
    AND v_now >= v_settings.club_auction_random_finish_time;

  v_any_work := v_should_settle_managers OR v_should_settle_players OR v_should_settle_clubs;
  IF NOT v_any_work THEN
    RETURN;
  END IF;

  -- Standard listings only needed when player draft may settle (same-evening block)
  IF v_should_settle_players OR v_should_settle_managers THEN
    PERFORM public.transferengine_process_standard_listings(v_now);
  END IF;

  IF v_should_settle_managers THEN
    PERFORM public.transferengine_settle_manager_draft_auctions_only();
  END IF;

  IF v_should_settle_players THEN
    PERFORM public.transferengine_settle_player_draft_listings(100);
  END IF;

  IF v_should_settle_clubs
     AND to_regprocedure('public.transferengine_settle_club_auctions_only()') IS NOT NULL THEN
    PERFORM public.transferengine_settle_club_auctions_only();
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7) Inbox notify — per-type starts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_inbox_notify_draft_schedule_from_settings(
  p_old public.global_settings,
  p_new public.global_settings
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start text;
  v_player_on boolean;
  v_manager_on boolean;
  v_player_notify boolean;
  v_manager_notify boolean;
  v_dedupe_ts text;
  v_player_start_changed boolean;
  v_manager_start_changed boolean;
BEGIN
  v_player_on := coalesce(p_new.draft_auction_enabled, false);
  v_manager_on := coalesce(p_new.manager_draft_auction_enabled, false);
  v_player_start_changed :=
    p_new.draft_auction_start_time IS DISTINCT FROM p_old.draft_auction_start_time;
  v_manager_start_changed :=
    p_new.manager_draft_auction_start_time IS DISTINCT FROM p_old.manager_draft_auction_start_time;

  v_player_notify := v_player_on
    AND p_new.draft_auction_start_time IS NOT NULL
    AND (
      v_player_start_changed
      OR (v_player_on AND NOT coalesce(p_old.draft_auction_enabled, false))
    );

  v_manager_notify := v_manager_on
    AND p_new.manager_draft_auction_start_time IS NOT NULL
    AND (
      v_manager_start_changed
      OR (v_manager_on AND NOT coalesce(p_old.manager_draft_auction_enabled, false))
    );

  IF NOT v_player_notify AND NOT v_manager_notify THEN
    RETURN;
  END IF;

  v_dedupe_ts := floor(extract(epoch FROM coalesce(p_new.updated_at, now())))::text;

  IF v_player_notify THEN
    v_start := to_char(
      p_new.draft_auction_start_time AT TIME ZONE 'Europe/London',
      'Dy DD Mon YYYY HH24:MI'
    );
    PERFORM public.owner_inbox_notify_all_clubs(
      'draft_scheduled',
      'Player draft auction scheduled',
      format(
        E'Player draft auction opens %s (UK).\nBidding closes at a secret random time — the countdown on the draft auction page never shows the exact moment in advance.\nCheck GPDB and Draft Auction.',
        v_start
      ),
      'draftauction.html',
      'draft_scheduled:player:' || p_new.draft_auction_start_time::text || ':' || v_dedupe_ts,
      NULL
    );
  END IF;

  IF v_manager_notify THEN
    v_start := to_char(
      p_new.manager_draft_auction_start_time AT TIME ZONE 'Europe/London',
      'Dy DD Mon YYYY HH24:MI'
    );
    PERFORM public.owner_inbox_notify_all_clubs(
      'draft_scheduled',
      'Manager draft auction scheduled',
      format(
        E'Manager draft auction opens %s (UK).\nBidding closes at a secret random time — the countdown on MGDB never shows the exact moment in advance.\nCheck MGDB and Manager Draft Auction.',
        v_start
      ),
      'manager_draftauction.html',
      'draft_scheduled:manager:' || p_new.manager_draft_auction_start_time::text || ':' || v_dedupe_ts,
      NULL
    );
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8) Discord notify — per-type starts (+ club schedule)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_club_auction_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND coalesce(NEW.club_auction_enabled, false)
     AND NOT coalesce(OLD.club_auction_enabled, false) THEN
    BEGIN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'draft',
        '🏟️ CLUB AUCTION',
        'Club auction has been enabled for new owners.',
        8070335,
        'club_auction_enabled:' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
        jsonb_build_object('kind', 'club_auction')
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'gpsl discord club auction notify failed: %', SQLERRM;
    END;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF coalesce(NEW.draft_auction_enabled, false)
       AND NEW.draft_auction_start_time IS NOT NULL
       AND (
         NEW.draft_auction_start_time IS DISTINCT FROM OLD.draft_auction_start_time
         OR NOT coalesce(OLD.draft_auction_enabled, false)
       ) THEN
      v_start := to_char(
        NEW.draft_auction_start_time AT TIME ZONE 'Europe/London',
        'Dy DD Mon YYYY HH24:MI'
      ) || ' (UK)';
      BEGIN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'draft',
          '🧾 PLAYER DRAFT AUCTION',
          format('Player draft auction is scheduled.%sStarts: %s', E'\n', v_start),
          8070335,
          'player_draft_sched:' || to_char(NEW.draft_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
          jsonb_build_object('kind', 'player_draft')
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'gpsl discord player draft notify failed: %', SQLERRM;
      END;
    END IF;

    IF coalesce(NEW.manager_draft_auction_enabled, false)
       AND NEW.manager_draft_auction_start_time IS NOT NULL
       AND (
         NEW.manager_draft_auction_start_time IS DISTINCT FROM OLD.manager_draft_auction_start_time
         OR NOT coalesce(OLD.manager_draft_auction_enabled, false)
       ) THEN
      v_start := to_char(
        NEW.manager_draft_auction_start_time AT TIME ZONE 'Europe/London',
        'Dy DD Mon YYYY HH24:MI'
      ) || ' (UK)';
      BEGIN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'draft',
          '👔 MANAGER DRAFT AUCTION',
          format('Manager draft auction is scheduled.%sStarts: %s', E'\n', v_start),
          8070335,
          'manager_draft_sched:' || to_char(NEW.manager_draft_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
          jsonb_build_object('kind', 'manager_draft')
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'gpsl discord manager draft notify failed: %', SQLERRM;
      END;
    END IF;

    IF coalesce(NEW.club_auction_enabled, false)
       AND NEW.club_auction_start_time IS NOT NULL
       AND (
         NEW.club_auction_start_time IS DISTINCT FROM OLD.club_auction_start_time
         OR NOT coalesce(OLD.club_auction_enabled, false)
       ) THEN
      v_start := to_char(
        NEW.club_auction_start_time AT TIME ZONE 'Europe/London',
        'Dy DD Mon YYYY HH24:MI'
      ) || ' (UK)';
      BEGIN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'draft',
          '🏟️ CLUB AUCTION SCHEDULED',
          format('Club auction is scheduled.%sStarts: %s', E'\n', v_start),
          8070335,
          'club_auction_sched:' || to_char(NEW.club_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
          jsonb_build_object('kind', 'club_auction')
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'gpsl discord club auction schedule notify failed: %', SQLERRM;
      END;
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION WHEN undefined_column THEN
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_settle_club_auctions_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_before int;
  v_after int;
  v_finish timestamptz;
  v_listing public."Club_Auction_Listings"%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT club_auction_random_finish_time INTO v_finish
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_before
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  FOR v_listing IN
    SELECT *
    FROM public."Club_Auction_Listings"
    WHERE status = 'Active'
    ORDER BY id
  LOOP
    PERFORM public.transferengine_accept_club_auction_sale(v_listing.id);
  END LOOP;

  SELECT count(*)::int INTO v_after
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'active_before', v_before,
    'active_after', v_after,
    'settled_count', v_before - v_after,
    'secret_finish_passed', v_finish IS NOT NULL AND now() >= v_finish,
    'still_active', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'listing_id', l.id,
        'club_short_name', l.club_short_name,
        'high_bid', l.current_highest_bid,
        'high_bidder', l.current_highest_bidder,
        'leader_tag', r.owner_tag
      ) ORDER BY l.prestige_rank NULLS LAST, l.club_short_name), '[]'::jsonb)
      FROM public."Club_Auction_Listings" l
      LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.current_highest_bidder
      WHERE l.status = 'Active'
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_settle_club_auctions_now() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  draft_auction_enabled AS player_on,
  manager_draft_auction_enabled AS manager_on,
  club_auction_enabled AS club_on,
  draft_auction_start_time AS player_start,
  manager_draft_auction_start_time AS manager_start,
  club_auction_start_time AS club_start
FROM public.global_settings
WHERE id = 1;
