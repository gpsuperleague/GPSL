-- =============================================================================
-- National team call-up size: max 28, claim eligible / pool bar 26
--
-- Room for tournament cards (reds / yellow accumulation) and injuries.
-- Claim / Apply selectable: ≥26 GPDB players and ≥2 GKs (not club-depth bands).
-- Call-up hard cap: 28. Min 26 is eligibility (UI); release still only enforces ≥2 GKs.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_nation_pool_json_is_selectable(p_pool jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_pool IS NOT NULL
    AND coalesce((p_pool->'all'->>'total')::integer, 0) >= 26
    AND coalesce((p_pool->'all'->>'gk')::integer, 0) >= 2;
$$;

CREATE OR REPLACE FUNCTION public.international_nation_pool_is_selectable(p_nation_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pool jsonb;
BEGIN
  SELECT cache.pool INTO v_pool
  FROM public.international_nation_player_pool_cache cache
  WHERE cache.nation_code = upper(btrim(p_nation_code));

  RETURN public.international_nation_pool_json_is_selectable(v_pool);
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_call_up_player(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_cycle_id bigint;
  v_player_club text;
  v_squad_count integer;
  v_pid text := btrim(p_player_id);
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'You have not been assigned a national team';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
  ) THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF NOT public.international_player_matches_nation(v_pid, v_nation) THEN
    RAISE EXCEPTION 'Player nationality does not match your national team';
  END IF;

  SELECT c."ShortName"
  INTO v_player_club
  FROM public."Players" p
  JOIN public."Clubs" c
    ON c."ShortName" = nullif(btrim(p."Contracted_Team"), '')
  WHERE p."Konami_ID"::text = v_pid;

  v_squad_count := public.international_nation_active_squad_count(v_nation);

  IF NOT EXISTS (
    SELECT 1
    FROM public.international_squad_callups sc
    WHERE sc.nation_code = v_nation
      AND sc.player_id = v_pid
      AND sc.is_active = true
  ) AND v_squad_count >= 28 THEN
    RAISE EXCEPTION 'National squad is full (28 players)';
  END IF;

  SELECT id INTO v_cycle_id
  FROM public.international_wc_cycles
  ORDER BY cycle_no DESC
  LIMIT 1;

  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE player_id = v_pid
    AND nation_code <> v_nation
    AND is_active = true;

  IF FOUND THEN
    PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_squad_callups sc
    WHERE sc.nation_code = v_nation
      AND sc.player_id = v_pid
  ) THEN
    UPDATE public.international_squad_callups sc
    SET is_active = true,
        released_at = NULL,
        called_at = now(),
        club_short_name = v_player_club,
        prev_cycle_id = CASE
          WHEN sc.cycle_id IS DISTINCT FROM v_cycle_id AND sc.cycle_id IS NOT NULL
            THEN sc.cycle_id
          ELSE sc.prev_cycle_id
        END,
        prev_appearances_in_cycle = CASE
          WHEN sc.cycle_id IS DISTINCT FROM v_cycle_id AND sc.cycle_id IS NOT NULL
            THEN coalesce(sc.appearances_in_cycle, 0)
          ELSE sc.prev_appearances_in_cycle
        END,
        cycle_id = v_cycle_id,
        appearances_in_cycle = CASE
          WHEN sc.cycle_id IS DISTINCT FROM v_cycle_id THEN 0
          WHEN sc.is_active THEN coalesce(sc.appearances_in_cycle, 0)
          ELSE 0
        END
    WHERE sc.nation_code = v_nation
      AND sc.player_id = v_pid;
  ELSE
    INSERT INTO public.international_squad_callups (
      nation_code,
      player_id,
      club_short_name,
      cycle_id,
      is_active,
      appearances_in_cycle,
      prev_appearances_in_cycle
    )
    VALUES (
      v_nation,
      v_pid,
      v_player_club,
      v_cycle_id,
      true,
      0,
      0
    );
  END IF;

  PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_nation_pool_json_is_selectable(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_pool_is_selectable(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_call_up_player(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- After deploy: re-run Admin → International → Apply selectable so flags use ≥26.
-- Optional: SELECT public.international_nation_pool_is_selectable('AUT');
