-- Evening transfer batch: process a club's outgoing sales before their incoming purchases,
-- defer squad-overflow enforcement until the full transferengine_run() tick completes.
-- Run after transferengine_draft.sql + transferengine_standard_bigint.sql (+ squad_overflow patches).

-- ---------------------------------------------------------------------------
-- player_assign_to_club — optional defer (transfer engine batch only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text,
  p_wage numeric DEFAULT NULL,
  p_defer_squad_overflow boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid      text := btrim(p_player_id);
  v_club     text := btrim(p_club_short_name);
  v_season   text;
  v_wage     numeric;
  v_overflow jsonb;
  v_defer    boolean;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  v_defer := p_defer_squad_overflow
    OR coalesce(
      nullif(current_setting('gpsl.defer_squad_overflow', true), ''),
      ''
    ) = 'on';

  PERFORM public.assert_player_available_for_signing(v_pid);

  v_season := public.current_gpsl_season_label();
  v_wage := coalesce(p_wage, public.calculate_player_wage_for_club(v_pid, v_club));

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season,
    contract_seasons_remaining = 3,
    contract_wage = round(coalesce(v_wage, 0), 0),
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = v_pid;

  IF v_defer THEN
    v_overflow := jsonb_build_object(
      'released', false,
      'deferred', true,
      'squad_total', public.club_squad_player_count(v_club)
    );
  ELSE
    v_overflow := public.enforce_squad_overflow_after_signing(v_club, v_pid);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'club_short_name', v_club,
    'contract_seasons_remaining', 3,
    'overflow_release', v_overflow
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- After a deferred batch: one overflow pass per over-limit club (net signings)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_finalize_deferred_squad_overflow()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club  text;
  v_total int;
  v_guard int;
BEGIN
  IF coalesce(
    nullif(current_setting('gpsl.defer_squad_overflow', true), ''),
    ''
  ) <> 'on' THEN
    RETURN;
  END IF;

  FOR v_club IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE public.club_squad_player_count(c."ShortName") > public.squad_max_size()
  LOOP
    v_guard := 0;
    LOOP
      v_guard := v_guard + 1;
      EXIT WHEN v_guard > 15;

      v_total := public.club_squad_player_count(v_club);
      EXIT WHEN v_total <= public.squad_max_size();

      PERFORM public.enforce_squad_overflow_after_signing(v_club, NULL);
    END LOOP;
  END LOOP;
END;
$function$;


-- ---------------------------------------------------------------------------
-- Standard listings — sync bids, outgoing-before-incoming order, multi-pass extensions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_process_standard_listings(
  p_now timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing record;
  v_pass    int := 0;
BEGIN
  LOOP
    v_pass := v_pass + 1;
    EXIT WHEN v_pass > 24;

    FOR v_listing IN
      SELECT l.id
      FROM public."Player_Transfer_Listings" l
      WHERE l.status = 'Active'
        AND l.listing_type IS DISTINCT FROM 'draft'
        AND p_now >= l.end_time
    LOOP
      PERFORM public.transferengine_sync_listing_high_bid(v_listing.id);
    END LOOP;

    FOR v_listing IN
      SELECT l.id
      FROM public."Player_Transfer_Listings" l
      WHERE l.status = 'Active'
        AND l.listing_type IS DISTINCT FROM 'draft'
        AND p_now >= l.end_time
      ORDER BY
        -- Clubs buying elsewhere tonight: settle their sales first
        CASE WHEN EXISTS (
          SELECT 1
          FROM public."Player_Transfer_Listings" l_out
          WHERE l_out.status = 'Active'
            AND l_out.listing_type IS DISTINCT FROM 'draft'
            AND p_now >= l_out.end_time
            AND l_out.seller_club_id = l.current_highest_bidder
        ) THEN 1 ELSE 0 END,
        -- Seller also buying tonight: outgoing before incoming
        CASE WHEN EXISTS (
          SELECT 1
          FROM public."Player_Transfer_Listings" l_in
          WHERE l_in.status = 'Active'
            AND l_in.listing_type IS DISTINCT FROM 'draft'
            AND p_now >= l_in.end_time
            AND l_in.current_highest_bidder = l.seller_club_id
        ) THEN 0 ELSE 1 END,
        l.id
    LOOP
      PERFORM public.transferengine_handle_expiry_or_extension(v_listing.id);
    END LOOP;

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public."Player_Transfer_Listings" l
      WHERE l.status = 'Active'
        AND l.listing_type IS DISTINCT FROM 'draft'
        AND p_now >= l.end_time
    );
  END LOOP;
END;
$function$;


-- ---------------------------------------------------------------------------
-- transferengine_run — defer overflow for the whole tick (market + draft)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_run()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM set_config('gpsl.defer_squad_overflow', 'on', true);

  PERFORM public.transferengine_process_standard_listings(now());
  PERFORM public.transferengine_settle_draft_auctions();

  PERFORM public.transferengine_finalize_deferred_squad_overflow();
  PERFORM set_config('gpsl.defer_squad_overflow', '', true);
END;
$function$;
