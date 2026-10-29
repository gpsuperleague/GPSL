-- =============================================================================
-- Special auction prize option 4: Star swap (2026-10-29)
--
-- Existing options:
--   1) Sign player
--   2) Sign & release any squad player at MV (squad full only)
--   3) Take cash (MV)
--
-- New:
--   4) Star swap — release an existing STAR at MV, then sign the prize star.
--      One of Our Own (OooO) is NOT listed unless the incoming prize is
--      home-grown + star-rated for the club; in that case OooO transfers
--      onto the prize IMMEDIATELY after assign (before star-count chaos).
--
-- Idempotent / safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_prize_is_star(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min smallint := 79;
  v_rating int;
BEGIN
  IF nullif(btrim(coalesce(p_player_id, '')), '') IS NULL THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := public.club_squad_star_min_rating();
  END IF;
  IF to_regprocedure('public.club_squad_player_rating(text)') IS NOT NULL THEN
    v_rating := public.club_squad_player_rating(btrim(p_player_id));
  ELSE
    SELECT nullif(
      regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
      ''
    )::int
    INTO v_rating
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id);
  END IF;
  RETURN coalesce(v_rating, 0) >= v_min;
END;
$function$;

CREATE OR REPLACE FUNCTION public.special_auction_prize_eligible_oooo_preview(
  p_player_id text,
  p_club text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- Preview only (prize may still be FA). Full set uses club_squad_player_eligible_* after assign.
  SELECT coalesce(public.is_player_homegrown(btrim(p_player_id), btrim(p_club)), false)
    AND public.special_auction_prize_is_star(p_player_id);
$$;

-- ---------------------------------------------------------------------------
-- List star-swap candidates for the winner UI
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.special_auction_winner_star_swap_options(
  p_auction_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_prize text;
  v_min smallint := 79;
  v_cap int;
  v_count int;
  v_prize_star boolean := false;
  v_prize_oooo boolean := false;
  v_ooo text;
  v_cands jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Auction not found');
  END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Not a settled player prize');
  END IF;
  IF upper(btrim(coalesce(a.winning_club_id, ''))) IS DISTINCT FROM upper(btrim(coalesce(v_club, '')))
     AND NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Only the winning club can view this');
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Prize options are not open');
  END IF;

  v_prize := nullif(btrim(coalesce(a.prize_player_id, a.known_player_id, '')), '');
  IF v_prize IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No prize player');
  END IF;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := public.club_squad_star_min_rating();
  END IF;
  IF to_regprocedure('public.club_squad_star_cap(text)') IS NOT NULL THEN
    v_cap := public.club_squad_star_cap(a.winning_club_id)::int;
  ELSE
    v_cap := 3;
  END IF;
  IF to_regprocedure('public.club_star_count_for_cap(text)') IS NOT NULL THEN
    v_count := public.club_star_count_for_cap(a.winning_club_id);
  ELSE
    v_count := 0;
  END IF;

  v_prize_star := public.special_auction_prize_is_star(v_prize);
  v_prize_oooo := public.special_auction_prize_eligible_oooo_preview(v_prize, a.winning_club_id);

  IF to_regprocedure('public.club_ooo_player_id(text)') IS NOT NULL THEN
    v_ooo := public.club_ooo_player_id(a.winning_club_id);
  ELSE
    SELECT d.player_id INTO v_ooo
    FROM public.club_squad_player_designations d
    WHERE d.club_short_name = a.winning_club_id
      AND d.designation = 'one_of_our_own'
    LIMIT 1;
  END IF;

  IF v_prize_star THEN
    SELECT coalesce(jsonb_agg(x.obj ORDER BY x.rating DESC NULLS LAST, x.name), '[]'::jsonb)
    INTO v_cands
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'name', p."Name",
          'position', p."Position",
          'rating', CASE
            WHEN to_regprocedure('public.club_squad_player_rating(text)') IS NOT NULL
              THEN public.club_squad_player_rating(p."Konami_ID"::text)
            ELSE nullif(
              regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
              ''
            )::int
          END,
          'market_value', greatest(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0), 0),
          'is_oooo', (v_ooo IS NOT NULL AND p."Konami_ID"::text = v_ooo),
          'transfers_oooo', (
            v_ooo IS NOT NULL
            AND p."Konami_ID"::text = v_ooo
            AND v_prize_oooo
          )
        ) AS obj,
        CASE
          WHEN to_regprocedure('public.club_squad_player_rating(text)') IS NOT NULL
            THEN public.club_squad_player_rating(p."Konami_ID"::text)
          ELSE nullif(
            regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
            ''
          )::int
        END AS rating,
        p."Name" AS name
      FROM public."Players" p
      WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = upper(btrim(a.winning_club_id))
        AND p."Konami_ID"::text IS DISTINCT FROM v_prize
        AND coalesce(
          CASE
            WHEN to_regprocedure('public.club_squad_player_rating(text)') IS NOT NULL
              THEN public.club_squad_player_rating(p."Konami_ID"::text)
            ELSE nullif(
              regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
              ''
            )::int
          END,
          0
        ) >= v_min
        -- OooO excluded unless prize can inherit OooO
        AND (
          v_ooo IS NULL
          OR p."Konami_ID"::text <> v_ooo
          OR v_prize_oooo
        )
    ) x;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'prize_is_star', v_prize_star,
    'prize_eligible_oooo', v_prize_oooo,
    'star_min', v_min,
    'star_cap', v_cap,
    'star_count', v_count,
    'available', v_prize_star AND jsonb_array_length(v_cands) > 0,
    'candidates', v_cands
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_winner_star_swap_options(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Execute star swap (release star @ MV → sign prize; optional OooO transfer)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.special_auction_winner_star_swap(
  p_auction_id bigint,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_pid text := nullif(btrim(coalesce(p_player_id, '')), '');
  v_prize text;
  v_min smallint := 79;
  v_name text;
  v_team text;
  v_mv numeric;
  v_rating int;
  v_prize_rating int;
  v_ooo text;
  v_is_oooo boolean := false;
  v_transfer_oooo boolean := false;
  v_hist bigint;
  v_space jsonb;
  v_stars_before int;
  v_stars_after int;
BEGIN
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'Choose a star player to release';
  END IF;

  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF upper(btrim(coalesce(a.winning_club_id, ''))) IS DISTINCT FROM upper(btrim(coalesce(v_club, '')))
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can do this';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;

  v_prize := nullif(btrim(coalesce(a.prize_player_id, a.known_player_id, '')), '');
  IF v_prize IS NULL THEN RAISE EXCEPTION 'No prize player'; END IF;
  IF v_pid = v_prize THEN
    RAISE EXCEPTION 'That is the prize player — use Take cash (MV) instead';
  END IF;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := public.club_squad_star_min_rating();
  END IF;

  IF NOT public.special_auction_prize_is_star(v_prize) THEN
    RAISE EXCEPTION 'Star swap is only for star-rated prize players (rated % +)', v_min;
  END IF;

  -- Prize must still be unsigned
  v_space := public.special_auction_winner_prize_space(p_auction_id);
  IF coalesce((v_space->>'prize_signed')::boolean, false) THEN
    RAISE EXCEPTION 'Prize is already signed — use Keep, or take cash';
  END IF;

  IF to_regprocedure('public.club_ooo_player_id(text)') IS NOT NULL THEN
    v_ooo := public.club_ooo_player_id(a.winning_club_id);
  ELSE
    SELECT d.player_id INTO v_ooo
    FROM public.club_squad_player_designations d
    WHERE d.club_short_name = a.winning_club_id
      AND d.designation = 'one_of_our_own'
    LIMIT 1;
  END IF;
  v_is_oooo := (v_ooo IS NOT NULL AND v_ooo = v_pid);
  v_transfer_oooo := v_is_oooo
    AND public.special_auction_prize_eligible_oooo_preview(v_prize, a.winning_club_id);

  IF v_is_oooo AND NOT v_transfer_oooo THEN
    RAISE EXCEPTION
      'One of Our Own cannot be released in a star swap unless the prize can take OooO (home-grown star for your club)';
  END IF;

  SELECT p."Name", p."Contracted_Team",
         greatest(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0), 0),
         CASE
           WHEN to_regprocedure('public.club_squad_player_rating(text)') IS NOT NULL
             THEN public.club_squad_player_rating(p."Konami_ID"::text)
           ELSE nullif(
             regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
             ''
           )::int
         END
  INTO v_name, v_team, v_mv, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;
  IF upper(btrim(coalesce(v_team, ''))) IS DISTINCT FROM upper(btrim(a.winning_club_id)) THEN
    RAISE EXCEPTION 'That player is not at your club';
  END IF;
  IF coalesce(v_rating, 0) < v_min THEN
    RAISE EXCEPTION 'That player is not a star (need rating % +)', v_min;
  END IF;

  IF to_regprocedure('public.club_star_count_for_cap(text)') IS NOT NULL THEN
    v_stars_before := public.club_star_count_for_cap(a.winning_club_id);
  END IF;

  -- Close open listings on the outgoing star
  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id::text = v_pid
    AND upper(btrim(l.seller_club_id::text)) = upper(btrim(a.winning_club_id))
    AND l.status IN ('Active', 'Review', 'Seller Review');

  -- Release outgoing at MV (OooO designation purged by Contracted_Team trigger)
  IF to_regprocedure('public.player_release_from_club(text)') IS NOT NULL THEN
    PERFORM public.player_release_from_club(v_pid);
  ELSE
    UPDATE public."Players"
    SET "Contracted_Team" = NULL,
        "Season_Signed" = NULL,
        contract_seasons_remaining = NULL,
        contract_wage = NULL
    WHERE "Konami_ID"::text = v_pid;
  END IF;

  INSERT INTO public."Transfer_History" (
    player_id, seller_club_id, buyer_club_id, fee, agent_fee,
    transfer_time, listing_id, foreign_buyer_name, transfer_sale_note
  )
  VALUES (
    v_pid, a.winning_club_id, 'FOREIGN', v_mv, 0,
    now(), NULL,
    CASE WHEN v_transfer_oooo
      THEN 'Special auction star swap + OooO transfer (market value)'
      ELSE 'Special auction star swap (market value)'
    END,
    'special_auction_star_swap'
  )
  RETURNING id INTO v_hist;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint,boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_hist, true);
  ELSE
    UPDATE public."Club_Finances"
    SET balance = balance + v_mv
    WHERE club_name = a.winning_club_id;
  END IF;

  -- Sign prize (before any star recount / enforcement)
  PERFORM public.special_auction_assign_prize_player(
    a, a.winning_club_id, coalesce(a.winning_amount, a.winner_purchase_amount, 0)
  );

  -- Immediately move OooO onto the prize so star count never spikes
  IF v_transfer_oooo THEN
    IF NOT public.club_squad_player_eligible_one_of_our_own(v_prize, a.winning_club_id) THEN
      RAISE EXCEPTION
        'Prize signed but is not eligible for One of Our Own — star swap aborted after release. Contact admin.';
    END IF;

    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = a.winning_club_id
      AND designation = 'one_of_our_own'
      AND player_id IS DISTINCT FROM v_prize;

    INSERT INTO public.club_squad_player_designations (club_short_name, player_id, designation)
    VALUES (a.winning_club_id, v_prize, 'one_of_our_own')
    ON CONFLICT (club_short_name, player_id) DO UPDATE
      SET designation = 'one_of_our_own',
          assigned_at = now();
  END IF;

  IF to_regprocedure('public.club_star_count_for_cap(text)') IS NOT NULL THEN
    v_stars_after := public.club_star_count_for_cap(a.winning_club_id);
  END IF;

  UPDATE public.special_auctions
  SET winner_keep_prep_done = true,
      winner_keep_prep_player_id = v_pid,
      winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;

  v_space := public.special_auction_club_squad_space(a.winning_club_id);

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'star_swap',
    'player_id', v_pid,
    'player_name', v_name,
    'market_value', v_mv,
    'history_id', v_hist,
    'oooo_transferred', v_transfer_oooo,
    'prize_player_id', v_prize,
    'star_count_before', v_stars_before,
    'star_count_after', v_stars_after,
    'total', (v_space->>'total')::int,
    'max', (v_space->>'max')::int,
    'resolved', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_winner_star_swap(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
