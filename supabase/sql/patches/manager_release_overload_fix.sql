-- =============================================================================
-- Fix: manager_process_season_end → manager_release_from_club is not unique
--
-- Symptom:
--   Process manager contracts
--   ❌ function public.manager_release_from_club(bigint, text, numeric, unknown)
--      is not unique
--
-- Cause: both overloads exist in the DB:
--   (bigint, text, numeric, text)                 — original 4-arg
--   (bigint, text, numeric, text, text, jsonb)    — extended 6-arg
-- A 4-arg call matches both (defaults on the last two).
--
-- Fix: drop the 4-arg overload; keep the 6-arg (career-history) version;
-- cast season-end release args explicitly.
-- Safe re-run. Then re-run Process manager contracts.
-- =============================================================================

DROP FUNCTION IF EXISTS public.manager_release_from_club(bigint, text, numeric, text);

CREATE OR REPLACE FUNCTION public.manager_release_from_club(
  p_manager_id bigint,
  p_payout_club text DEFAULT NULL,
  p_payout_amount numeric DEFAULT NULL,
  p_ledger_type text DEFAULT 'transfer_sale',
  p_description text DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_club text;
  v_payout numeric;
  v_desc text;
  v_meta jsonb;
  v_end_kind text := 'release';
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  v_club := v_mgr.contracted_club;
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'Manager is a free agent';
  END IF;

  v_payout := coalesce(p_payout_amount, v_mgr.market_value::numeric);
  v_desc := coalesce(nullif(btrim(p_description), ''), format('Manager release — %s', v_mgr.name));
  v_meta := coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager');

  IF p_payout_club IS NOT NULL AND v_payout > 0 THEN
    PERFORM public.post_club_ledger(
      p_payout_club,
      p_ledger_type,
      abs(v_payout),
      v_desc,
      v_meta
    );
  END IF;

  IF coalesce((p_metadata->>'manager_sack')::boolean, false)
    OR coalesce(p_metadata->>'manager_sack', '') IN ('true', 't', '1')
    OR v_desc ILIKE 'Manager sack%' THEN
    v_end_kind := 'sack';
  ELSIF p_ledger_type = 'transfer_sale' THEN
    v_end_kind := 'transfer';
  END IF;

  IF to_regprocedure('public.manager_stint_close(bigint,text,numeric,text,timestamptz)') IS NOT NULL THEN
    PERFORM public.manager_stint_close(
      p_manager_id,
      v_club,
      CASE WHEN v_end_kind = 'sack' THEN v_payout ELSE NULL END,
      v_end_kind,
      now()
    );
  END IF;

  UPDATE public."Managers"
  SET contracted_club = NULL,
      contract_seasons_remaining = 0,
      weekly_wage = 0,
      updated_at = now()
  WHERE id = p_manager_id;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = v_club;

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Cancelled', updated_at = now()
  WHERE manager_id = p_manager_id AND status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'former_club', v_club,
    'payout', v_payout
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_release_from_club(bigint, text, numeric, text, text, jsonb)
  TO authenticated, service_role;

-- Pin season-end releases to the 6-arg signature (explicit casts)
CREATE OR REPLACE FUNCTION public.manager_process_season_end()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
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
  v_fail_club text;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
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
      -- Final season of the deal
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

        IF to_regprocedure('public.manager_rehire_block_record(text,bigint,bigint,integer,text)') IS NOT NULL THEN
          PERFORM public.manager_rehire_block_record(
            v_fail_club, v_mgr.id, v_season.id, 2, 'failed_targets'
          );
        END IF;

        v_row := jsonb_build_object(
          'manager_id', v_mgr.id,
          'club', v_fail_club,
          'action', 'released_failed_deal',
          'position', v_pos,
          'target_met', v_met,
          'hits', v_hits,
          'misses', v_misses,
          'payout', v_mgr.market_value
        );
      END IF;
    END IF;

    v_results := v_results || jsonb_build_array(v_row);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season.id, 'results', v_results);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_process_season_end() TO authenticated;

NOTIFY pgrst, 'reload schema';
