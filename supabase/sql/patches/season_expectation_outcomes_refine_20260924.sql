-- =============================================================================
-- Season expectation outcomes refine (2026-09-24)
-- =============================================================================
-- • Slight miss → lower-rated forced listing (big/medium)
-- • Low clubs → ≤72 rated transfer request on any miss
-- • Board fine: 25% of owner GPSL Building Society balance on club miss only
--   (manager personal-target misses do not trigger this fine)
-- • Manager deal end:
--     - 0 personal hits → leaves (refuse), MV credited to club, 2-season rehire block
--     - ≥1 personal hit BUT club missed both deal seasons → sack, MV credited
--     - else → renewal available
-- • Stadium expansion requires current fill ≥ 100%
--
-- Run once in Supabase SQL Editor.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Expectation band helpers (all tiers)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_expectation_band_for_season(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_metrics jsonb;
  v_band text;
BEGIN
  BEGIN
    v_metrics := public.competition_stadium_season_metrics(
      p_club_short_name, p_season_id, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN 'on_target';
  END;

  IF v_metrics IS NULL OR (v_metrics ? 'error') THEN
    RETURN 'on_target';
  END IF;

  v_band := coalesce(
    nullif(btrim(v_metrics ->> 'performance_band'), ''),
    'on_target'
  );
  RETURN v_band;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.club_expectation_missed_for_season(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_expectation_band_for_season(p_club_short_name, p_season_id)
    IS DISTINCT FROM 'on_target';
$$;

-- ---------------------------------------------------------------------------
-- Board fine: 25% of personal Building Society balance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.board_fine_owner_personal_pct(
  p_club_short_name text,
  p_pct numeric DEFAULT 25,
  p_reason text DEFAULT 'Board fine',
  p_season_id bigint DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_owner uuid;
  v_bal numeric(14, 2) := 0;
  v_fine numeric(14, 2) := 0;
  v_pct numeric := greatest(0, least(100, coalesce(p_pct, 25)));
BEGIN
  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = btrim(p_club_short_name);

  IF v_owner IS NULL THEN
    RETURN 0;
  END IF;

  IF to_regprocedure('public.owner_wallet_ensure(uuid)') IS NOT NULL THEN
    PERFORM public.owner_wallet_ensure(v_owner);
  END IF;

  SELECT coalesce(w.balance, 0) INTO v_bal
  FROM public.owner_wallets w
  WHERE w.owner_id = v_owner;

  v_bal := coalesce(v_bal, 0);
  v_fine := round(v_bal * (v_pct / 100.0), 2);
  IF v_fine <= 0 THEN
    RETURN 0;
  END IF;
  IF v_fine > v_bal THEN
    v_fine := v_bal;
  END IF;
  IF v_fine <= 0 THEN
    RETURN 0;
  END IF;

  PERFORM public._post_owner_ledger_internal(
    v_owner,
    'board_fine',
    -v_fine,
    coalesce(nullif(btrim(p_reason), ''), 'Board fine'),
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'club', btrim(p_club_short_name),
      'pct', v_pct,
      'balance_before', v_bal
    ),
    p_season_id,
    true
  );

  RETURN v_fine;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.club_expectation_band_for_season(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_expectation_missed_for_season(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.board_fine_owner_personal_pct(text, numeric, text, bigint, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Pick player by tier + band
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_underperformance_pick_player(
  p_club_short_name text,
  p_tier text,
  p_band text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_player_id text;
  v_band text := lower(coalesce(nullif(btrim(p_band), ''), 'bad'));
  v_slight boolean := (v_band = 'slight');
BEGIN
  IF p_tier = 'big' THEN
    IF v_slight THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM public."Players" p
      WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
        AND public.player_rating_numeric(p."Rating"::text) IS NOT NULL
        AND public.player_rating_numeric(p."Rating"::text) <= 76
        AND p."Konami_ID" NOT IN (
          SELECT x."Konami_ID" FROM (
            SELECT p2."Konami_ID"
            FROM public."Players" p2
            WHERE public.player_contracted_club_key(p2."Contracted_Team") = p_club_short_name
            ORDER BY public.player_rating_numeric(p2."Rating"::text) DESC NULLS LAST, p2."Konami_ID"
            LIMIT 4
          ) x
        )
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Listings" l
          WHERE l.player_id = p."Konami_ID"::text
            AND l.perpetual_renew = true
            AND l.status IN ('Active', 'Review', 'Seller Review')
        )
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_player_id IS NULL THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM (
        SELECT p2."Konami_ID", public.player_rating_numeric(p2."Rating"::text) AS rnk
        FROM public."Players" p2
        WHERE public.player_contracted_club_key(p2."Contracted_Team") = p_club_short_name
        ORDER BY rnk DESC NULLS LAST, p2."Konami_ID"
        LIMIT 4
      ) top4
      JOIN public."Players" p ON p."Konami_ID" = top4."Konami_ID"
      WHERE NOT EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" l
        WHERE l.player_id = p."Konami_ID"::text
          AND l.perpetual_renew = true
          AND l.status IN ('Active', 'Review', 'Seller Review')
      )
      ORDER BY random()
      LIMIT 1;
    END IF;

  ELSIF p_tier = 'medium' THEN
    IF v_slight THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM public."Players" p
      WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
        AND public.player_rating_numeric(p."Rating"::text) BETWEEN 68 AND 73
        AND public.player_age_numeric(p."Age"::text) > 21
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Listings" l
          WHERE l.player_id = p."Konami_ID"::text
            AND l.perpetual_renew = true
            AND l.status IN ('Active', 'Review', 'Seller Review')
        )
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_player_id IS NULL THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM public."Players" p
      WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
        AND public.player_rating_numeric(p."Rating"::text) BETWEEN 74 AND 78
        AND public.player_age_numeric(p."Age"::text) > 21
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Listings" l
          WHERE l.player_id = p."Konami_ID"::text
            AND l.perpetual_renew = true
            AND l.status IN ('Active', 'Review', 'Seller Review')
        )
      ORDER BY random()
      LIMIT 1;
    END IF;

  ELSIF p_tier = 'low' THEN
    SELECT p."Konami_ID"::text INTO v_player_id
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
      AND public.player_rating_numeric(p."Rating"::text) <= 72
      AND NOT EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" l
        WHERE l.player_id = p."Konami_ID"::text
          AND l.perpetual_renew = true
          AND l.status IN ('Active', 'Review', 'Seller Review')
      )
    ORDER BY random()
    LIMIT 1;
  END IF;

  RETURN v_player_id;
END;
$fn$;

-- 2-arg wrapper for older callers
CREATE OR REPLACE FUNCTION public.club_underperformance_pick_player(
  p_club_short_name text,
  p_tier text
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_underperformance_pick_player(p_club_short_name, p_tier, 'bad');
$$;

-- ---------------------------------------------------------------------------
-- Process club (includes low; band-aware; board fine)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_underperformance_process_club(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_tier text;
  v_metrics jsonb;
  v_band text;
  v_player_id text;
  v_listing_id bigint;
  v_fine numeric := 0;
BEGIN
  v_tier := public.competition_club_tier(p_club_short_name);
  v_band := public.club_expectation_band_for_season(p_club_short_name, p_season_id);

  IF v_band IS NOT DISTINCT FROM 'on_target' THEN
    RETURN jsonb_build_object(
      'club', p_club_short_name, 'tier', v_tier, 'skipped', 'on_target'
    );
  END IF;

  BEGIN
    v_fine := public.board_fine_owner_personal_pct(
      p_club_short_name,
      25,
      format('Board fine — club expectation %s', v_band),
      p_season_id,
      jsonb_build_object('performance_band', v_band, 'tier', v_tier)
    );
  EXCEPTION WHEN OTHERS THEN
    v_fine := 0;
  END;

  BEGIN
    v_metrics := public.competition_stadium_season_metrics(
      p_club_short_name, p_season_id, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_metrics := jsonb_build_object('performance_band', v_band);
  END;

  v_player_id := public.club_underperformance_pick_player(
    p_club_short_name, v_tier, v_band
  );

  IF v_player_id IS NULL THEN
    RETURN jsonb_build_object(
      'club', p_club_short_name,
      'tier', v_tier,
      'band', v_band,
      'board_fine', v_fine,
      'skipped', 'no_eligible_player'
    );
  END IF;

  v_listing_id := public.club_underperformance_create_listing(
    p_club_short_name,
    v_player_id,
    p_season_id,
    v_tier,
    coalesce(v_metrics, '{}'::jsonb) || jsonb_build_object('performance_band', v_band)
  );

  IF v_listing_id IS NULL THEN
    RETURN jsonb_build_object(
      'club', p_club_short_name,
      'tier', v_tier,
      'band', v_band,
      'board_fine', v_fine,
      'skipped', 'listing_exists'
    );
  END IF;

  BEGIN
    PERFORM public.owner_inbox_notify_underperformance_transfer(
      p_club_short_name,
      v_player_id,
      v_listing_id,
      v_tier,
      coalesce(v_metrics, '{}'::jsonb)
        || jsonb_build_object('season_id', p_season_id, 'performance_band', v_band)
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'club', p_club_short_name,
    'tier', v_tier,
    'band', v_band,
    'player_id', v_player_id,
    'listing_id', v_listing_id,
    'board_fine', v_fine,
    'performance_band', v_band
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.club_underperformance_missed_expectation(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_expectation_missed_for_season(p_club_short_name, p_season_id);
$$;

-- ---------------------------------------------------------------------------
-- Manager season end outcomes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manager_process_season_end()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_season public.competition_seasons;
  v_mgr public."Managers"%rowtype;
  v_division text;
  v_pos smallint;
  v_target public.manager_rating_targets;
  v_met boolean;
  v_deal bigint;
  v_hits int;
  v_misses int;
  v_club_misses int;
  v_deal_seasons int;
  v_fail_club text;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_block_err text;
  v_club_missed boolean;
BEGIN
  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season', 'results', '[]'::jsonb);
  END IF;

  FOR v_mgr IN
    SELECT * FROM public."Managers"
    WHERE contracted_club IS NOT NULL
      AND btrim(contracted_club) <> ''
      AND (
        contract_seasons_remaining > 0
        OR pending_owner_renewal IS TRUE
      )
  LOOP
    IF coalesce(v_mgr.pending_owner_renewal, false)
       AND coalesce(v_mgr.contract_seasons_remaining, 0) = 0 THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'awaiting_renewal'
      ));
      CONTINUE;
    END IF;

    SELECT cs.division, cs.season_position
    INTO v_division, v_pos
    FROM public.manager_club_season_position(v_season.id, v_mgr.contracted_club) cs;

    v_target := public.manager_target_for(
      v_mgr.rating, coalesce(v_division, 'championship_a')
    );
    v_met := public.manager_target_met(v_target, v_pos, v_division);
    v_deal := coalesce(v_mgr.deal_start_season_id, v_mgr.signed_season_id, v_season.id);
    v_club_missed := public.club_expectation_missed_for_season(
      v_mgr.contracted_club, v_season.id
    );

    INSERT INTO public.manager_deal_season_results (
      manager_id, club_short_name, deal_start_season_id, season_id,
      division, final_position, target_kind, target_value, target_label, target_met
    )
    VALUES (
      v_mgr.id, v_mgr.contracted_club, v_deal, v_season.id,
      v_division, v_pos,
      v_target.target_kind, v_target.target_value, v_target.label, v_met
    )
    ON CONFLICT (manager_id, club_short_name, deal_start_season_id, season_id)
    DO UPDATE SET
      division = excluded.division,
      final_position = excluded.final_position,
      target_kind = excluded.target_kind,
      target_value = excluded.target_value,
      target_label = excluded.target_label,
      target_met = excluded.target_met,
      recorded_at = now();

    -- Board fine is club-expectation only (applied in club_underperformance_process_club)

    IF coalesce(v_mgr.contract_seasons_remaining, 0) > 1 THEN
      UPDATE public."Managers"
      SET contract_seasons_remaining = contract_seasons_remaining - 1,
          deal_start_season_id = v_deal,
          pending_owner_renewal = false,
          updated_at = now()
      WHERE id = v_mgr.id;

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'season_tick',
        'position', v_pos,
        'target_met', v_met,
        'club_expectation_missed', v_club_missed,
        'seasons_remaining', v_mgr.contract_seasons_remaining - 1
      );
    ELSE
      SELECT
        count(*) FILTER (WHERE target_met IS TRUE)::int,
        count(*) FILTER (WHERE target_met IS FALSE)::int,
        count(*)::int
      INTO v_hits, v_misses, v_deal_seasons
      FROM public.manager_deal_season_results
      WHERE manager_id = v_mgr.id
        AND club_short_name = v_mgr.contracted_club
        AND deal_start_season_id = v_deal;

      SELECT count(*)::int INTO v_club_misses
      FROM public.manager_deal_season_results r
      WHERE r.manager_id = v_mgr.id
        AND r.club_short_name = v_mgr.contracted_club
        AND r.deal_start_season_id = v_deal
        AND public.club_expectation_missed_for_season(
          r.club_short_name, r.season_id
        );

      IF coalesce(v_hits, 0) = 0 THEN
        -- Failed personal targets every season → leave / refuse; MV to club
        v_fail_club := v_mgr.contracted_club;
        PERFORM public.manager_release_from_club(
          v_mgr.id,
          v_fail_club::text,
          v_mgr.market_value::numeric,
          'transfer_sale'::text,
          format(
            'Manager left — refused new deal after failing targets (%s)',
            coalesce(v_mgr.name, v_mgr.id::text)
          )::text,
          jsonb_build_object(
            'season_end', true,
            'failed_targets', true,
            'exit_kind', 'manager_refused',
            'hits', v_hits,
            'misses', v_misses
          )::jsonb
        );

        v_block_err := NULL;
        BEGIN
          PERFORM public.manager_rehire_block_record(
            v_fail_club, v_mgr.id, v_season.id, 2, 'failed_targets'
          );
        EXCEPTION WHEN OTHERS THEN
          v_block_err := SQLERRM;
        END;

        v_row := jsonb_build_object(
          'manager_id', v_mgr.id,
          'club', v_fail_club,
          'action', 'released_failed_deal',
          'exit_kind', 'manager_refused',
          'hits', v_hits,
          'misses', v_misses,
          'payout', v_mgr.market_value,
          'rehire_block_error', v_block_err
        );

      ELSIF v_deal_seasons >= 2 AND coalesce(v_club_misses, 0) >= 2 THEN
        -- Hit personal targets at least once, but club missed both seasons → sack
        v_fail_club := v_mgr.contracted_club;
        PERFORM public.manager_release_from_club(
          v_mgr.id,
          v_fail_club::text,
          v_mgr.market_value::numeric,
          'transfer_sale'::text,
          format(
            'Manager sacked — club missed season expectations (%s)',
            coalesce(v_mgr.name, v_mgr.id::text)
          )::text,
          jsonb_build_object(
            'season_end', true,
            'club_expectation_failed', true,
            'exit_kind', 'club_sack',
            'hits', v_hits,
            'misses', v_misses,
            'club_misses', v_club_misses
          )::jsonb
        );

        v_block_err := NULL;
        BEGIN
          PERFORM public.manager_rehire_block_record(
            v_fail_club, v_mgr.id, v_season.id, 2, 'club_expectation_failed'
          );
        EXCEPTION WHEN OTHERS THEN
          v_block_err := SQLERRM;
        END;

        v_row := jsonb_build_object(
          'manager_id', v_mgr.id,
          'club', v_fail_club,
          'action', 'sacked_club_expectation',
          'exit_kind', 'club_sack',
          'hits', v_hits,
          'misses', v_misses,
          'club_misses', v_club_misses,
          'payout', v_mgr.market_value,
          'rehire_block_error', v_block_err
        );

      ELSE
        UPDATE public."Managers"
        SET contract_seasons_remaining = 0,
            pending_owner_renewal = true,
            deal_start_season_id = v_deal,
            updated_at = now()
        WHERE id = v_mgr.id;

        v_row := jsonb_build_object(
          'manager_id', v_mgr.id,
          'club', v_mgr.contracted_club,
          'action', 'renewal_available',
          'position', v_pos,
          'target_met', v_met,
          'hits', v_hits,
          'misses', v_misses,
          'club_misses', v_club_misses
        );
      END IF;
    END IF;

    v_results := v_results || jsonb_build_array(v_row);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season.id, 'results', v_results);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.manager_process_season_end() TO authenticated;

-- ---------------------------------------------------------------------------
-- Stadium expansion: require fill ≥ 100%
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stadium_current_fill_pct(p_club_short_name text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT c.stadium_display_fill_pct
      FROM public."Clubs" c
      WHERE c."ShortName" = btrim(p_club_short_name)
    ),
    0
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION public.stadium_expansion_create_quote(p_seats integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_current int;
  v_base int;
  v_max int;
  v_headroom int;
  v_cps numeric;
  v_total numeric;
  v_quote_id bigint;
  v_max_build int;
  v_fill numeric;
BEGIN
  v_club := public.my_club_shortname();

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF coalesce(p_seats, 0) <= 0 THEN
    RAISE EXCEPTION 'Seats must be positive';
  END IF;

  IF to_regprocedure('public.stadium_expansion_sync_progress(text)') IS NOT NULL THEN
    PERFORM public.stadium_expansion_sync_progress(v_club);
  END IF;

  SELECT coalesce(c."Capacity", 0)::int,
         coalesce(c.base_capacity, c."Capacity", 0)::int
  INTO v_current, v_base
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  v_fill := public.stadium_current_fill_pct(v_club);
  IF coalesce(v_fill, 0) < 100 THEN
    RAISE EXCEPTION
      'Stadium expansion requires current fill of 100%% or higher (currently %s%%)',
      round(coalesce(v_fill, 0), 1);
  END IF;

  SELECT coalesce(gs.stadium_new_build_max_capacity, 55000)
  INTO v_max_build
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_max_build := coalesce(v_max_build, 55000);

  IF v_current > v_max_build THEN
    RAISE EXCEPTION
      'Stadium expansion is only available for clubs with capacity at or below % seats',
      v_max_build;
  END IF;

  v_max := public.stadium_max_capacity(v_base);
  v_headroom := public.stadium_expansion_headroom(v_club);

  IF v_headroom <= 0 THEN
    RAISE EXCEPTION 'Stadium is at maximum capacity — expansion not available';
  END IF;

  IF p_seats > v_headroom THEN
    RAISE EXCEPTION 'Cannot add % seats — only % headroom remaining', p_seats, v_headroom;
  END IF;

  v_cps := public.stadium_expansion_cost_per_seat(v_current);
  v_total := round(p_seats * v_cps, 2);

  INSERT INTO public.stadium_expansion_quotes (
    club_short_name, seats, capacity_at_quote, cost_per_seat, total_cost
  )
  VALUES (v_club, p_seats, v_current, v_cps, v_total)
  RETURNING id INTO v_quote_id;

  RETURN jsonb_build_object(
    'quote_id', v_quote_id,
    'seats', p_seats,
    'cost_per_seat', v_cps,
    'total_cost', v_total,
    'capacity_at_quote', v_current,
    'max_capacity', v_max,
    'headroom', v_headroom,
    'new_build_max_capacity', v_max_build,
    'fill_pct', round(v_fill, 2)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.stadium_current_fill_pct(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.stadium_expansion_create_quote(integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- Inbox + Discord: clearer "handed in a transfer request" wording
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_inbox_notify_underperformance_transfer(
  p_club_short_name text,
  p_player_id text,
  p_listing_id bigint,
  p_tier text,
  p_metrics jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_body text;
  v_exp text;
  v_act text;
  v_band text;
  v_tier_label text;
BEGIN
  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_exp := coalesce(p_metrics ->> 'expected_position', '?');
  v_act := coalesce(p_metrics ->> 'actual_position', '?');
  v_band := coalesce(p_metrics ->> 'performance_band', 'under');
  v_tier_label := CASE lower(coalesce(p_tier, ''))
    WHEN 'big' THEN 'big'
    WHEN 'medium' THEN 'medium'
    WHEN 'low' THEN 'low'
    ELSE coalesce(nullif(btrim(p_tier), ''), 'club')
  END;

  v_body := concat_ws(
    E'\n',
    format(
      '%s has handed in a transfer request after the club failed to meet expectations last season.',
      coalesce(v_player."Name", 'A player')
    ),
    format(
      'Your %s-club season expectation was missed (expected league position: %s · finished: %s · band: %s).',
      v_tier_label,
      v_exp,
      v_act,
      v_band
    ),
    format(
      'They are listed at market value (₿ %s) with automatic relisting until sold. You cannot remove this listing.',
      to_char(greatest(coalesce(v_player.market_value::numeric, 0), 0), 'FM999,999,999,999')
    ),
    'See Transfer Centre → Active listings and the Transfer Market.'
  );

  PERFORM public.owner_inbox_send(
    'underperformance_transfer',
    'Transfer request — failed season expectations',
    v_body,
    p_club_short_name,
    NULL,
    NULL, NULL, NULL,
    p_listing_id,
    'transfer_center.html',
    'underperformance:' || p_club_short_name || ':' || coalesce((p_metrics ->> 'season_id'), '0') || ':' || btrim(p_player_id),
    NULL,
    (p_metrics ->> 'season_id')::bigint
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_listing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_club text;
  v_club_full text;
  v_price text;
  v_headline text;
  v_body text;
  v_ask numeric;
  v_source text;
  v_tier text;
  v_age text;
  v_rating text;
BEGIN
  IF lower(coalesce(NEW.status::text, '')) IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;

  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft' THEN
    RETURN NEW;
  END IF;

  SELECT
    p."Name",
    nullif(btrim(p."Age"::text), ''),
    nullif(btrim(p."Rating"::text), '')
  INTO v_name, v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_club := coalesce(nullif(btrim(NEW.seller_club_id), ''), 'Unknown');

  BEGIN
    v_club_full := public.gpsl_discord_feed_club_name(v_club);
  EXCEPTION WHEN OTHERS THEN
    v_club_full := v_club;
  END;

  v_ask := coalesce(NEW.reserve_price, NEW.market_value, 0);

  BEGIN
    v_price := public.transfer_format_money(v_ask);
  EXCEPTION WHEN OTHERS THEN
    v_price := v_ask::text;
  END;

  v_source := lower(coalesce(NEW.special_rules ->> 'source', ''));
  v_tier := lower(coalesce(NEW.special_rules ->> 'tier', ''));

  IF v_source = 'underperformance' THEN
    v_headline := format('🚪 TRANSFER REQUEST — %s', v_name);
    v_body := format(
      E'%s has handed in a transfer request at %s after the club failed to meet expectations last season.\nListed at market value: %s\n%s · Age %s · Rating %s\nPerpetual listing until sold.',
      v_name,
      v_club_full,
      v_price,
      CASE v_tier
        WHEN 'big' THEN 'Big club underperformance'
        WHEN 'medium' THEN 'Medium club underperformance'
        WHEN 'low' THEN 'Low club underperformance'
        ELSE 'Club underperformance'
      END,
      coalesce(v_age, '?'),
      coalesce(v_rating, '?')
    );

    PERFORM public.gpsl_discord_feed_enqueue(
      'transfer_request',
      v_headline,
      v_body,
      15105570,
      'transfer_request:' || NEW.id::text,
      jsonb_build_object(
        'listing_id', NEW.id,
        'player_id', NEW.player_id,
        'club', v_club,
        'source', 'underperformance',
        'tier', v_tier,
        'channel', 'news'
      )
    );

    RETURN NEW;
  END IF;

  v_headline := format('📋 LISTED — %s', v_name);
  v_body := format('Club: %s\nAsking: %s', v_club_full, v_price);

  PERFORM public.gpsl_discord_feed_enqueue(
    'listing',
    v_headline,
    v_body,
    16763904,
    'listing:' || NEW.id::text,
    jsonb_build_object(
      'listing_id', NEW.id,
      'player_id', NEW.player_id,
      'channel', 'news'
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_listing ON public."Player_Transfer_Listings";
CREATE TRIGGER trg_gpsl_discord_feed_listing
  AFTER INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_listing();

NOTIFY pgrst, 'reload schema';
