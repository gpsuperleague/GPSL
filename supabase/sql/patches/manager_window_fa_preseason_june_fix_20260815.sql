-- =============================================================================
-- Manager FA board: work in preseason June (and top up reliably)
--
-- Bug: manager_window_fa_spawn / ensure_board / renew required
--   competition_seasons.status = 'active'
-- During June the season is often still 'preseason', so the board never
-- spawns → Manager Market shows 0 free-agent managers.
--
-- Fix:
--   • Resolve current season for preseason OR active
--   • Keep month_tick = spawn + ensure_board(10) + process
--   • admin_manager_window_fa_restock still available
--
-- After apply (SQL Editor as admin / postgres):
--   SELECT public.admin_manager_window_fa_restock(true);  -- fresh 10
--   -- or false to top up without closing existing window_fa rows
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.manager_window_fa_current_season_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
    AND lower(coalesce(status, '')) IN ('preseason', 'active')
  ORDER BY id DESC
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.manager_window_fa_current_season_id() IS
  'Current season for Manager FA board — includes preseason (June) and active.';

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
  v_quotas_full int[] := ARRAY[2, 3, 3, 2];
  v_quotas int[] := ARRAY[0, 0, 0, 0];
  v_i int;
  v_sum int := 0;
  v_have int;
BEGIN
  IF v_limit <= 0 THEN
    RETURN v_ids;
  END IF;

  FOR v_i IN 1..4 LOOP
    v_quotas[v_i] := greatest(
      0,
      round((v_quotas_full[v_i]::numeric / 10.0) * v_limit)::int
    );
    v_sum := v_sum + v_quotas[v_i];
  END LOOP;
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
    v_season_id := public.manager_window_fa_current_season_id();
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

CREATE OR REPLACE FUNCTION public.manager_window_fa_spawn(
  p_season_id bigint DEFAULT NULL,
  p_month text DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_month text := lower(btrim(coalesce(p_month, '')));
  v_job text;
  v_job_id bigint;
  v_ids bigint[];
  v_id bigint;
  v_mv bigint;
  v_end timestamptz;
  v_lock timestamptz;
  v_created int := 0;
  v_closed int := 0;
BEGIN
  IF v_season_id IS NULL THEN
    v_season_id := public.manager_window_fa_current_season_id();
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

  v_job := format('manager_window_fa:%s', v_month);

  IF NOT p_force THEN
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (v_season_id, v_job, v_month, jsonb_build_object('status', 'running'))
    ON CONFLICT (season_id, job_key) DO NOTHING
    RETURNING id INTO v_job_id;

    IF v_job_id IS NULL THEN
      RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_spawned', 'month', v_month);
    END IF;
  ELSE
    DELETE FROM public.competition_season_calendar_jobs
    WHERE season_id = v_season_id AND job_key = v_job;
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (v_season_id, v_job, v_month, jsonb_build_object('status', 'running'))
    RETURNING id INTO v_job_id;
  END IF;

  v_closed := public.manager_window_fa_close_batch(v_season_id, NULL);

  v_lock := public.manager_gpsl_month_lock_at(v_season_id, v_month);
  v_end := coalesce(v_lock, now() + interval '7 days');
  v_end := least(v_end, now() + interval '48 hours');

  v_ids := public.manager_window_fa_pick_ids(v_season_id, 10);

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
        'batch_job', v_job
      )
    );
    v_created := v_created + 1;
  END LOOP;

  UPDATE public.competition_season_calendar_jobs
  SET result = jsonb_build_object(
        'ok', true,
        'month', v_month,
        'closed_prior', v_closed,
        'created', v_created,
        'manager_ids', to_jsonb(v_ids)
      ),
      ran_at = now()
  WHERE id = v_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'month', v_month,
    'closed_prior', v_closed,
    'created', v_created,
    'end_time', v_end
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_window_fa_renew_active()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_lock timestamptz;
  v_n int := 0;
BEGIN
  v_season_id := public.manager_window_fa_current_season_id();

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'renewed', 0);
  END IF;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    PERFORM public.manager_window_fa_close_batch(v_season_id, NULL);
    RETURN jsonb_build_object('ok', true, 'renewed', 0, 'closed_off_month', true);
  END IF;

  v_lock := public.manager_gpsl_month_lock_at(v_season_id, v_month);

  UPDATE public."Manager_Transfer_Listings" l
  SET end_time = least(coalesce(v_lock, now() + interval '48 hours'), now() + interval '48 hours'),
      updated_at = now()
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND l.end_time IS NOT NULL
    AND l.end_time <= now()
    AND l.current_highest_bidder IS NULL
    AND coalesce(l.metadata->>'gpsl_month', '') = v_month
    AND coalesce((l.metadata->>'season_id')::bigint, 0) = v_season_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'renewed', v_n, 'month', v_month);
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
  v_spawn := public.manager_window_fa_spawn(NULL, NULL, false);
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

GRANT EXECUTE ON FUNCTION public.manager_window_fa_current_season_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_pick_ids(bigint, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_ensure_board(bigint, text, int) TO service_role;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_month_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_manager_window_fa_restock(boolean, int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Immediate restock after apply:
--   SELECT public.admin_manager_window_fa_restock(true);
