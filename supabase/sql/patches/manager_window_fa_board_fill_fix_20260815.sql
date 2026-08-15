-- =============================================================================
-- Manager FA board: diagnose + actually fill (preseason / past end_time / drafts)
--
-- Why the board can stay empty after the previous fix:
--   1) competition_active_gpsl_month() is NULL in preseason before June unlock
--      → restock returns not_tw_month and creates nothing
--   2) end_time = least(month_lock, now+48h) can be in the PAST if lock passed
--      → rows exist as Active but Manager Market hides them (end_time > now)
--   3) Free agents stuck on Active manager-draft listings are excluded from pick
--      and also hidden on the market (draft filtered out)
--
-- This patch:
--   • Resolves month: active TW month, else preseason → june
--   • Never creates past end_times; renews expired window_fa
--   • Closes leftover Active draft listings when draft auction is off
--   • pick_ids ignores draft-only blockers
--   • admin_manager_window_fa_diagnose() for SQL Editor
--   • Auto-runs force restock at end (when executed as postgres)
--
-- After apply, confirm with:
--   SELECT public.admin_manager_window_fa_diagnose();
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

CREATE OR REPLACE FUNCTION public.manager_window_fa_resolve_month(p_season_id bigint DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_status text;
  v_month text;
BEGIN
  IF v_season_id IS NULL THEN
    v_season_id := public.manager_window_fa_current_season_id();
  END IF;
  IF v_season_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT lower(coalesce(status, '')) INTO v_status
  FROM public.competition_seasons
  WHERE id = v_season_id;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  IF public.manager_is_transfer_window_month(v_month) THEN
    RETURN v_month;
  END IF;

  -- Preseason (or gap before June unlock): stock the June FA board
  IF v_status = 'preseason' THEN
    RETURN 'june';
  END IF;

  -- If a TW calendar row is currently open under any casing / naming
  SELECT lower(m.gpsl_month) INTO v_month
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season_id
    AND now() >= m.unlock_at
    AND now() < m.lock_at
    AND public.manager_is_transfer_window_month(m.gpsl_month)
  ORDER BY m.sort_order
  LIMIT 1;

  IF v_month IS NOT NULL AND v_month <> '' THEN
    RETURN v_month;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_window_fa_listing_end_at(
  p_season_id bigint,
  p_month text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_end timestamptz;
BEGIN
  -- Same as player transfer market / owner-listed managers:
  -- ≥24h from now, then next 19:00 Europe/London.
  -- (p_season_id / p_month kept for callers; month close uses close_batch.)
  v_end := public.compute_standard_listing_end_time(now());
  IF v_end IS NULL OR v_end <= now() THEN
    v_end := public.compute_standard_listing_end_time(now() + interval '1 second');
  END IF;
  RETURN v_end;
END;
$function$;

-- Close abandoned manager-draft auctions when draft is off (free agents for FA board)
CREATE OR REPLACE FUNCTION public.manager_window_fa_close_stale_drafts()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_draft_on boolean := false;
  v_n int := 0;
BEGIN
  SELECT coalesce(manager_draft_auction_enabled, false)
  INTO v_draft_on
  FROM public.global_settings
  WHERE id = 1;

  IF coalesce(v_draft_on, false) THEN
    RETURN 0;
  END IF;

  UPDATE public."Manager_Transfer_Listings" l
  SET status = 'Closed',
      updated_at = now(),
      metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
        'closed_for_fa_board', true,
        'closed_at', now()
      )
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active';

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

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
      WHERE coalesce(m.archived, false) = false
        AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
        AND NOT EXISTS (
          SELECT 1
          FROM public."Manager_Transfer_Listings" l
          WHERE l.manager_id = m.id
            AND l.status = 'Active'
            AND l.listing_type IN ('window_fa', 'standard', 'direct')
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
    WHERE coalesce(m.archived, false) = false
      AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
      AND NOT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Listings" l
        WHERE l.manager_id = m.id
          AND l.status = 'Active'
          AND l.listing_type IN ('window_fa', 'standard', 'direct')
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
  v_created int := 0;
  v_fa_pool int := 0;
  v_closed_drafts int := 0;
  v_renewed int := 0;
BEGIN
  IF v_season_id IS NULL THEN
    v_season_id := public.manager_window_fa_current_season_id();
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF v_month = '' THEN
    v_month := coalesce(public.manager_window_fa_resolve_month(v_season_id), '');
  END IF;

  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_tw_month',
      'month', nullif(v_month, ''),
      'hint', 'Need June/July/August/January (preseason maps to june)'
    );
  END IF;

  v_closed_drafts := public.manager_window_fa_close_stale_drafts();

  -- Revive Active window_fa rows with past end_times (UI filters these out)
  UPDATE public."Manager_Transfer_Listings" l
  SET end_time = public.manager_window_fa_listing_end_at(v_season_id, v_month),
      updated_at = now(),
      metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
        'gpsl_month', v_month,
        'season_id', v_season_id,
        'revived_end', true
      )
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND (l.end_time IS NULL OR l.end_time <= now());

  GET DIAGNOSTICS v_renewed = ROW_COUNT;

  SELECT count(*)::int INTO v_active
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND l.end_time > now();

  v_need := greatest(0, v_target - v_active);
  IF v_need = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'month', v_month,
      'active', v_active,
      'target', v_target,
      'created', 0,
      'renewed_end', v_renewed,
      'closed_stale_drafts', v_closed_drafts,
      'topped_up', false
    );
  END IF;

  SELECT count(*)::int INTO v_fa_pool
  FROM public."Managers" m
  WHERE coalesce(m.archived, false) = false
    AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
    AND NOT EXISTS (
      SELECT 1
      FROM public."Manager_Transfer_Listings" l
      WHERE l.manager_id = m.id
        AND l.status = 'Active'
        AND l.listing_type IN ('window_fa', 'standard', 'direct')
    );

  v_end := public.manager_window_fa_listing_end_at(v_season_id, v_month);
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
    'renewed_end', v_renewed,
    'closed_stale_drafts', v_closed_drafts,
    'end_time', v_end,
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
  v_created int := 0;
  v_closed int := 0;
  v_closed_drafts int := 0;
