-- =============================================================================
-- Admin: seed GPDB draft bids toward squad compliance (testing / pre-season)
-- UI: admin_test_draft_seed.html
-- Run after: transferengine_draft.sql, squad_composition_rules.sql,
--            club_squad_designations.sql (star cap), global_settings_public.sql
-- =============================================================================
-- Places real draft auction opening/join bids (not instant signings). Auctions
-- settle via the normal transfer engine at random finish.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_draft_bid_window_bounds()
RETURNS TABLE (
  draft_start timestamptz,
  draft_cutoff timestamptz,
  draft_window_end timestamptz,
  draft_finish timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start timestamptz;
  v_finish timestamptz;
BEGIN
  SELECT gs.draft_auction_start_time, gs.draft_random_finish_time
  INTO v_start, v_finish
  FROM public.global_settings gs
  WHERE gs.id = 1;

  IF v_start IS NULL THEN
    RETURN;
  END IF;

  draft_start := v_start;
  draft_cutoff := v_start + interval '23 hours';
  draft_window_end := v_start + interval '23 hours 59 minutes 59 seconds';
  draft_finish := coalesce(v_finish, draft_window_end);
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_draft_auction_credits(
  p_club_short_name text,
  p_start timestamptz,
  p_cutoff timestamptz,
  p_window_end timestamptz
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH earned AS (
    SELECT count(*)::int * 2 AS n
    FROM public."Player_Transfer_Bids" b
    WHERE b.bidder_club_id = p_club_short_name
      AND b.is_first_draft_bid = true
      AND b.bid_time >= p_start
      AND b.bid_time < p_cutoff
  ),
  used AS (
    SELECT count(DISTINCT coalesce(b.player_id, b.direct_bid_id::text))::int AS n
    FROM public."Player_Transfer_Bids" b
    WHERE b.bidder_club_id = p_club_short_name
      AND b.is_draft_join = true
      AND b.draft_join_consumed = true
      AND b.bid_time >= p_start
      AND b.bid_time < p_window_end
  )
  SELECT coalesce((SELECT n FROM earned), 0) - coalesce((SELECT n FROM used), 0);
$$;

CREATE OR REPLACE FUNCTION public.club_squad_position_counts(p_club_short_name text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'gk',
    count(*) FILTER (
      WHERE public.international_player_pool_position_group(p."Position") = 'gk'
    ),
    'def',
    count(*) FILTER (
      WHERE public.international_player_pool_position_group(p."Position") = 'def'
    ),
    'mid',
    count(*) FILTER (
      WHERE public.international_player_pool_position_group(p."Position") = 'mid'
    ),
    'fwd',
    count(*) FILTER (
      WHERE public.international_player_pool_position_group(p."Position") = 'fwd'
    ),
    'other',
    count(*) FILTER (
      WHERE public.international_player_pool_position_group(p."Position") IS NULL
    )
  )
  FROM public."Players" p
  WHERE p."Contracted_Team" = btrim(p_club_short_name);
$$;

CREATE OR REPLACE FUNCTION public.admin_ensure_draft_listing_for_player(p_player_id text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_listing_id bigint;
  v_mv numeric;
  v_start timestamptz;
  v_end timestamptz;
  v_bounds record;
BEGIN
  SELECT l.id
  INTO v_listing_id
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id = v_pid
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  LIMIT 1;

  IF v_listing_id IS NOT NULL THEN
    RETURN v_listing_id;
  END IF;

  SELECT coalesce(p.market_value::numeric, 0)
  INTO v_mv
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  SELECT * INTO v_bounds FROM public.club_draft_bid_window_bounds() LIMIT 1;
  v_start := coalesce(v_bounds.draft_start, now());
  v_end := coalesce(
    v_bounds.draft_window_end,
    v_start + interval '23 hours 50 minutes'
  ) + (floor(random() * 600))::int * interval '1 second';

  INSERT INTO public."Player_Transfer_Listings" (
    player_id,
    seller_club_id,
    reserve_price,
    listing_type,
    market_value,
    status,
    start_time,
    end_time,
    initial_end_time,
    created_at
  )
  VALUES (
    v_pid,
    NULL,
    v_mv,
    'draft',
    v_mv,
    'Active',
    v_start,
    v_end,
    v_end,
    now()
  )
  RETURNING id INTO v_listing_id;

  RETURN v_listing_id;
END;
$function$;

-- Must drop before CREATE when renaming parameters (p_bid_amount → p_total_spend_budget).
DROP FUNCTION IF EXISTS public.admin_compliance_draft_seed_bids(text, integer, numeric, boolean, numeric);
DROP FUNCTION IF EXISTS public.admin_compliance_draft_seed_bids(text, int, numeric, boolean, numeric);
DROP FUNCTION IF EXISTS public.admin_compliance_draft_seed_bids(text, integer, numeric, boolean);
DROP FUNCTION IF EXISTS public.admin_compliance_draft_seed_bids(text, int, numeric, boolean);

CREATE OR REPLACE FUNCTION public.admin_compliance_draft_seed_bids(
  p_club_short_name text,
  p_max_bids int DEFAULT 27,
  p_budget_reserve numeric DEFAULT 5000000,
  p_dry_run boolean DEFAULT true,
  p_total_spend_budget numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_club_nation text;
  v_max_bids int := greatest(coalesce(p_max_bids, 1), 1);
  v_reserve numeric := greatest(coalesce(p_budget_reserve, 0), 0);
  v_spend_cap numeric;
  v_share numeric;
  v_slots_remaining int;
  v_min_bid numeric;
  v_mode text;
  v_modes text[] := ARRAY['star', 'hg', 'u21', 'pos', 'any'];
  v_player_found boolean;
  v_bounds record;
  v_enabled boolean;
  v_balance numeric;
  v_budget numeric;
  v_spent numeric := 0;
  v_credits int;
  v_comp jsonb;
  v_pos jsonb;
  v_star_min smallint;
  v_star_cap smallint;
  v_ooo text;
  v_squad int;
  v_hg int;
  v_u21 int;
  v_stars int;
  v_gk int;
  v_def int;
  v_mid int;
  v_fwd int;
  v_target_gk constant int := 2;
  v_target_def constant int := 8;
  v_target_mid constant int := 10;
  v_target_fwd constant int := 8;
  v_min_squad constant int := 24;
  v_max_squad constant int := 28;
  v_min_hg constant int := 8;
  v_min_u21 constant int := 5;
  v_exclude text[] := ARRAY[]::text[];
  v_bids jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_placed int := 0;
  v_i int;
  v_player record;
  v_listing_id bigint;
  v_window_bids int;
  v_high numeric;
  v_amount numeric;
  v_is_first boolean;
  v_is_join boolean;
  v_consume boolean;
  v_rating int;
  v_is_hg boolean;
  v_is_u21 boolean;
  v_pos_group text;
  v_need_pos text;
  v_pos_deficit int;
  v_def_gk int;
  v_def_def int;
  v_def_mid int;
  v_def_fwd int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_club');
  END IF;

  SELECT gs.draft_auction_enabled
  INTO v_enabled
  FROM public.global_settings gs
  WHERE gs.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'draft_not_enabled');
  END IF;

  SELECT * INTO v_bounds FROM public.club_draft_bid_window_bounds() LIMIT 1;
  IF v_bounds.draft_start IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'draft_not_scheduled');
  END IF;

  IF now() < v_bounds.draft_start THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'draft_not_started');
  END IF;

  IF now() >= v_bounds.draft_finish THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'draft_ended');
  END IF;

  SELECT c."Nation"
  INTO v_club_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  SELECT cf.balance
  INTO v_balance
  FROM public."Club_Finances" cf
  WHERE cf.club_name = v_club;

  v_balance := coalesce(v_balance, 0);
  v_spend_cap := coalesce(nullif(greatest(coalesce(p_total_spend_budget, 0), 0), 0), v_balance - v_reserve);
  v_budget := least(v_spend_cap, v_balance - v_reserve);
  IF v_budget < 0 THEN
    v_budget := v_spend_cap;
  END IF;

  v_credits := public.club_draft_auction_credits(
    v_club,
    v_bounds.draft_start,
    v_bounds.draft_cutoff,
    v_bounds.draft_window_end
  );

  SELECT public.check_club_squad_composition(v_club) INTO v_comp;
  v_squad := coalesce((v_comp->>'total')::int, 0);
  v_hg := coalesce((v_comp->>'home_grown')::int, 0);
  v_u21 := coalesce((v_comp->>'under_21')::int, 0);

  SELECT public.club_squad_position_counts(v_club) INTO v_pos;
  v_gk := coalesce((v_pos->>'gk')::int, 0);
  v_def := coalesce((v_pos->>'def')::int, 0);
  v_mid := coalesce((v_pos->>'mid')::int, 0);
  v_fwd := coalesce((v_pos->>'fwd')::int, 0);

  v_star_min := public.club_squad_star_min_rating();
  v_star_cap := public.club_squad_star_cap(v_club);

  SELECT d.player_id
  INTO v_ooo
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club
    AND d.designation = 'one_of_our_own'
  LIMIT 1;

  SELECT count(*)::int
  INTO v_stars
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND public.club_squad_player_rating(p."Konami_ID"::text) >= v_star_min
    AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo);

  v_max_bids := least(v_max_bids, greatest(v_max_squad - v_squad, 0));
  IF v_max_bids <= 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'squad_full',
      'club', v_club,
      'squad_size', v_squad
    );
  END IF;

  FOR v_i IN 1..v_max_bids LOOP
    EXIT WHEN v_squad >= v_max_squad;

    v_def_gk := greatest(v_target_gk - v_gk, 0);
    v_def_def := greatest(v_target_def - v_def, 0);
    v_def_mid := greatest(v_target_mid - v_mid, 0);
    v_def_fwd := greatest(v_target_fwd - v_fwd, 0);

    v_need_pos := NULL;
    v_pos_deficit := 0;
    IF v_def_gk > v_pos_deficit THEN
      v_need_pos := 'gk';
      v_pos_deficit := v_def_gk;
    END IF;
    IF v_def_def > v_pos_deficit THEN
      v_need_pos := 'def';
      v_pos_deficit := v_def_def;
    END IF;
    IF v_def_mid > v_pos_deficit THEN
      v_need_pos := 'mid';
      v_pos_deficit := v_def_mid;
    END IF;
    IF v_def_fwd > v_pos_deficit THEN
      v_need_pos := 'fwd';
      v_pos_deficit := v_def_fwd;
    END IF;

    v_slots_remaining := v_max_bids - v_i + 1;
    v_share := floor((v_spend_cap - v_spent) / greatest(v_slots_remaining, 1));
    v_player_found := false;

    FOREACH v_mode IN ARRAY v_modes LOOP
      IF v_mode = 'star' AND v_stars >= v_star_cap THEN
        CONTINUE;
      END IF;
      IF v_mode = 'hg' AND v_hg >= v_min_hg THEN
        CONTINUE;
      END IF;
      IF v_mode = 'u21' AND v_u21 >= v_min_u21 THEN
        CONTINUE;
      END IF;
      IF v_mode = 'pos' AND (v_need_pos IS NULL OR v_pos_deficit <= 0) THEN
        CONTINUE;
      END IF;

      SELECT
        p."Konami_ID"::text AS player_id,
        p."Name" AS player_name,
        p."Position" AS player_position,
        coalesce(p.market_value::numeric, 0) AS market_value,
        public.club_squad_player_rating(p."Konami_ID"::text) AS rating,
        public.club_squad_player_age(p."Konami_ID"::text) AS age,
        (
          public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_club_nation)
          AND public.normalize_nation_key(p."Nation") <> ''
        ) AS is_home_grown,
        public.international_player_pool_position_group(p."Position") AS pos_group
      INTO v_player
      FROM public."Players" p
      WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
        AND coalesce(p.pesdb_unavailable, false) = false
        AND NOT public.player_signed_this_season(p."Season_Signed")
        AND (
          p.contract_seasons_remaining IS NULL
          OR p.contract_seasons_remaining > 1
        )
        AND NOT (p."Konami_ID"::text = ANY (v_exclude))
        AND (
          public.club_squad_player_rating(p."Konami_ID"::text) < v_star_min
          OR v_stars < v_star_cap
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public."Player_Transfer_Bids" b
          WHERE b.bidder_club_id = v_club
            AND b.is_direct = true
            AND b.seller_club_id IS NULL
            AND coalesce(b.player_id, b.direct_bid_id::text) = p."Konami_ID"::text
            AND b.bid_time >= v_bounds.draft_start
            AND b.bid_time < v_bounds.draft_window_end
        )
        AND (
          v_mode <> 'star'
          OR public.club_squad_player_rating(p."Konami_ID"::text) >= v_star_min
        )
        AND (
          v_mode <> 'hg'
          OR (
            public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_club_nation)
            AND public.normalize_nation_key(p."Nation") <> ''
          )
        )
        AND (
          v_mode <> 'u21'
          OR public.club_squad_player_age(p."Konami_ID"::text) <= 21
        )
        AND (
          v_mode <> 'pos'
          OR public.international_player_pool_position_group(p."Position") = v_need_pos
        )
        AND (
          p_total_spend_budget IS NULL
          OR NOT EXISTS (
            SELECT 1
            FROM public."Player_Transfer_Bids" b
            WHERE b.is_direct = true
              AND b.seller_club_id IS NULL
              AND coalesce(b.player_id, b.direct_bid_id::text) = p."Konami_ID"::text
              AND b.bid_time >= v_bounds.draft_start
              AND b.bid_time < v_bounds.draft_window_end
          )
        )
        AND (
          p_total_spend_budget IS NULL
          OR coalesce(p.market_value::numeric, 0) <= greatest(v_share, v_spend_cap - v_spent)
        )
      ORDER BY
        CASE
          WHEN p_total_spend_budget IS NOT NULL THEN coalesce(p.market_value::numeric, 0)
        END ASC NULLS LAST,
        CASE
          WHEN v_mode = 'star'
            AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_club_nation)
          THEN 0
          ELSE 1
        END,
        CASE
          WHEN v_mode IN ('star', 'hg', 'u21')
            AND public.club_squad_player_age(p."Konami_ID"::text) <= 21
          THEN 0
          ELSE 1
        END,
        CASE
          WHEN v_need_pos IS NOT NULL
            AND public.international_player_pool_position_group(p."Position") = v_need_pos
          THEN 0
          ELSE 1
        END,
        random()
      LIMIT 1;

      IF FOUND THEN
        v_player_found := true;
        EXIT;
      END IF;
    END LOOP;

    IF NOT v_player_found THEN
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object('reason', 'no_eligible_player', 'attempt', v_i)
      );
      EXIT;
    END IF;

    v_rating := coalesce(v_player.rating, 0);
    v_is_hg := coalesce(v_player.is_home_grown, false);
    v_is_u21 := coalesce(v_player.age, 99) <= 21;
    v_pos_group := v_player.pos_group;

    SELECT count(*)::int
    INTO v_window_bids
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND b.seller_club_id IS NULL
      AND coalesce(b.player_id, b.direct_bid_id::text) = v_player.player_id
      AND b.bid_time >= v_bounds.draft_start
      AND b.bid_time < v_bounds.draft_window_end;

    v_is_first := v_window_bids = 0;
    v_is_join := NOT v_is_first;
    v_consume := false;
    v_high := 0;

    IF v_is_first THEN
      IF now() >= v_bounds.draft_cutoff THEN
        v_skipped := v_skipped || jsonb_build_array(
          jsonb_build_object(
            'reason', 'new_auction_locked_after_cutoff',
            'player_id', v_player.player_id,
            'player_name', v_player.player_name
          )
        );
        v_exclude := array_append(v_exclude, v_player.player_id);
        CONTINUE;
      END IF;
    ELSE
      SELECT coalesce(max(b.bid_amount), 0)
      INTO v_high
      FROM public."Player_Transfer_Bids" b
      WHERE b.is_direct = true
        AND b.seller_club_id IS NULL
        AND coalesce(b.player_id, b.direct_bid_id::text) = v_player.player_id
        AND b.bid_time >= v_bounds.draft_start
        AND b.bid_time < v_bounds.draft_window_end;

      IF EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Bids" b
        WHERE b.bidder_club_id = v_club
          AND b.is_draft_join = true
          AND coalesce(b.player_id, b.direct_bid_id::text) = v_player.player_id
          AND b.bid_time >= v_bounds.draft_start
          AND b.bid_time < v_bounds.draft_window_end
      ) THEN
        v_skipped := v_skipped || jsonb_build_array(
          jsonb_build_object(
            'reason', 'already_joined_auction',
            'player_id', v_player.player_id,
            'player_name', v_player.player_name
          )
        );
        v_exclude := array_append(v_exclude, v_player.player_id);
        CONTINUE;
      END IF;

      IF v_credits <= 0 THEN
        v_skipped := v_skipped || jsonb_build_array(
          jsonb_build_object(
            'reason', 'no_draft_join_credits',
            'player_id', v_player.player_id,
            'player_name', v_player.player_name
          )
        );
        EXIT;
      END IF;

      v_consume := NOT EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Bids" b
        WHERE b.bidder_club_id = v_club
          AND b.is_draft_join = true
          AND b.draft_join_consumed = true
          AND coalesce(b.player_id, b.direct_bid_id::text) = v_player.player_id
          AND b.bid_time >= v_bounds.draft_start
          AND b.bid_time < v_bounds.draft_window_end
      );
    END IF;

    IF v_is_first THEN
      v_min_bid := greatest(coalesce(v_player.market_value, 0), 500000);
    ELSE
      v_min_bid := v_high + 500000;
    END IF;

    IF p_total_spend_budget IS NOT NULL AND p_total_spend_budget > 0 THEN
      v_amount := greatest(v_min_bid, v_share);
      v_amount := least(v_amount, v_spend_cap - v_spent);
    ELSIF v_is_first THEN
      v_amount := greatest(coalesce(v_player.market_value, 0), 0);
    ELSE
      v_amount := v_high + 500000;
    END IF;

    IF v_amount <= 0 OR v_min_bid > v_spend_cap - v_spent THEN
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object(
          'reason', 'cannot_afford_player',
          'player_id', v_player.player_id,
          'player_name', v_player.player_name,
          'min_bid', v_min_bid,
          'remaining_budget', v_spend_cap - v_spent
        )
      );
      v_exclude := array_append(v_exclude, v_player.player_id);
      CONTINUE;
    END IF;

    IF v_amount < v_min_bid THEN
      v_amount := v_min_bid;
    END IF;

    IF v_spent + v_amount > v_spend_cap THEN
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object(
          'reason', 'budget_exhausted',
          'player_id', v_player.player_id,
          'player_name', v_player.player_name,
          'amount', v_amount,
          'remaining_budget', v_spend_cap - v_spent
        )
      );
      EXIT;
    END IF;

    IF v_spent + v_amount > v_budget THEN
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object(
          'reason', 'club_balance_exhausted',
          'player_id', v_player.player_id,
          'player_name', v_player.player_name,
          'amount', v_amount,
          'remaining_balance', v_budget - v_spent
        )
      );
      EXIT;
    END IF;

    IF NOT p_dry_run THEN
      BEGIN
        v_listing_id := public.admin_ensure_draft_listing_for_player(v_player.player_id);

        INSERT INTO public."Player_Transfer_Bids" (
          listing_id,
          player_id,
          direct_bid_id,
          bidder_club_id,
          seller_club_id,
          bid_amount,
          is_direct,
          is_first_draft_bid,
          is_draft_join,
          draft_join_consumed,
          bid_time
        )
        VALUES (
          v_listing_id,
          v_player.player_id,
          NULL,
          v_club,
          NULL,
          v_amount,
          true,
          v_is_first,
          v_is_join,
          v_consume,
          now()
        );

        UPDATE public."Player_Transfer_Listings" l
        SET current_highest_bid = v_amount,
            current_highest_bidder = v_club
        WHERE l.id = v_listing_id
          AND coalesce(l.current_highest_bid, 0) < v_amount;

        IF v_is_first THEN
          v_credits := v_credits + 2;
        ELSIF v_consume THEN
          v_credits := v_credits - 1;
        END IF;

        v_placed := v_placed + 1;
      EXCEPTION WHEN OTHERS THEN
        v_skipped := v_skipped || jsonb_build_array(
          jsonb_build_object(
            'reason', 'transfer_blocked',
            'detail', SQLERRM,
            'player_id', v_player.player_id,
            'player_name', v_player.player_name
          )
        );
        v_exclude := array_append(v_exclude, v_player.player_id);
        CONTINUE;
      END;
    END IF;

    v_spent := v_spent + v_amount;
    v_exclude := array_append(v_exclude, v_player.player_id);
    v_squad := v_squad + 1;
    IF v_is_hg THEN v_hg := v_hg + 1; END IF;
    IF v_is_u21 THEN v_u21 := v_u21 + 1; END IF;
    IF v_rating >= v_star_min THEN v_stars := v_stars + 1; END IF;
    IF v_pos_group = 'gk' THEN v_gk := v_gk + 1;
    ELSIF v_pos_group = 'def' THEN v_def := v_def + 1;
    ELSIF v_pos_group = 'mid' THEN v_mid := v_mid + 1;
    ELSIF v_pos_group = 'fwd' THEN v_fwd := v_fwd + 1;
    END IF;

    v_bids := v_bids || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_player.player_id,
        'player_name', v_player.player_name,
        'position', v_player.player_position,
        'pos_group', v_pos_group,
        'rating', v_rating,
        'age', v_player.age,
        'home_grown', v_is_hg,
        'under_21', v_is_u21,
        'is_star', v_rating >= v_star_min,
        'amount', v_amount,
        'bid_type', CASE WHEN v_is_first THEN 'open' ELSE 'join' END,
        'join_credit_consumed', v_consume
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'club', v_club,
    'placed', v_placed,
    'planned_bids', jsonb_array_length(v_bids),
    'total_spend', v_spent,
    'balance', v_balance,
    'budget_after_reserve', v_budget,
    'total_spend_budget', NULLIF(greatest(coalesce(p_total_spend_budget, 0), 0), 0),
    'spend_cap', v_spend_cap,
    'draft_credits_remaining', v_credits,
    'composition_before', v_comp,
    'position_before', v_pos,
    'projected_after', jsonb_build_object(
      'squad_size', v_squad,
      'home_grown', v_hg,
      'under_21', v_u21,
      'stars', v_stars,
      'positions', jsonb_build_object(
        'gk', v_gk,
        'def', v_def,
        'mid', v_mid,
        'fwd', v_fwd
      ),
      'targets', jsonb_build_object(
        'gk', v_target_gk,
        'def', v_target_def,
        'mid', v_target_mid,
        'fwd', v_target_fwd,
        'min_squad', v_min_squad,
        'max_squad', v_max_squad,
        'min_hg', v_min_hg,
        'min_u21', v_min_u21,
        'star_cap', v_star_cap,
        'star_min_rating', v_star_min
      )
    ),
    'bids', v_bids,
    'skipped', v_skipped
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_compliance_draft_seed_bids(text, integer, numeric, boolean, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
