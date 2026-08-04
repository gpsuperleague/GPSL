-- =============================================================================
-- Season contract tick audit + catch-up (players + managers)
--
-- Why this exists:
--   • Player tick was split out of Create Season (timeout). If the second step
--     failed / was skipped, contract_seasons_remaining never decreased.
--   • Manager tick is a separate Close-season button and uses is_current.
--     After Summer Break there is no current season → managers never process.
--
-- Run in Supabase SQL Editor:
--   1) This whole file
--   2) SELECT public.admin_season_contract_tick_status();
--   3) If players look unticked:
--        SELECT public.admin_catchup_player_contract_tick();
--      (refuses if a tick was already logged for the newest season)
--   4) If managers look unticked for Season 2:
--        SELECT public.admin_catchup_manager_season_end(NULL);
--      (uses latest complete season; refuses if deal results already exist)
--
-- Safe re-run of this file. Catch-up RPCs are guarded against double-apply.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_contract_tick_log (
  id bigserial PRIMARY KEY,
  for_season_id bigint REFERENCES public.competition_seasons (id) ON DELETE SET NULL,
  for_season_label text,
  ticked_at timestamptz NOT NULL DEFAULT now(),
  result jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS competition_contract_tick_log_season_idx
  ON public.competition_contract_tick_log (for_season_id);

ALTER TABLE public.competition_contract_tick_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_contract_tick_log_admin ON public.competition_contract_tick_log;
CREATE POLICY competition_contract_tick_log_admin ON public.competition_contract_tick_log
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.competition_contract_tick_log TO authenticated;

-- ---------------------------------------------------------------------------
-- Status / diagnosis
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_season_contract_tick_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_players jsonb;
  v_managers jsonb;
  v_final_year int;
  v_market int;
  v_last_complete record;
  v_current record;
  v_newest record;
  v_mgr_results int := 0;
  v_tick_logs jsonb;
  v_player_tick_logged boolean := false;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(
    jsonb_object_agg(remaining::text, cnt),
    '{}'::jsonb
  )
  INTO v_players
  FROM (
    SELECT
      coalesce(p.contract_seasons_remaining::text, 'null') AS remaining,
      count(*)::int AS cnt
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    GROUP BY p.contract_seasons_remaining
  ) x;

  SELECT coalesce(
    jsonb_object_agg(remaining::text, cnt),
    '{}'::jsonb
  )
  INTO v_managers
  FROM (
    SELECT
      coalesce(m.contract_seasons_remaining::text, 'null') AS remaining,
      count(*)::int AS cnt
    FROM public."Managers" m
    WHERE m.contracted_club IS NOT NULL
      AND btrim(m.contracted_club) <> ''
    GROUP BY m.contract_seasons_remaining
  ) x;

  SELECT count(*)::int INTO v_final_year
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  SELECT count(*)::int INTO v_market
  FROM public."Players" p
  WHERE public.player_expiry_auction_applies(p."Konami_ID"::text);

  SELECT s.id, s.label, s.status, s.is_current
  INTO v_last_complete
  FROM public.competition_seasons s
  WHERE s.status = 'complete'
  ORDER BY s.id DESC
  LIMIT 1;

  SELECT s.id, s.label, s.status, s.is_current
  INTO v_current
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  SELECT s.id, s.label, s.status, s.is_current
  INTO v_newest
  FROM public.competition_seasons s
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_last_complete.id IS NOT NULL THEN
    SELECT count(*)::int INTO v_mgr_results
    FROM public.manager_deal_season_results r
    WHERE r.season_id = v_last_complete.id;
  END IF;

  IF v_newest.id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.competition_contract_tick_log l
      WHERE l.for_season_id = v_newest.id
    ) INTO v_player_tick_logged;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.ticked_at DESC), '[]'::jsonb)
  INTO v_tick_logs
  FROM (
    SELECT id, for_season_id, for_season_label, ticked_at, result
    FROM public.competition_contract_tick_log
    ORDER BY ticked_at DESC
    LIMIT 5
  ) l;

  RETURN jsonb_build_object(
    'ok', true,
    'player_remaining_counts', v_players,
    'players_final_year', v_final_year,
    'players_on_expiring_market', v_market,
    'player_tick_logged_for_newest_season', v_player_tick_logged,
    'manager_remaining_counts', v_managers,
    'manager_deal_results_for_last_complete', v_mgr_results,
    'last_complete_season', CASE
      WHEN v_last_complete.id IS NULL THEN NULL
      ELSE jsonb_build_object(
        'id', v_last_complete.id,
        'label', v_last_complete.label,
        'status', v_last_complete.status
      )
    END,
    'current_season', CASE
      WHEN v_current.id IS NULL THEN NULL
      ELSE jsonb_build_object(
        'id', v_current.id,
        'label', v_current.label,
        'status', v_current.status
      )
    END,
    'newest_season', CASE
      WHEN v_newest.id IS NULL THEN NULL
      ELSE jsonb_build_object(
        'id', v_newest.id,
        'label', v_newest.label,
        'status', v_newest.status
      )
    END,
    'recent_player_tick_logs', v_tick_logs,
    'hints', jsonb_build_array(
      'If players_on_expiring_market = 0 and many players still show remaining=2 or 3 after creating Season 3, player tick was skipped — run admin_catchup_player_contract_tick().',
      'If manager_deal_results_for_last_complete = 0, Season 2 manager processing was skipped — run admin_catchup_manager_season_end(NULL) BEFORE trusting Season 3 manager state.',
      'Managers are NOT ticked by Create Season. Process manager contracts on Close season while that season is still current (or use the catch-up RPC).'
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_season_contract_tick_status() TO authenticated;

-- ---------------------------------------------------------------------------
-- Player catch-up (wraps contract_tick_season_rollover + log)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_catchup_player_contract_tick(
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_newest record;
  v_out jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id, s.label INTO v_newest
  FROM public.competition_seasons s
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_newest.id IS NULL THEN
    RAISE EXCEPTION 'No competition seasons found';
  END IF;

  IF NOT coalesce(p_force, false)
     AND EXISTS (
       SELECT 1 FROM public.competition_contract_tick_log l
       WHERE l.for_season_id = v_newest.id
     )
  THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'already_ticked',
      'for_season_id', v_newest.id,
      'for_season_label', v_newest.label,
      'hint', 'A player contract tick is already logged for this season. Pass p_force := true only if you are sure it never applied.'
    );
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  v_out := public.contract_tick_season_rollover();

  INSERT INTO public.competition_contract_tick_log (for_season_id, for_season_label, result)
  VALUES (v_newest.id, v_newest.label, coalesce(v_out, '{}'::jsonb));

  RETURN jsonb_build_object(
    'ok', true,
    'for_season_id', v_newest.id,
    'for_season_label', v_newest.label,
    'tick', v_out
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_catchup_player_contract_tick(boolean)
  TO authenticated;

-- Also log when the normal UI tick succeeds
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

  -- Prior final-year first (resolve/release), THEN decrement into new final-year
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
    'players_final_year', v_final
  );

  SELECT s.id, s.label INTO v_newest
  FROM public.competition_seasons s
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_newest.id IS NOT NULL
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

-- ---------------------------------------------------------------------------
-- Manager catch-up for a specific (usually complete) season
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_catchup_manager_season_end(
  p_season_id bigint DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_mgr public."Managers"%ROWTYPE;
  v_division text;
  v_pos smallint;
  v_target public.manager_rating_targets;
  v_met boolean;
  v_deal bigint;
  v_hits int;
  v_misses int;
  v_fail_club text;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_block_err text;
  v_existing int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NOT NULL THEN
    SELECT * INTO v_season FROM public.competition_seasons WHERE id = p_season_id;
  ELSE
    SELECT * INTO v_season
    FROM public.competition_seasons
    WHERE status = 'complete'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND OR v_season.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT count(*)::int INTO v_existing
  FROM public.manager_deal_season_results r
  WHERE r.season_id = v_season.id;

  IF v_existing > 0 AND NOT coalesce(p_force, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'already_processed',
      'season_id', v_season.id,
      'season_label', v_season.label,
      'existing_results', v_existing,
      'hint', 'Manager deal results already exist for this season. Pass p_force := true only if those rows are wrong and you accept re-processing risk.'
    );
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

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

    v_target := public.manager_target_for(v_mgr.rating, coalesce(v_division, 'championship_a'));
    v_met := public.manager_target_met(v_target, v_pos, v_division);
    v_deal := coalesce(v_mgr.deal_start_season_id, v_mgr.signed_season_id, v_season.id);

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
        'seasons_remaining', v_mgr.contract_seasons_remaining - 1
      );
    ELSE
      SELECT
        count(*) FILTER (WHERE target_met IS TRUE)::int,
        count(*) FILTER (WHERE target_met IS FALSE)::int
      INTO v_hits, v_misses
      FROM public.manager_deal_season_results
      WHERE manager_id = v_mgr.id
        AND club_short_name = v_mgr.contracted_club
        AND deal_start_season_id = v_deal;

      IF v_hits >= 1 THEN
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
          'misses', v_misses
        );
      ELSE
        v_fail_club := v_mgr.contracted_club;
        PERFORM public.manager_release_from_club(
          v_mgr.id,
          v_fail_club::text,
          v_mgr.market_value::numeric,
          'transfer_sale'::text,
          format('Manager released — failed targets (%s)', coalesce(v_mgr.name, v_mgr.id::text))::text,
          jsonb_build_object(
            'season_end', true,
            'failed_targets', true,
            'hits', v_hits,
            'misses', v_misses
          )::jsonb
        );

        v_block_err := NULL;
        BEGIN
          IF to_regprocedure('public.manager_rehire_block_record(text,bigint,bigint,integer,text)') IS NOT NULL THEN
            PERFORM public.manager_rehire_block_record(
              v_fail_club, v_mgr.id, v_season.id, 2, 'failed_targets'
            );
          END IF;
        EXCEPTION
          WHEN OTHERS THEN
            v_block_err := SQLERRM;
        END;

        v_row := jsonb_build_object(
          'manager_id', v_mgr.id,
          'club', v_fail_club,
          'action', 'released_failed_deal',
          'position', v_pos,
          'target_met', v_met,
          'hits', v_hits,
          'misses', v_misses,
          'payout', v_mgr.market_value,
          'rehire_block_error', v_block_err
        );
      END IF;
    END IF;

    v_results := v_results || jsonb_build_array(v_row);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season.id,
    'season_label', v_season.label,
    'catchup', true,
    'results', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_catchup_manager_season_end(bigint, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
