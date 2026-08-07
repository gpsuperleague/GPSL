-- =============================================================================
-- Admin Testing: populate a club squad to 24 players at market value
-- UI: admin_test_populate_squad.html
--
-- Instant GPDB free-agent signings (not draft bids):
--   player_assign_to_club → Transfer_History (fee = MV) → post_transfer_ledger_for_history
-- Defaults: 2 GK · 8 DEF · 8 MID · 6 FWD; min HG 8; min U21 5; stars = division quota.
--
-- Performance: builds a one-shot free-agent pool (temp table), then picks from it.
-- =============================================================================

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

GRANT EXECUTE ON FUNCTION public.club_squad_position_counts(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_test_squad_snapshot(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_comp jsonb;
  v_pos jsonb;
  v_balance numeric := 0;
  v_star_min smallint;
  v_star_cap smallint;
  v_ooo text;
  v_stars int := 0;
  v_club_name text;
  v_nation text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_club');
  END IF;

  SELECT c."Club", c."Nation"
  INTO v_club_name, v_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  SELECT cf.balance INTO v_balance
  FROM public."Club_Finances" cf
  WHERE cf.club_name = v_club;

  SELECT public.check_club_squad_composition(v_club) INTO v_comp;
  SELECT public.club_squad_position_counts(v_club) INTO v_pos;

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
    AND coalesce(
      nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), ''),
      '0'
    )::integer >= v_star_min
    AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo);

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'club_name', v_club_name,
    'nation', v_nation,
    'balance', coalesce(v_balance, 0),
    'total', coalesce((v_comp->>'total')::int, 0),
    'home_grown', coalesce((v_comp->>'home_grown')::int, 0),
    'under_21', coalesce((v_comp->>'under_21')::int, 0),
    'goalkeepers', coalesce((v_comp->>'goalkeepers')::int, 0),
    'positions', v_pos,
    'stars', v_stars,
    'star_cap', v_star_cap,
    'star_min_rating', v_star_min,
    'one_of_our_own', v_ooo,
    'target_squad_size', 24,
    'min_home_grown', 8,
    'min_under_21', 5,
    'default_position_mins', jsonb_build_object(
      'gk', 2, 'def', 8, 'mid', 8, 'fwd', 6
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_test_squad_snapshot(text) TO authenticated;

DROP FUNCTION IF EXISTS public.admin_test_populate_squad(text, boolean, jsonb);
DROP FUNCTION IF EXISTS public.admin_test_populate_squad(text, boolean);

CREATE OR REPLACE FUNCTION public.admin_test_populate_squad(
  p_club_short_name text,
  p_dry_run boolean DEFAULT true,
  p_position_targets jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_club_nation text;
  v_club_nation_key text;
  v_target_size constant int := 24;
  v_min_hg constant int := 8;
  v_min_u21 constant int := 5;
  v_target_gk int := 2;
  v_target_def int := 8;
  v_target_mid int := 8;
  v_target_fwd int := 6;
  v_pos_sum int;
  v_balance numeric := 0;
  v_spent numeric := 0;
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
  v_squad_before int;
  v_need int;
  v_signed jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_placed int := 0;
  v_i int;
  v_player record;
  v_player_found boolean;
  v_mode text;
  v_pick_modes text[];
  v_need_pos text;
  v_pos_deficit int;
  v_def_gk int;
  v_def_def int;
  v_def_mid int;
  v_def_fwd int;
  v_compliance_met boolean;
  v_registration_met boolean;
  v_slots_left int;
  v_need_hg int;
  v_need_u21 int;
  v_need_star int;
  v_force_hg boolean;
  v_force_u21 boolean;
  v_force_star boolean;
  v_rating int;
  v_is_hg boolean;
  v_is_u21 boolean;
  v_pos_group text;
  v_amount numeric;
  v_history_id bigint;
  v_pool_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_club');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_finances_missing');
  END IF;

  IF p_position_targets IS NOT NULL AND jsonb_typeof(p_position_targets) = 'object' THEN
    v_target_gk := greatest(coalesce((p_position_targets->>'gk')::int, v_target_gk), 0);
    v_target_def := greatest(coalesce((p_position_targets->>'def')::int, v_target_def), 0);
    v_target_mid := greatest(coalesce((p_position_targets->>'mid')::int, v_target_mid), 0);
    v_target_fwd := greatest(coalesce((p_position_targets->>'fwd')::int, v_target_fwd), 0);
  END IF;

  v_pos_sum := v_target_gk + v_target_def + v_target_mid + v_target_fwd;
  IF v_pos_sum > v_target_size THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'position_mins_exceed_24',
      'position_sum', v_pos_sum,
      'target_squad_size', v_target_size
    );
  END IF;

  SELECT c."Nation" INTO v_club_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;
  v_club_nation_key := public.normalize_nation_key(v_club_nation);

  SELECT cf.balance INTO v_balance
  FROM public."Club_Finances" cf
  WHERE cf.club_name = v_club;
  v_balance := coalesce(v_balance, 0);

  SELECT public.check_club_squad_composition(v_club) INTO v_comp;
  v_squad := coalesce((v_comp->>'total')::int, 0);
  v_hg := coalesce((v_comp->>'home_grown')::int, 0);
  v_u21 := coalesce((v_comp->>'under_21')::int, 0);
  v_squad_before := v_squad;

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
    AND coalesce(
      nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), ''),
      '0'
    )::integer >= v_star_min
    AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo);

  IF v_squad > v_target_size THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'squad_over_24',
      'club', v_club,
      'squad_size', v_squad,
      'target_squad_size', v_target_size
    );
  END IF;

  v_need := v_target_size - v_squad;
  IF v_need <= 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'dry_run', p_dry_run,
      'club', v_club,
      'placed', 0,
      'reason', 'already_at_24',
      'squad_size_before', v_squad_before,
      'squad_size_after', v_squad,
      'total_spend', 0,
      'balance_before', v_balance,
      'balance_after', v_balance,
      'signed', '[]'::jsonb,
      'skipped', '[]'::jsonb,
      'registration_met', (
        v_hg >= v_min_hg
        AND v_u21 >= v_min_u21
        AND v_stars >= v_star_cap
        AND v_gk >= v_target_gk
        AND v_def >= v_target_def
        AND v_mid >= v_target_mid
        AND v_fwd >= v_target_fwd
      ),
      'position_targets', jsonb_build_object(
        'gk', v_target_gk, 'def', v_target_def, 'mid', v_target_mid, 'fwd', v_target_fwd
      ),
      'composition_before', jsonb_build_object(
        'total', v_squad_before,
        'home_grown', v_hg,
        'under_21', v_u21,
        'stars', v_stars,
        'positions', jsonb_build_object(
          'gk', v_gk, 'def', v_def, 'mid', v_mid, 'fwd', v_fwd
        )
      ),
      'projected_after', jsonb_build_object(
        'total', v_squad,
        'home_grown', v_hg,
        'under_21', v_u21,
        'stars', v_stars,
        'star_cap', v_star_cap,
        'star_min_rating', v_star_min,
        'min_hg', v_min_hg,
        'min_u21', v_min_u21,
        'positions', jsonb_build_object(
          'gk', v_gk, 'def', v_def, 'mid', v_mid, 'fwd', v_fwd
        ),
        'targets', jsonb_build_object(
          'gk', v_target_gk, 'def', v_target_def, 'mid', v_target_mid, 'fwd', v_target_fwd,
          'min_hg', v_min_hg, 'min_u21', v_min_u21, 'star_cap', v_star_cap,
          'star_min_rating', v_star_min
        )
      )
    );
  END IF;

  -- One scan of free agents → temp pool. Picks are O(1) filters from here.
  CREATE TEMP TABLE _admin_populate_pool (
    player_id text PRIMARY KEY,
    player_name text,
    player_position text,
    market_value numeric,
    rating int,
    age int,
    is_home_grown boolean,
    is_u21 boolean,
    is_star boolean,
    pos_group text,
    pick_rand double precision
  ) ON COMMIT DROP;

  INSERT INTO _admin_populate_pool (
    player_id, player_name, player_position, market_value,
    rating, age, is_home_grown, is_u21, is_star, pos_group, pick_rand
  )
  SELECT
    p."Konami_ID"::text,
    p."Name",
    p."Position",
    coalesce(p.market_value::numeric, 0),
    coalesce(
      nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), ''),
      '0'
    )::integer,
    nullif(btrim(p."Age"::text), '')::integer,
    (
      public.normalize_nation_key(p."Nation") = v_club_nation_key
      AND v_club_nation_key <> ''
    ),
    coalesce(nullif(btrim(p."Age"::text), '')::integer, 99) <= 21,
    coalesce(
      nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), ''),
      '0'
    )::integer >= v_star_min,
    public.international_player_pool_position_group(p."Position"),
    random()
  FROM public."Players" p
  WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
    AND coalesce(p.pesdb_unavailable, false) = false
    AND NOT public.player_signed_this_season(p."Season_Signed")
    AND (
      p.contract_seasons_remaining IS NULL
      OR p.contract_seasons_remaining > 1
    )
    AND coalesce(p.market_value::numeric, 0) > 0
    AND NOT EXISTS (
      SELECT 1
      FROM public."Player_Transfer_Listings" l
      WHERE l.player_id = p."Konami_ID"::text
        AND l.status = 'Active'
    );

  CREATE INDEX ON _admin_populate_pool (pos_group);
  CREATE INDEX ON _admin_populate_pool (is_home_grown) WHERE is_home_grown;
  CREATE INDEX ON _admin_populate_pool (is_u21) WHERE is_u21;
  CREATE INDEX ON _admin_populate_pool (is_star) WHERE is_star;

  SELECT count(*)::int INTO v_pool_count FROM _admin_populate_pool;

  IF v_pool_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_eligible_free_agents',
      'club', v_club
    );
  END IF;

  FOR v_i IN 1..v_need LOOP
    EXIT WHEN v_squad >= v_target_size;

    v_slots_left := v_target_size - v_squad;
    v_need_hg := greatest(v_min_hg - v_hg, 0);
    v_need_u21 := greatest(v_min_u21 - v_u21, 0);
    v_need_star := greatest(v_star_cap - v_stars, 0);

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

    v_force_star := v_need_star > 0 AND v_slots_left <= v_need_star;
    v_force_hg := v_need_hg > 0 AND v_slots_left <= v_need_hg;
    v_force_u21 := v_need_u21 > 0 AND v_slots_left <= v_need_u21;

    v_compliance_met := (
      v_need_hg = 0
      AND v_need_u21 = 0
      AND v_need_star = 0
      AND v_gk >= v_target_gk
      AND v_def >= v_target_def
      AND v_mid >= v_target_mid
      AND v_fwd >= v_target_fwd
    );

    IF v_force_star THEN
      v_pick_modes := ARRAY['star', 'hg', 'u21', 'pos', 'any'];
    ELSIF v_force_hg THEN
      v_pick_modes := ARRAY['hg', 'star', 'u21', 'pos', 'any'];
    ELSIF v_force_u21 THEN
      v_pick_modes := ARRAY['u21', 'hg', 'star', 'pos', 'any'];
    ELSIF v_compliance_met THEN
      v_pick_modes := ARRAY['any'];
    ELSE
      v_pick_modes := ARRAY['star', 'hg', 'u21', 'pos', 'any'];
    END IF;

    v_player_found := false;

    FOREACH v_mode IN ARRAY v_pick_modes LOOP
      IF v_mode = 'star' AND v_need_star <= 0 THEN CONTINUE; END IF;
      IF v_mode = 'hg' AND v_need_hg <= 0 THEN CONTINUE; END IF;
      IF v_mode = 'u21' AND v_need_u21 <= 0 THEN CONTINUE; END IF;
      IF v_mode = 'pos' AND (v_need_pos IS NULL OR v_pos_deficit <= 0) THEN CONTINUE; END IF;

      SELECT
        pool.player_id,
        pool.player_name,
        pool.player_position,
        pool.market_value,
        pool.rating,
        pool.age,
        pool.is_home_grown,
        pool.pos_group
      INTO v_player
      FROM _admin_populate_pool pool
      WHERE (NOT v_force_star OR pool.is_star)
        AND (NOT v_force_hg OR pool.is_home_grown)
        AND (NOT v_force_u21 OR pool.is_u21)
        AND (v_mode <> 'star' OR pool.is_star)
        AND (v_mode <> 'hg' OR pool.is_home_grown)
        AND (v_mode <> 'u21' OR pool.is_u21)
        AND (v_mode <> 'pos' OR pool.pos_group = v_need_pos)
        AND (NOT pool.is_star OR v_stars < v_star_cap)
      ORDER BY
        CASE WHEN v_need_star > 0 AND pool.is_star THEN 0 ELSE 1 END,
        CASE WHEN v_need_hg > 0 AND pool.is_home_grown THEN 0 ELSE 1 END,
        CASE WHEN v_need_u21 > 0 AND pool.is_u21 THEN 0 ELSE 1 END,
        CASE WHEN v_need_pos IS NOT NULL AND pool.pos_group = v_need_pos THEN 0 ELSE 1 END,
        pool.pick_rand
      LIMIT 1;

      IF FOUND THEN
        v_player_found := true;
        EXIT;
      END IF;
    END LOOP;

    IF NOT v_player_found THEN
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object(
          'reason', 'no_eligible_player',
          'attempt', v_i,
          'slots_left', v_target_size - v_squad,
          'pool_remaining', (SELECT count(*)::int FROM _admin_populate_pool)
        )
      );
      EXIT;
    END IF;

    v_rating := coalesce(v_player.rating, 0);
    v_is_hg := coalesce(v_player.is_home_grown, false);
    v_is_u21 := coalesce(v_player.age, 99) <= 21;
    v_pos_group := v_player.pos_group;
    v_amount := coalesce(v_player.market_value, 0);

    DELETE FROM _admin_populate_pool WHERE player_id = v_player.player_id;

    IF v_amount <= 0 THEN
      CONTINUE;
    END IF;

    IF NOT p_dry_run THEN
      BEGIN
        IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
          PERFORM public.assert_player_available_for_signing(v_player.player_id);
        END IF;

        PERFORM public.player_assign_to_club(
          v_player.player_id,
          v_club,
          NULL::numeric,
          false
        );

        INSERT INTO public."Transfer_History" (
          player_id,
          seller_club_id,
          buyer_club_id,
          fee,
          agent_fee,
          transfer_time,
          listing_id,
          transfer_sale_note
        )
        VALUES (
          v_player.player_id,
          NULL,
          v_club,
          v_amount,
          0,
          now(),
          NULL,
          'admin_test_populate_squad'
        )
        RETURNING id INTO v_history_id;

        IF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
          PERFORM public.post_transfer_ledger_for_history(v_history_id);
        ELSIF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
          PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_skipped := v_skipped || jsonb_build_array(
          jsonb_build_object(
            'reason', 'sign_blocked',
            'detail', SQLERRM,
            'player_id', v_player.player_id,
            'player_name', v_player.player_name
          )
        );
        CONTINUE;
      END;
    END IF;

    v_placed := v_placed + 1;
    v_spent := v_spent + v_amount;
    v_squad := v_squad + 1;
    IF v_is_hg THEN v_hg := v_hg + 1; END IF;
    IF v_is_u21 THEN v_u21 := v_u21 + 1; END IF;
    IF v_rating >= v_star_min THEN v_stars := v_stars + 1; END IF;
    IF v_pos_group = 'gk' THEN v_gk := v_gk + 1;
    ELSIF v_pos_group = 'def' THEN v_def := v_def + 1;
    ELSIF v_pos_group = 'mid' THEN v_mid := v_mid + 1;
    ELSIF v_pos_group = 'fwd' THEN v_fwd := v_fwd + 1;
    END IF;

    v_signed := v_signed || jsonb_build_array(
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
        'market_value', v_amount,
        'fee', v_amount
      )
    );
  END LOOP;

  DROP TABLE IF EXISTS _admin_populate_pool;

  v_registration_met := (
    v_hg >= v_min_hg
    AND v_u21 >= v_min_u21
    AND v_stars >= v_star_cap
    AND v_gk >= v_target_gk
    AND v_def >= v_target_def
    AND v_mid >= v_target_mid
    AND v_fwd >= v_target_fwd
    AND v_squad >= v_target_size
  );

  IF NOT v_registration_met THEN
    v_skipped := v_skipped || jsonb_build_array(
      jsonb_build_object(
        'reason', 'registration_shortfall',
        'home_grown', v_hg,
        'min_home_grown', v_min_hg,
        'under_21', v_u21,
        'min_under_21', v_min_u21,
        'stars', v_stars,
        'star_cap', v_star_cap,
        'positions', jsonb_build_object(
          'gk', v_gk, 'def', v_def, 'mid', v_mid, 'fwd', v_fwd
        ),
        'position_targets', jsonb_build_object(
          'gk', v_target_gk, 'def', v_target_def, 'mid', v_target_mid, 'fwd', v_target_fwd
        ),
        'squad_size', v_squad
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'club', v_club,
    'placed', v_placed,
    'planned', jsonb_array_length(v_signed),
    'slots_requested', v_need,
    'pool_size', v_pool_count,
    'squad_size_before', v_squad_before,
    'squad_size_after', v_squad,
    'target_squad_size', v_target_size,
    'registration_met', v_registration_met,
    'total_spend', v_spent,
    'balance_before', v_balance,
    'balance_after', CASE
      WHEN p_dry_run THEN v_balance - v_spent
      ELSE (
        SELECT coalesce(cf.balance, 0)
        FROM public."Club_Finances" cf
        WHERE cf.club_name = v_club
      )
    END,
    'signed', v_signed,
    'skipped', v_skipped,
    'position_targets', jsonb_build_object(
      'gk', v_target_gk, 'def', v_target_def, 'mid', v_target_mid, 'fwd', v_target_fwd
    ),
    'composition_before', jsonb_build_object(
      'total', v_squad_before
    ),
    'projected_after', jsonb_build_object(
      'total', v_squad,
      'home_grown', v_hg,
      'under_21', v_u21,
      'stars', v_stars,
      'star_cap', v_star_cap,
      'star_min_rating', v_star_min,
      'min_hg', v_min_hg,
      'min_u21', v_min_u21,
      'positions', jsonb_build_object(
        'gk', v_gk, 'def', v_def, 'mid', v_mid, 'fwd', v_fwd
      ),
      'targets', jsonb_build_object(
        'gk', v_target_gk, 'def', v_target_def, 'mid', v_target_mid, 'fwd', v_target_fwd,
        'min_hg', v_min_hg, 'min_u21', v_min_u21, 'star_cap', v_star_cap,
        'star_min_rating', v_star_min
      )
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_test_populate_squad(text, boolean, jsonb)
  TO authenticated;
