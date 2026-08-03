-- =============================================================================
-- Manager FA board: keep 10 available through June / July / August / January
--
-- Bug: spawn ran once per month and never topped up after sales → board
-- often shows fewer than 10 by mid-January (and after summer signings).
--
-- Fix:
--   • Top up Active window_fa listings to 10 on every transferengine tick
--   • pick_ids respects p_limit (proportional bands)
--   • admin_manager_window_fa_restock() for manual fill / force fresh board
--
-- Safe re-run. After apply (January now):
--   SELECT public.admin_manager_window_fa_restock();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.manager_window_fa_pick_ids(
  p_season_id bigint,
  p_limit int DEFAULT 10
)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(0, least(coalesce(p_limit, 10), 20));
  v_ids bigint[] := ARRAY[]::bigint[];
  v_id bigint;
  v_band text;
  v_need int;
  v_bands text[] := ARRAY['low', 'mid', 'upper', 'elite'];
  -- Quotas for a full board of 10; scaled when topping up fewer
  v_quotas_full int[] := ARRAY[2, 3, 3, 2];
  v_quotas int[] := ARRAY[0, 0, 0, 0];
  v_i int;
  v_sum int := 0;
  v_have int;
BEGIN
  IF v_limit <= 0 THEN
    RETURN v_ids;
  END IF;

  -- Scale band quotas to v_limit (at least 0 each; remainder via refill)
  FOR v_i IN 1..4 LOOP
    v_quotas[v_i] := greatest(
      0,
      round((v_quotas_full[v_i]::numeric / 10.0) * v_limit)::int
    );
    v_sum := v_sum + v_quotas[v_i];
  END LOOP;
  -- Ensure we aim for v_limit via refill if rounding under-shoots
  IF v_sum > v_limit THEN
    v_quotas[2] := greatest(0, v_quotas[2] - (v_sum - v_limit));
  END IF;

  FOR v_i IN 1..4 LOOP
    v_band := v_bands[v_i];
    v_have := coalesce(array_length(v_ids, 1), 0);
    EXIT WHEN v_have >= v_limit;

    v_need := least(v_quotas[v_i], v_limit - v_have);
    IF v_need <= 0 THEN
      CONTINUE;
    END IF;

    FOR v_id IN
      SELECT m.id
      FROM public."Managers" m
      WHERE (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
        AND NOT EXISTS (
          SELECT 1 FROM public."Manager_Transfer_Listings" l
          WHERE l.manager_id = m.id AND l.status = 'Active'
        )
        AND NOT (m.id = ANY (v_ids))
        AND (
          (v_band = 'low' AND coalesce(m.rating, 0) <= 65)
          OR (v_band = 'mid' AND coalesce(m.rating, 0) BETWEEN 66 AND 72)
          OR (v_band = 'upper' AND coalesce(m.rating, 0) BETWEEN 73 AND 78)
          OR (v_band = 'elite' AND coalesce(m.rating, 0) >= 79)
        )
      ORDER BY random()
      LIMIT v_need
    LOOP
      v_ids := array_append(v_ids, v_id);
      EXIT WHEN coalesce(array_length(v_ids, 1), 0) >= v_limit;
    END LOOP;
  END LOOP;

  -- Fill remainder from any eligible FA
  WHILE coalesce(array_length(v_ids, 1), 0) < v_limit LOOP
    SELECT m.id INTO v_id
    FROM public."Managers" m
    WHERE (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
      AND NOT EXISTS (
        SELECT 1 FROM public."Manager_Transfer_Listings" l
        WHERE l.manager_id = m.id AND l.status = 'Active'
      )
      AND NOT (m.id = ANY (v_ids))
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_id IS NULL;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  RETURN v_ids;
END;
$function$;

-- Top up Active window_fa to target without closing existing listings
CREATE OR REPLACE FUNCTION public.manager_window_fa_ensure_board(
  p_season_id bigint DEFAULT NULL,
  p_month text DEFAULT NULL,
  p_target int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_month text := lower(btrim(coalesce(p_month, '')));
  v_target int := greatest(1, least(coalesce(p_target, 10), 20));
  v_active int := 0;
  v_need int;
  v_ids bigint[];
  v_id bigint;
  v_mv bigint;
  v_end timestamptz;
  v_lock timestamptz;
  v_created int := 0;
  v_fa_pool int := 0;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF v_month = '' THEN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  END IF;

  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_tw_month', 'month', v_month);
  END IF;

  SELECT count(*)::int INTO v_active
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND coalesce(l.metadata->>'gpsl_month', '') = v_month
    AND coalesce((l.metadata->>'season_id')::bigint, 0) = v_season_id;

  v_need := greatest(0, v_target - v_active);
  IF v_need = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'month', v_month,
      'active', v_active,
      'target', v_target,
      'created', 0,
      'topped_up', false
    );
  END IF;

  SELECT count(*)::int INTO v_fa_pool
  FROM public."Managers" m
  WHERE (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
    AND NOT EXISTS (
      SELECT 1 FROM public."Manager_Transfer_Listings" l
      WHERE l.manager_id = m.id AND l.status = 'Active'
    );

  v_lock := public.manager_gpsl_month_lock_at(v_season_id, v_month);
  v_end := least(coalesce(v_lock, now() + interval '7 days'), now() + interval '48 hours');

  v_ids := public.manager_window_fa_pick_ids(v_season_id, v_need);

  FOREACH v_id IN ARRAY coalesce(v_ids, ARRAY[]::bigint[]) LOOP
    SELECT coalesce(m.market_value, 0) INTO v_mv
    FROM public."Managers" m WHERE m.id = v_id;

    INSERT INTO public."Manager_Transfer_Listings" (
      manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
    )
    VALUES (
      v_id, NULL, 'window_fa', 'Active', v_end, v_mv,
      jsonb_build_object(
        'gpsl_month', v_month,
        'season_id', v_season_id,
        'window_fa', true,
        'top_up', true
      )
    );
    v_created := v_created + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'month', v_month,
    'active_before', v_active,
    'active_after', v_active + v_created,
    'target', v_target,
    'need', v_need,
    'created', v_created,
    'fa_pool_available', v_fa_pool,
    'topped_up', v_created > 0,
    'shortfall', greatest(0, v_need - v_created)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_window_fa_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_spawn jsonb;
  v_topup jsonb;
  v_process jsonb;
BEGIN
  -- First tick of the month: full fresh board of 10
  v_spawn := public.manager_window_fa_spawn(NULL, NULL, false);
  -- Every tick: top up to 10 if sales depleted the board
  v_topup := public.manager_window_fa_ensure_board(NULL, NULL, 10);
  v_process := public.manager_process_window_fa_listings();

  RETURN jsonb_build_object(
    'ok', true,
    'spawn', v_spawn,
    'ensure_board', v_topup,
    'process', v_process
  );
END;
$function$;

-- Admin: top up now, or force a brand-new board of 10
CREATE OR REPLACE FUNCTION public.admin_manager_window_fa_restock(
  p_force_fresh boolean DEFAULT false,
  p_target int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_spawn jsonb := NULL;
  v_topup jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(p_force_fresh, false) THEN
    v_spawn := public.manager_window_fa_spawn(NULL, NULL, true);
  END IF;

  v_topup := public.manager_window_fa_ensure_board(NULL, NULL, coalesce(p_target, 10));

  RETURN jsonb_build_object(
    'ok', true,
    'force_fresh', coalesce(p_force_fresh, false),
    'spawn', v_spawn,
    'ensure_board', v_topup
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_window_fa_pick_ids(bigint, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_ensure_board(bigint, text, int) TO service_role;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_month_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_manager_window_fa_restock(boolean, int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Manual restock after apply (SQL Editor as admin / postgres):
--   SELECT public.admin_manager_window_fa_restock(false);  -- top up to 10
--   SELECT public.admin_manager_window_fa_restock(true);   -- close + fresh 10
