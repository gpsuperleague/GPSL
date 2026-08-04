-- =============================================================================
-- Fix: manager_club_rehire_blocks FK on future season ids
--
-- Symptom (Process manager contracts):
--   insert or update on table "manager_club_rehire_blocks" violates foreign key
--   constraint "manager_club_rehire_blocks_blocked_from_season_id_fkey"
--
-- Cause: manager_rehire_block_record fell back to p_from_season_id + 1 / + N
-- when Season 3+ rows do not exist yet — those ids are not in competition_seasons.
--
-- Fix:
--   • Store evaluation season (real FK) + block_seasons count
--   • Resolve through-season when they exist; else through = from
--   • manager_club_rehire_blocked uses ordinal “next N seasons” (and blocks
--     the evaluation season itself for summer-break rehire)
-- Safe re-run. Then Process manager contracts again.
-- =============================================================================

ALTER TABLE public.manager_club_rehire_blocks
  ADD COLUMN IF NOT EXISTS block_seasons smallint NOT NULL DEFAULT 2;

ALTER TABLE public.manager_club_rehire_blocks
  DROP CONSTRAINT IF EXISTS manager_club_rehire_blocks_block_seasons_check;

ALTER TABLE public.manager_club_rehire_blocks
  ADD CONSTRAINT manager_club_rehire_blocks_block_seasons_check
  CHECK (block_seasons >= 1 AND block_seasons <= 10);

CREATE OR REPLACE FUNCTION public.manager_rehire_block_record(
  p_club_short text,
  p_manager_id bigint,
  p_from_season_id bigint,
  p_seasons int DEFAULT 2,
  p_reason text DEFAULT 'failed_targets'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_eval bigint := p_from_season_id;
  v_from bigint;
  v_through bigint;
  v_n int := greatest(coalesce(p_seasons, 2), 1);
BEGIN
  v_club := public.manager_club_short_canonical(p_club_short);
  IF v_club IS NULL OR p_manager_id IS NULL OR v_eval IS NULL THEN
    RETURN;
  END IF;

  -- Evaluation season must exist (FK)
  IF NOT EXISTS (
    SELECT 1 FROM public.competition_seasons s WHERE s.id = v_eval
  ) THEN
    RAISE EXCEPTION 'manager_rehire_block_record: unknown season_id %', v_eval;
  END IF;

  -- Prefer real following seasons when they already exist
  SELECT s.id INTO v_from
  FROM public.competition_seasons s
  WHERE s.id > v_eval
  ORDER BY s.id
  LIMIT 1;

  SELECT s.id INTO v_through
  FROM public.competition_seasons s
  WHERE s.id > v_eval
  ORDER BY s.id
  OFFSET (v_n - 1)
  LIMIT 1;

  -- No Season 3+ yet: anchor on evaluation season; ban logic uses block_seasons
  IF v_from IS NULL THEN
    v_from := v_eval;
  END IF;
  IF v_through IS NULL THEN
    v_through := v_eval;
  END IF;

  INSERT INTO public.manager_club_rehire_blocks (
    club_short_name, manager_id, reason,
    blocked_from_season_id, blocked_through_season_id, block_seasons
  )
  VALUES (
    v_club,
    p_manager_id,
    coalesce(p_reason, 'failed_targets'),
    v_from,
    v_through,
    v_n
  )
  ON CONFLICT (club_short_name, manager_id) DO UPDATE
    SET reason = excluded.reason,
        blocked_from_season_id = least(
          public.manager_club_rehire_blocks.blocked_from_season_id,
          excluded.blocked_from_season_id
        ),
        blocked_through_season_id = greatest(
          public.manager_club_rehire_blocks.blocked_through_season_id,
          excluded.blocked_through_season_id
        ),
        block_seasons = greatest(
          public.manager_club_rehire_blocks.block_seasons,
          excluded.block_seasons
        ),
        created_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_club_rehire_blocked(
  p_club_short text,
  p_manager_id bigint,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short, '')));
  v_season_id bigint := p_season_id;
  v_block record;
  v_anchor bigint;
  v_dist int;
BEGIN
  IF v_club = '' OR p_manager_id IS NULL THEN
    RETURN false;
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    b.blocked_from_season_id,
    b.blocked_through_season_id,
    coalesce(b.block_seasons, 2) AS block_seasons
  INTO v_block
  FROM public.manager_club_rehire_blocks b
  WHERE upper(b.club_short_name) = v_club
    AND b.manager_id = p_manager_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Classic absolute range (when through > from — future seasons existed at write)
  IF v_block.blocked_through_season_id > v_block.blocked_from_season_id
     AND v_season_id >= v_block.blocked_from_season_id
     AND v_season_id <= v_block.blocked_through_season_id THEN
    RETURN true;
  END IF;

  -- Deferred / same-season anchor: evaluation season (or first blocked = eval)
  -- Ban covers evaluation season (summer) + next block_seasons seasons.
  v_anchor := CASE
    WHEN v_block.blocked_through_season_id <= v_block.blocked_from_season_id
      THEN v_block.blocked_from_season_id
    ELSE NULL
  END;

  IF v_anchor IS NULL THEN
    RETURN false;
  END IF;

  IF v_season_id = v_anchor THEN
    RETURN true;
  END IF;

  IF v_season_id < v_anchor THEN
    RETURN false;
  END IF;

  SELECT count(*)::int
  INTO v_dist
  FROM public.competition_seasons s
  WHERE s.id > v_anchor
    AND s.id <= v_season_id;

  RETURN v_dist >= 1 AND v_dist <= v_block.block_seasons;
END;
$function$;

-- Soft-fail rehire block inside season-end so release still completes
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
  v_block_err text;
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
          PERFORM public.manager_rehire_block_record(
            v_fail_club, v_mgr.id, v_season.id, 2, 'failed_targets'
          );
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

  RETURN jsonb_build_object('ok', true, 'season_id', v_season.id, 'results', v_results);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_rehire_block_record(text, bigint, bigint, integer, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manager_club_rehire_blocked(text, bigint, bigint)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manager_process_season_end() TO authenticated;

NOTIFY pgrst, 'reload schema';