BEGIN
  IF v_season_id IS NULL THEN
    v_season_id := public.manager_window_fa_current_season_id();
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF v_month = '' THEN
    v_month := coalesce(public.manager_window_fa_resolve_month(v_season_id), '');
  END IF;

  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_tw_month', 'month', nullif(v_month, ''));
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

  v_closed_drafts := public.manager_window_fa_close_stale_drafts();
  v_closed := public.manager_window_fa_close_batch(v_season_id, NULL);

  v_end := public.manager_window_fa_listing_end_at(v_season_id, v_month);
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
        'closed_stale_drafts', v_closed_drafts,
        'created', v_created,
        'end_time', v_end,
        'manager_ids', to_jsonb(v_ids)
      ),
      ran_at = now()
  WHERE id = v_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'month', v_month,
    'closed_prior', v_closed,
    'closed_stale_drafts', v_closed_drafts,
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
  v_n int := 0;
BEGIN
  v_season_id := public.manager_window_fa_current_season_id();
  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'renewed', 0);
  END IF;

  v_month := coalesce(public.manager_window_fa_resolve_month(v_season_id), '');
  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    PERFORM public.manager_window_fa_close_batch(v_season_id, NULL);
    RETURN jsonb_build_object('ok', true, 'renewed', 0, 'closed_off_month', true);
  END IF;

  UPDATE public."Manager_Transfer_Listings" l
  SET end_time = public.manager_window_fa_listing_end_at(v_season_id, v_month),
      updated_at = now()
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND (l.end_time IS NULL OR l.end_time <= now())
    AND l.current_highest_bidder IS NULL;

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

CREATE OR REPLACE FUNCTION public.admin_manager_window_fa_diagnose()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_active_month text;
  v_resolved text;
  v_fa int := 0;
  v_fa_blocked_draft int := 0;
  v_window_active int := 0;
  v_window_active_live int := 0;
  v_window_expired int := 0;
  v_draft_active int := 0;
  v_draft_on boolean := false;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_season_id := public.manager_window_fa_current_season_id();
  IF v_season_id IS NOT NULL THEN
    SELECT lower(coalesce(status, '')) INTO v_status
    FROM public.competition_seasons WHERE id = v_season_id;
    v_active_month := public.competition_active_gpsl_month(v_season_id, now());
    v_resolved := public.manager_window_fa_resolve_month(v_season_id);
  END IF;

  SELECT coalesce(manager_draft_auction_enabled, false) INTO v_draft_on
  FROM public.global_settings WHERE id = 1;

  SELECT count(*)::int INTO v_fa
  FROM public."Managers" m
  WHERE coalesce(m.archived, false) = false
    AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '');

  SELECT count(*)::int INTO v_fa_blocked_draft
  FROM public."Managers" m
  WHERE coalesce(m.archived, false) = false
    AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
    AND EXISTS (
      SELECT 1 FROM public."Manager_Transfer_Listings" l
      WHERE l.manager_id = m.id AND l.status = 'Active' AND l.listing_type = 'draft'
    );

  SELECT count(*)::int INTO v_window_active
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'window_fa' AND status = 'Active';

  SELECT count(*)::int INTO v_window_active_live
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'window_fa' AND status = 'Active' AND end_time > now();

  SELECT count(*)::int INTO v_window_expired
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'window_fa' AND status = 'Active'
    AND (end_time IS NULL OR end_time <= now());

  SELECT count(*)::int INTO v_draft_active
  FROM public."Manager_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_status', v_status,
    'active_gpsl_month', v_active_month,
    'resolved_fa_month', v_resolved,
    'manager_draft_on', coalesce(v_draft_on, false),
    'free_agent_managers', v_fa,
    'free_agents_blocked_by_draft_listing', v_fa_blocked_draft,
    'window_fa_active_total', v_window_active,
    'window_fa_active_visible', v_window_active_live,
    'window_fa_active_expired_end', v_window_expired,
    'draft_listings_active', v_draft_active
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
  v_diag jsonb;
  v_spawn jsonb := NULL;
  v_topup jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_diag := public.admin_manager_window_fa_diagnose();

  IF coalesce(p_force_fresh, false) THEN
    v_spawn := public.manager_window_fa_spawn(NULL, NULL, true);
  END IF;

  v_topup := public.manager_window_fa_ensure_board(NULL, NULL, coalesce(p_target, 10));

  RETURN jsonb_build_object(
    'ok', true,
    'force_fresh', coalesce(p_force_fresh, false),
    'before', v_diag,
    'spawn', v_spawn,
    'ensure_board', v_topup,
    'after', public.admin_manager_window_fa_diagnose()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_window_fa_current_season_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_resolve_month(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_listing_end_at(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_close_stale_drafts() TO service_role;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_pick_ids(bigint, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_ensure_board(bigint, text, int) TO service_role;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_month_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_manager_window_fa_diagnose() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_manager_window_fa_restock(boolean, int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Fill the board now (SQL Editor as postgres / service role)
SELECT public.admin_manager_window_fa_restock(true, 10) AS manager_fa_restock_result;
