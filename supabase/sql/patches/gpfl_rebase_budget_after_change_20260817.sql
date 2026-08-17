-- =============================================================================
-- GPFL: rebase entry banks after budget change (e.g. 400m → 500m)
--
-- remaining = season budget_snapshot − sum(active squad purchase prices)
-- Also syncs current season budget_snapshot from gpfl_settings.budget.
-- Safe re-run. Play-money only.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpfl_rebase_entry_budgets(p_gpfl_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_cfg public.gpfl_settings%rowtype;
  v_cap numeric;
  v_n int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season');
  END IF;

  -- Keep season cap in line with current settings
  UPDATE public.gpfl_seasons
  SET budget_snapshot = v_cfg.budget,
      settings_snapshot = to_jsonb(v_cfg)
  WHERE id = v_gs_id
    AND status IS DISTINCT FROM 'closed';

  SELECT budget_snapshot INTO v_cap
  FROM public.gpfl_seasons WHERE id = v_gs_id;

  UPDATE public.gpfl_entries e
  SET budget_remaining = greatest(
    0,
    coalesce(v_cap, 0) - coalesce((
      SELECT sum(sp.purchase_price)
      FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = e.id
        AND sp.slot_status = 'active'
    ), 0)
  )
  WHERE e.gpfl_season_id = v_gs_id
    AND e.status IN ('building', 'active');

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'budget_cap', v_cap,
    'entries_updated', v_n
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_rebase_entry_budgets(bigint) TO authenticated;

-- Run once now for the live season
SELECT public.gpfl_rebase_entry_budgets(NULL);

-- When admin saves settings, rebase if budget changed
CREATE OR REPLACE FUNCTION public.admin_gpfl_settings_set(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_div text[];
  v_ctypes text[];
  v_old_budget numeric;
  v_new_budget numeric;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  SELECT budget INTO v_old_budget FROM public.gpfl_settings WHERE id = 1;

  IF p_settings ? 'divisions' AND jsonb_typeof(p_settings->'divisions') = 'array' THEN
    SELECT array_agg(x) INTO v_div
    FROM jsonb_array_elements_text(p_settings->'divisions') t(x);
  END IF;
  IF p_settings ? 'competition_types' AND jsonb_typeof(p_settings->'competition_types') = 'array' THEN
    SELECT array_agg(x) INTO v_ctypes
    FROM jsonb_array_elements_text(p_settings->'competition_types') t(x);
  END IF;

  UPDATE public.gpfl_settings SET
    enabled = coalesce((p_settings->>'enabled')::boolean, enabled),
    opt_in_only = coalesce((p_settings->>'opt_in_only')::boolean, opt_in_only),
    budget = greatest(1000000, coalesce((p_settings->>'budget')::numeric, budget)),
    squad_size = greatest(11, least(20, coalesce((p_settings->>'squad_size')::int, squad_size))),
    starters = greatest(11, least(11, coalesce((p_settings->>'starters')::int, starters))),
    max_per_club = greatest(1, least(5, coalesce((p_settings->>'max_per_club')::int, max_per_club))),
    slot_gk = greatest(1, least(3, coalesce((p_settings->>'slot_gk')::int, slot_gk))),
    slot_def = greatest(3, least(6, coalesce((p_settings->>'slot_def')::int, slot_def))),
    slot_mid = greatest(3, least(6, coalesce((p_settings->>'slot_mid')::int, slot_mid))),
    slot_fwd = greatest(1, least(4, coalesce((p_settings->>'slot_fwd')::int, slot_fwd))),
    price_round_to = greatest(100000, coalesce((p_settings->>'price_round_to')::numeric, price_round_to)),
    price_floor = greatest(0, coalesce((p_settings->>'price_floor')::numeric, price_floor)),
    free_transfers_per_month = greatest(0, least(15, coalesce((p_settings->>'free_transfers_per_month')::int, free_transfers_per_month))),
    divisions = coalesce(v_div, divisions),
    competition_types = coalesce(v_ctypes, competition_types),
    require_stats_to_score = coalesce((p_settings->>'require_stats_to_score')::boolean, require_stats_to_score),
    pts_appear = coalesce((p_settings->>'pts_appear')::numeric, pts_appear),
    pts_goal_gk = coalesce((p_settings->>'pts_goal_gk')::numeric, pts_goal_gk),
    pts_goal_def = coalesce((p_settings->>'pts_goal_def')::numeric, pts_goal_def),
    pts_goal_mid = coalesce((p_settings->>'pts_goal_mid')::numeric, pts_goal_mid),
    pts_goal_fwd = coalesce((p_settings->>'pts_goal_fwd')::numeric, pts_goal_fwd),
    pts_assist = coalesce((p_settings->>'pts_assist')::numeric, pts_assist),
    pts_cs_gk = coalesce((p_settings->>'pts_cs_gk')::numeric, pts_cs_gk),
    pts_cs_def = coalesce((p_settings->>'pts_cs_def')::numeric, pts_cs_def),
    pts_cs_mid = coalesce((p_settings->>'pts_cs_mid')::numeric, pts_cs_mid),
    pts_cs_fwd = coalesce((p_settings->>'pts_cs_fwd')::numeric, pts_cs_fwd),
    pts_yellow = coalesce((p_settings->>'pts_yellow')::numeric, pts_yellow),
    pts_red = coalesce((p_settings->>'pts_red')::numeric, pts_red),
    pts_potm = coalesce((p_settings->>'pts_potm')::numeric, pts_potm),
    captain_multiplier = greatest(1, coalesce((p_settings->>'captain_multiplier')::numeric, captain_multiplier)),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = 1;

  UPDATE public.gpfl_settings
  SET squad_size = slot_gk + slot_def + slot_mid + slot_fwd
  WHERE id = 1;

  SELECT budget INTO v_new_budget FROM public.gpfl_settings WHERE id = 1;

  IF v_new_budget IS DISTINCT FROM v_old_budget THEN
    PERFORM public.gpfl_rebase_entry_budgets(NULL);
  END IF;

  RETURN public.gpfl_settings_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpfl_settings_set(jsonb) TO authenticated;
