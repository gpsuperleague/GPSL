-- =============================================================================
-- GPFL banks / lines XI + position groups (no formations)
--
-- Squad groups (sign / slots / auto-subs):
--   GK  → gk
--   CB, LB, RB (+ LWB/RWB) → def
--   DMF, CMF, AMF, LMF, RMF, LWF, RWF → mid
--   SS, CF → fwd
--
-- Scoring role (goals / clean sheets):
--   Same as above EXCEPT DMF scores as defender (CS/goal pts like DEF)
--
-- XI banks (not formations):
--   GK 1 · DEF 3–5 · MID 2–5 · FWD 1–3 · total 11
--   pitch_slot = gk_1 / def_1.. / mid_1.. / fwd_1..
--   formation_id stored as 'banks'
--
-- Safe re-run. After apply: owners re-Save XI (old formation slots ignored).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Position helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_normalize_card_pos(p_position text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE upper(btrim(coalesce(p_position, '')))
    WHEN 'LW' THEN 'LWF'
    WHEN 'RW' THEN 'RWF'
    WHEN 'LM' THEN 'LMF'
    WHEN 'RM' THEN 'RMF'
    WHEN 'WG' THEN 'LWF'
    WHEN 'CB1' THEN 'CB'
    WHEN 'CB2' THEN 'CB'
    WHEN 'CB3' THEN 'CB'
    ELSE upper(btrim(coalesce(p_position, '')))
  END;
$$;

-- Squad / pool / bank group (DMF is MID)
CREATE OR REPLACE FUNCTION public.gpfl_position_group(p_position text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE public.gpfl_normalize_card_pos(p_position)
    WHEN 'GK' THEN 'gk'
    WHEN 'CB' THEN 'def'
    WHEN 'LB' THEN 'def'
    WHEN 'RB' THEN 'def'
    WHEN 'LWB' THEN 'def'
    WHEN 'RWB' THEN 'def'
    WHEN 'DMF' THEN 'mid'
    WHEN 'CMF' THEN 'mid'
    WHEN 'AMF' THEN 'mid'
    WHEN 'LMF' THEN 'mid'
    WHEN 'RMF' THEN 'mid'
    WHEN 'LWF' THEN 'mid'
    WHEN 'RWF' THEN 'mid'
    WHEN 'SS' THEN 'fwd'
    WHEN 'CF' THEN 'fwd'
    ELSE 'mid'
  END;
$$;

-- Points role (DMF uses defender goal/CS tables)
CREATE OR REPLACE FUNCTION public.gpfl_scoring_position_group(p_position text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE public.gpfl_normalize_card_pos(p_position)
    WHEN 'GK' THEN 'gk'
    WHEN 'CB' THEN 'def'
    WHEN 'LB' THEN 'def'
    WHEN 'RB' THEN 'def'
    WHEN 'LWB' THEN 'def'
    WHEN 'RWB' THEN 'def'
    WHEN 'DMF' THEN 'def'  -- defensive scoring only
    WHEN 'CMF' THEN 'mid'
    WHEN 'AMF' THEN 'mid'
    WHEN 'LMF' THEN 'mid'
    WHEN 'RMF' THEN 'mid'
    WHEN 'LWF' THEN 'mid'
    WHEN 'RWF' THEN 'mid'
    WHEN 'SS' THEN 'fwd'
    WHEN 'CF' THEN 'fwd'
    ELSE 'mid'
  END;
$$;

COMMENT ON FUNCTION public.gpfl_position_group(text) IS
  'GPFL squad bank group. DMF/LWF/RWF are midfielders.';
COMMENT ON FUNCTION public.gpfl_scoring_position_group(text) IS
  'GPFL points role. DMF scores as defender; otherwise matches bank group.';

-- Bank fit: player may only occupy a slot on their own bank line
CREATE OR REPLACE FUNCTION public.gpfl_pos_fits_slot(p_player_pos text, p_slot_required text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.gpfl_position_group(p_player_pos)
       = public.gpfl_position_group(p_slot_required)
     OR (
       lower(btrim(coalesce(p_slot_required, ''))) IN ('gk', 'def', 'mid', 'fwd')
       AND public.gpfl_position_group(p_player_pos) = lower(btrim(p_slot_required))
     );
$$;

CREATE OR REPLACE FUNCTION public.gpfl_assert_xi_banks(
  p_gk int,
  p_def int,
  p_mid int,
  p_fwd int
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $function$
BEGIN
  IF coalesce(p_gk, 0) <> 1 THEN
    RAISE EXCEPTION 'XI needs exactly 1 goalkeeper (have %)', coalesce(p_gk, 0);
  END IF;
  IF coalesce(p_def, 0) < 3 OR coalesce(p_def, 0) > 5 THEN
    RAISE EXCEPTION 'XI needs 3–5 defenders (have %)', coalesce(p_def, 0);
  END IF;
  IF coalesce(p_mid, 0) < 2 OR coalesce(p_mid, 0) > 5 THEN
    RAISE EXCEPTION 'XI needs 2–5 midfielders (have %)', coalesce(p_mid, 0);
  END IF;
  IF coalesce(p_fwd, 0) < 1 OR coalesce(p_fwd, 0) > 3 THEN
    RAISE EXCEPTION 'XI needs 1–3 forwards (have %)', coalesce(p_fwd, 0);
  END IF;
  IF coalesce(p_gk, 0) + coalesce(p_def, 0) + coalesce(p_mid, 0) + coalesce(p_fwd, 0) <> 11 THEN
    RAISE EXCEPTION 'XI must total 11 players (have %)',
      coalesce(p_gk, 0) + coalesce(p_def, 0) + coalesce(p_mid, 0) + coalesce(p_fwd, 0);
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Scoring: use scoring role (DMF → def pts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_score_player_fixture(
  p_fixture_id bigint,
  p_player_id text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_f public.competition_fixtures%rowtype;
  v_m public.competition_match_player_stats%rowtype;
  v_pos_group text;
  v_pts numeric := 0;
  v_conceded int;
  v_breakdown jsonb := '{}'::jsonb;
  v_gs_id bigint;
  v_goal_pts numeric;
  v_cs_pts numeric;
  v_card_pos text;
BEGIN
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status <> 'played' THEN
    RETURN 0;
  END IF;
  IF NOT (v_f.competition_type = ANY (v_cfg.competition_types)) THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_m
  FROM public.competition_match_player_stats
  WHERE fixture_id = p_fixture_id AND player_id = p_player_id;

  IF NOT FOUND THEN
    IF v_cfg.require_stats_to_score THEN
      RETURN 0;
    END IF;
    RETURN 0;
  END IF;

  IF NOT coalesce(v_m.appeared, true) THEN
    RETURN 0;
  END IF;

  SELECT p."Position"::text INTO v_card_pos
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id
  LIMIT 1;

  v_pos_group := public.gpfl_scoring_position_group(v_card_pos);

  v_pts := v_pts + v_cfg.pts_appear;
  v_breakdown := v_breakdown || jsonb_build_object('appear', v_cfg.pts_appear);

  v_goal_pts := CASE v_pos_group
    WHEN 'gk' THEN v_cfg.pts_goal_gk
    WHEN 'def' THEN v_cfg.pts_goal_def
    WHEN 'mid' THEN v_cfg.pts_goal_mid
    ELSE v_cfg.pts_goal_fwd
  END;
  IF coalesce(v_m.goals, 0) > 0 THEN
    v_pts := v_pts + v_m.goals * v_goal_pts;
    v_breakdown := v_breakdown || jsonb_build_object('goals', v_m.goals * v_goal_pts);
  END IF;

  IF coalesce(v_m.assists, 0) > 0 THEN
    v_pts := v_pts + v_m.assists * v_cfg.pts_assist;
    v_breakdown := v_breakdown || jsonb_build_object('assists', v_m.assists * v_cfg.pts_assist);
  END IF;

  v_conceded := public.competition_player_conceded_in_fixture(p_fixture_id, v_m.club_short_name);
  IF v_conceded = 0 AND coalesce(v_m.started, false) THEN
    v_cs_pts := CASE v_pos_group
      WHEN 'gk' THEN v_cfg.pts_cs_gk
      WHEN 'def' THEN v_cfg.pts_cs_def
      WHEN 'mid' THEN v_cfg.pts_cs_mid
      ELSE v_cfg.pts_cs_fwd
    END;
    IF v_cs_pts <> 0 THEN
      v_pts := v_pts + v_cs_pts;
      v_breakdown := v_breakdown || jsonb_build_object('clean_sheet', v_cs_pts);
    END IF;
  END IF;

  IF coalesce(v_m.yellow_card, false) THEN
    v_pts := v_pts + v_cfg.pts_yellow;
    v_breakdown := v_breakdown || jsonb_build_object('yellow', v_cfg.pts_yellow);
  END IF;
  IF coalesce(v_m.red_card, false) THEN
    v_pts := v_pts + v_cfg.pts_red;
    v_breakdown := v_breakdown || jsonb_build_object('red', v_cfg.pts_red);
  END IF;
  IF coalesce(v_m.is_player_of_match, false) THEN
    v_pts := v_pts + v_cfg.pts_potm;
    v_breakdown := v_breakdown || jsonb_build_object('potm', v_cfg.pts_potm);
  END IF;

  SELECT id INTO v_gs_id
  FROM public.gpfl_seasons
  WHERE competition_season_id = v_f.season_id
  ORDER BY id DESC
  LIMIT 1;

  IF v_gs_id IS NOT NULL THEN
    INSERT INTO public.gpfl_player_fixture_points (
      gpfl_season_id, fixture_id, player_id, gpsl_month, points, breakdown
    ) VALUES (
      v_gs_id,
      p_fixture_id,
      p_player_id,
      v_f.gpsl_month,
      v_pts,
      v_breakdown || jsonb_build_object(
        'scoring_group', v_pos_group,
        'card_position', public.gpfl_normalize_card_pos(v_card_pos)
      )
    )
    ON CONFLICT (fixture_id, player_id) DO UPDATE
      SET points = EXCLUDED.points,
          breakdown = EXCLUDED.breakdown,
          gpsl_month = EXCLUDED.gpsl_month;
  END IF;

  RETURN v_pts;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Set XI by banks (replaces formation slot map)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.gpfl_set_xi(text, jsonb, text, text[]);
DROP FUNCTION IF EXISTS public.gpfl_set_xi(text, jsonb, text);
DROP FUNCTION IF EXISTS public.gpfl_set_xi(text[], text);

CREATE OR REPLACE FUNCTION public.gpfl_set_xi(
  p_lineup jsonb,
  p_captain_id text,
  p_bench_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_group text;
  v_pid text;
  v_player_pos text;
  v_player_group text;
  v_seen text[] := ARRAY[]::text[];
  v_cap_ok boolean := false;
  v_i int;
  v_order smallint := 1;
  v_n_gk int := 0;
  v_n_def int := 0;
  v_n_mid int := 0;
  v_n_fwd int := 0;
  v_arr text[];
  v_slot text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_gs_id := public.gpfl_current_season_id();
  IF v_gs_id IS NULL THEN RAISE EXCEPTION 'No GPFL season'; END IF;

  SELECT * INTO v_entry
  FROM public.gpfl_entries e
  WHERE e.gpfl_season_id = v_gs_id
    AND e.owner_id = v_uid
    AND e.status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  PERFORM public.gpfl_assert_editing_open(v_entry);

  IF p_lineup IS NULL OR jsonb_typeof(p_lineup) <> 'object' THEN
    RAISE EXCEPTION 'p_lineup must be a JSON object {gk,def,mid,fwd}';
  END IF;

  IF p_captain_id IS NULL OR btrim(p_captain_id) = '' THEN
    RAISE EXCEPTION 'Captain required';
  END IF;

  UPDATE public.gpfl_squad_players sp
  SET is_starter = false,
      is_captain = false,
      pitch_slot = NULL,
      bench_order = NULL
  WHERE sp.entry_id = v_entry.id;

  FOREACH v_group IN ARRAY ARRAY['gk', 'def', 'mid', 'fwd'] LOOP
    SELECT coalesce(array_agg(x ORDER BY ord), ARRAY[]::text[])
    INTO v_arr
    FROM (
      SELECT
        nullif(btrim(e.val), '') AS x,
        e.ord
      FROM jsonb_array_elements_text(coalesce(p_lineup -> v_group, '[]'::jsonb))
        WITH ORDINALITY AS e(val, ord)
    ) s
    WHERE s.x IS NOT NULL;

    v_i := 0;
    FOREACH v_pid IN ARRAY coalesce(v_arr, ARRAY[]::text[]) LOOP
      v_i := v_i + 1;
      IF v_pid = ANY (v_seen) THEN
        RAISE EXCEPTION 'Player % assigned twice', v_pid;
      END IF;
      v_seen := v_seen || v_pid;

      IF NOT EXISTS (
        SELECT 1 FROM public.gpfl_squad_players sp
        WHERE sp.entry_id = v_entry.id
          AND sp.player_id = v_pid
          AND sp.slot_status = 'active'
      ) THEN
        RAISE EXCEPTION 'Player % is not in your active squad', v_pid;
      END IF;

      SELECT coalesce(nullif(btrim(pp.position), ''), p."Position"::text)
      INTO v_player_pos
      FROM public."Players" p
      LEFT JOIN public.gpfl_player_prices pp
        ON pp.gpfl_season_id = v_gs_id AND pp.player_id = v_pid
      WHERE p."Konami_ID"::text = v_pid
      LIMIT 1;

      IF v_player_pos IS NULL THEN
        SELECT pp.position INTO v_player_pos
        FROM public.gpfl_player_prices pp
        WHERE pp.gpfl_season_id = v_gs_id AND pp.player_id = v_pid;
      END IF;

      v_player_group := public.gpfl_position_group(v_player_pos);
      IF v_player_group <> v_group THEN
        RAISE EXCEPTION '% (%) belongs on the % line, not %',
          v_pid, coalesce(v_player_pos, '?'), v_player_group, v_group;
      END IF;

      -- Keep squad row group in sync with card position
      UPDATE public.gpfl_squad_players sp
      SET position_group = v_player_group,
          is_starter = true,
          pitch_slot = v_group || '_' || v_i::text,
          is_captain = (v_pid = p_captain_id)
      WHERE sp.entry_id = v_entry.id AND sp.player_id = v_pid;

      IF v_pid = p_captain_id THEN
        v_cap_ok := true;
      END IF;
    END LOOP;

    IF v_group = 'gk' THEN v_n_gk := v_i;
    ELSIF v_group = 'def' THEN v_n_def := v_i;
    ELSIF v_group = 'mid' THEN v_n_mid := v_i;
    ELSE v_n_fwd := v_i;
    END IF;
  END LOOP;

  PERFORM public.gpfl_assert_xi_banks(v_n_gk, v_n_def, v_n_mid, v_n_fwd);

  IF NOT v_cap_ok THEN
    RAISE EXCEPTION 'Captain must be one of the 11 starters';
  END IF;

  IF coalesce(array_length(v_seen, 1), 0) <> coalesce(v_cfg.starters, 11) THEN
    RAISE EXCEPTION 'Expected % starters', coalesce(v_cfg.starters, 11);
  END IF;

  IF p_bench_ids IS NOT NULL THEN
    FOR v_i IN 1 .. coalesce(array_length(p_bench_ids, 1), 0) LOOP
      v_pid := nullif(btrim(coalesce(p_bench_ids[v_i], '')), '');
      IF v_pid IS NULL THEN
        CONTINUE;
      END IF;
      IF v_pid = ANY (v_seen) THEN
        RAISE EXCEPTION 'Player % is on the pitch and cannot also be on the bench', v_pid;
      END IF;
      v_seen := v_seen || v_pid;

      UPDATE public.gpfl_squad_players sp
      SET bench_order = v_order
      WHERE sp.entry_id = v_entry.id
        AND sp.player_id = v_pid
        AND sp.slot_status = 'active'
        AND sp.is_starter = false;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Bench player % is not an available squad player', v_pid;
      END IF;

      v_order := v_order + 1;
    END LOOP;
  END IF;

  WITH rest AS (
    SELECT
      sp.id,
      (row_number() OVER (
        ORDER BY
          CASE sp.position_group WHEN 'gk' THEN 1 WHEN 'def' THEN 2 WHEN 'mid' THEN 3 ELSE 4 END,
          sp.id
      ) + v_order - 1)::smallint AS rn
    FROM public.gpfl_squad_players sp
    WHERE sp.entry_id = v_entry.id
      AND sp.slot_status = 'active'
      AND sp.is_starter = false
      AND sp.bench_order IS NULL
  )
  UPDATE public.gpfl_squad_players sp
  SET bench_order = rest.rn
  FROM rest
  WHERE rest.id = sp.id;

  UPDATE public.gpfl_entries e
  SET formation_id = 'banks'
  WHERE e.id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_set_xi(jsonb, text, text[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- Confirm: banks XI, not formation catalogue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_confirm_squad()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_n int;
  v_starters int;
  v_caps int;
  v_n_gk int;
  v_n_def int;
  v_n_mid int;
  v_n_fwd int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_gs_id := public.gpfl_current_season_id();
  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  IF coalesce(v_entry.formation_id, '') <> 'banks' THEN
    RAISE EXCEPTION 'Save pitch XI (4 banks / lines) before confirming';
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';
  IF v_n <> v_cfg.squad_size THEN
    RAISE EXCEPTION 'Need a full squad of % (have %)', v_cfg.squad_size, v_n;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpfl_squad_players
    WHERE entry_id = v_entry.id AND slot_status = 'needs_replace'
  ) THEN
    RAISE EXCEPTION 'Replace free-agent slots before confirming';
  END IF;

  SELECT
    count(*) FILTER (WHERE is_starter)::int,
    count(*) FILTER (WHERE is_captain)::int,
    count(*) FILTER (WHERE is_starter AND position_group = 'gk')::int,
    count(*) FILTER (WHERE is_starter AND position_group = 'def')::int,
    count(*) FILTER (WHERE is_starter AND position_group = 'mid')::int,
    count(*) FILTER (WHERE is_starter AND position_group = 'fwd')::int
  INTO v_starters, v_caps, v_n_gk, v_n_def, v_n_mid, v_n_fwd
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';

  IF v_starters <> coalesce(v_cfg.starters, 11) OR v_caps <> 1 THEN
    RAISE EXCEPTION 'Save pitch XI (%) and exactly 1 captain first', coalesce(v_cfg.starters, 11);
  END IF;

  PERFORM public.gpfl_assert_xi_banks(v_n_gk, v_n_def, v_n_mid, v_n_fwd);

  -- Starter bank must match card position group
  IF EXISTS (
    SELECT 1
    FROM public.gpfl_squad_players sp
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
    WHERE sp.entry_id = v_entry.id
      AND sp.is_starter
      AND public.gpfl_position_group(
            coalesce(nullif(btrim(p."Position"::text), ''), pp.position)
          ) <> sp.position_group
  ) THEN
    RAISE EXCEPTION 'One or more starters are on the wrong bank line';
  END IF;

  UPDATE public.gpfl_entries
  SET status = 'active',
      confirmed_at = coalesce(confirmed_at, now()),
      free_transfers_remaining = v_cfg.free_transfers_per_month
  WHERE id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_confirm_squad() TO authenticated;

-- ---------------------------------------------------------------------------
-- Effective XI: order by bank line, not formation catalogue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_effective_xi(
  p_entry_id bigint,
  p_gpsl_month text
)
RETURNS TABLE (
  player_id text,
  position_group text,
  pitch_slot text,
  is_captain boolean,
  is_bench boolean,
  bench_order smallint,
  apps int,
  base_points numeric,
  multiplier numeric,
  points numeric,
  replaced_player_id text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
#variable_conflict use_column
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_entry public.gpfl_entries%rowtype;
  v_gs_id bigint;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_chip text;
  v_bench_boost boolean := false;
  v_triple boolean := false;
  v_cap_mult numeric;
  v_used text[] := ARRAY[]::text[];
  v_starter record;
  v_sub_id text;
  v_sub_order smallint;
  v_apps int;
  v_pid text;
  v_group text;
  v_replaced text;
  v_bench_order smallint;
  v_base numeric;
  v_mult numeric;
BEGIN
  IF v_month = '' THEN
    RETURN;
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  SELECT * INTO v_entry
  FROM public.gpfl_entries e
  WHERE e.id = p_entry_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_gs_id := v_entry.gpfl_season_id;

  IF coalesce(v_cfg.chips_enabled, true)
     AND v_entry.active_chip IS NOT NULL
     AND (
       v_entry.active_chip_month IS NULL
       OR lower(btrim(v_entry.active_chip_month)) = v_month
     )
  THEN
    v_chip := lower(btrim(v_entry.active_chip));
  END IF;

  v_bench_boost := coalesce(v_chip, '') = 'bench_boost'
    AND coalesce(v_cfg.chip_bench_boost_enabled, true);
  v_triple := coalesce(v_chip, '') = 'triple_captain'
    AND coalesce(v_cfg.chip_triple_captain_enabled, true);

  v_cap_mult := CASE
    WHEN v_triple THEN greatest(3, coalesce(v_cfg.captain_multiplier, 2))
    ELSE greatest(1, coalesce(v_cfg.captain_multiplier, 2))
  END;

  FOR v_starter IN
    SELECT
      sp.player_id AS pid,
      sp.position_group AS pgroup,
      sp.pitch_slot AS slot,
      sp.is_captain AS cap,
      CASE sp.position_group
        WHEN 'gk' THEN 1
        WHEN 'def' THEN 2
        WHEN 'mid' THEN 3
        ELSE 4
      END AS group_sort,
      coalesce(nullif(regexp_replace(coalesce(sp.pitch_slot, ''), '^[a-z]+_', ''), '')::int, 99) AS slot_n
    FROM public.gpfl_squad_players sp
    WHERE sp.entry_id = p_entry_id
      AND sp.slot_status = 'active'
      AND sp.is_starter = true
    ORDER BY
      CASE sp.position_group
        WHEN 'gk' THEN 1
        WHEN 'def' THEN 2
        WHEN 'mid' THEN 3
        ELSE 4
      END,
      coalesce(nullif(regexp_replace(coalesce(sp.pitch_slot, ''), '^[a-z]+_', ''), '')::int, 99),
      sp.player_id
  LOOP
    v_pid := v_starter.pid;
    v_group := v_starter.pgroup;
    v_replaced := NULL;
    v_bench_order := NULL;
    v_used := v_used || v_starter.pid;

    v_apps := public.gpfl_player_month_apps(v_gs_id, v_starter.pid, v_month);

    IF NOT v_bench_boost AND coalesce(v_apps, 0) = 0 THEN
      v_sub_id := NULL;
      v_sub_order := NULL;

      SELECT sp.player_id, sp.bench_order
      INTO v_sub_id, v_sub_order
      FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = p_entry_id
        AND sp.slot_status = 'active'
        AND sp.is_starter = false
        AND sp.position_group = v_group
        AND NOT (sp.player_id = ANY (v_used))
        AND public.gpfl_player_month_apps(v_gs_id, sp.player_id, v_month) > 0
      ORDER BY coalesce(sp.bench_order, 99), sp.player_id
      LIMIT 1;

      IF v_sub_id IS NOT NULL THEN
        v_replaced := v_pid;
        v_pid := v_sub_id;
        v_bench_order := v_sub_order;
        v_used := v_used || v_sub_id;
        v_apps := public.gpfl_player_month_apps(v_gs_id, v_pid, v_month);
      END IF;
    END IF;

    v_base := public.gpfl_player_month_points(v_gs_id, v_pid, v_month);
    v_mult := CASE WHEN v_starter.cap THEN v_cap_mult ELSE 1 END;

    player_id := v_pid;
    position_group := v_group;
    pitch_slot := v_starter.slot;
    is_captain := v_starter.cap;
    is_bench := false;
    bench_order := v_bench_order;
    apps := coalesce(v_apps, 0);
    base_points := coalesce(v_base, 0);
    multiplier := v_mult;
    points := round(coalesce(v_base, 0) * v_mult, 2);
    replaced_player_id := v_replaced;
    RETURN NEXT;
  END LOOP;

  -- Bench boost: remaining unused bench scorers
  IF v_bench_boost THEN
    FOR v_starter IN
      SELECT
        sp.player_id AS pid,
        sp.position_group AS pgroup,
        sp.pitch_slot AS slot,
        sp.bench_order AS bord
      FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = p_entry_id
        AND sp.slot_status = 'active'
        AND sp.is_starter = false
        AND NOT (sp.player_id = ANY (v_used))
      ORDER BY coalesce(sp.bench_order, 99), sp.player_id
    LOOP
      v_apps := public.gpfl_player_month_apps(v_gs_id, v_starter.pid, v_month);
      IF coalesce(v_apps, 0) <= 0 THEN
        CONTINUE;
      END IF;
      v_base := public.gpfl_player_month_points(v_gs_id, v_starter.pid, v_month);
      player_id := v_starter.pid;
      position_group := v_starter.pgroup;
      pitch_slot := v_starter.slot;
      is_captain := false;
      is_bench := true;
      bench_order := v_starter.bord;
      apps := coalesce(v_apps, 0);
      base_points := coalesce(v_base, 0);
      multiplier := 1;
      points := round(coalesce(v_base, 0), 2);
      replaced_player_id := NULL;
      RETURN NEXT;
    END LOOP;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- my_entry: expose xi_banks helper instead of formation slot catalogue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_my_entry()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg jsonb;
  v_cfg_row public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_comp_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_squad jsonb;
  v_season jsonb;
  v_formation jsonb;
  v_xi_banks jsonb;
  v_months jsonb;
  v_open boolean;
  v_month text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_cfg_row FROM public.gpfl_settings WHERE id = 1;
  v_cfg := public.gpfl_settings_get();
  v_gs_id := public.gpfl_current_season_id();

  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', null,
      'editing_open', public.gpfl_editing_open(NULL),
      'target_month', public.gpfl_target_month(NULL),
      'settings', v_cfg,
      'xi_rules', jsonb_build_object(
        'mode', 'banks',
        'gk', jsonb_build_object('min', 1, 'max', 1),
        'def', jsonb_build_object('min', 3, 'max', 5),
        'mid', jsonb_build_object('min', 2, 'max', 5),
        'fwd', jsonb_build_object('min', 1, 'max', 3)
      )
    );
  END IF;

  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  v_open := public.gpfl_editing_open(v_comp_id);
  v_month := public.gpfl_target_month(v_comp_id);

  SELECT to_jsonb(gs.*) INTO v_season
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  SELECT * INTO v_entry
  FROM public.gpfl_entries e
  WHERE e.gpfl_season_id = v_gs_id AND e.owner_id = v_uid;

  IF NOT FOUND OR v_entry.status = 'withdrawn' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', v_gs_id,
      'season', v_season,
      'editing_open', v_open,
      'target_month', v_month,
      'settings', v_cfg,
      'xi_rules', jsonb_build_object(
        'mode', 'banks',
        'gk', jsonb_build_object('min', 1, 'max', 1),
        'def', jsonb_build_object('min', 3, 'max', 5),
        'mid', jsonb_build_object('min', 2, 'max', 5),
        'fwd', jsonb_build_object('min', 1, 'max', 3)
      )
    );
  END IF;

  PERFORM public.gpfl_sync_free_agents(v_gs_id);
  SELECT * INTO v_entry FROM public.gpfl_entries e WHERE e.id = v_entry.id;

  IF coalesce(v_entry.formation_id, '') = 'banks' THEN
    v_formation := jsonb_build_object('formation_id', 'banks', 'mode', 'banks');
  ELSIF v_entry.formation_id IS NOT NULL THEN
    v_formation := jsonb_build_object(
      'formation_id', v_entry.formation_id,
      'mode', 'legacy_formation',
      'needs_resave', true
    );
  END IF;

  SELECT jsonb_build_object(
    'gk', coalesce((
      SELECT jsonb_agg(sp.player_id ORDER BY sp.pitch_slot)
      FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = v_entry.id AND sp.is_starter AND sp.position_group = 'gk'
        AND sp.slot_status = 'active'
    ), '[]'::jsonb),
    'def', coalesce((
      SELECT jsonb_agg(sp.player_id ORDER BY sp.pitch_slot)
      FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = v_entry.id AND sp.is_starter AND sp.position_group = 'def'
        AND sp.slot_status = 'active'
    ), '[]'::jsonb),
    'mid', coalesce((
      SELECT jsonb_agg(sp.player_id ORDER BY sp.pitch_slot)
      FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = v_entry.id AND sp.is_starter AND sp.position_group = 'mid'
        AND sp.slot_status = 'active'
    ), '[]'::jsonb),
    'fwd', coalesce((
      SELECT jsonb_agg(sp.player_id ORDER BY sp.pitch_slot)
      FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = v_entry.id AND sp.is_starter AND sp.position_group = 'fwd'
        AND sp.slot_status = 'active'
    ), '[]'::jsonb)
  ) INTO v_xi_banks;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY
    CASE WHEN x.pitch_slot IS NULL THEN 1 ELSE 0 END,
    coalesce(x.bench_order, 99),
    CASE x.position_group WHEN 'gk' THEN 1 WHEN 'def' THEN 2 WHEN 'mid' THEN 3 ELSE 4 END,
    x.player_name
  ), '[]'::jsonb)
  INTO v_squad
  FROM (
    SELECT
      sp.id,
      sp.player_id,
      sp.position_group,
      sp.purchase_price,
      sp.is_starter,
      sp.is_captain,
      sp.slot_status,
      sp.pitch_slot,
      sp.bench_order,
      coalesce(nullif(btrim(p."Name"), ''), pp.player_name) AS player_name,
      pp.club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), pp.club_short_name) AS club_name,
      CASE
        WHEN c.owner_id IS NULL AND coalesce(nullif(btrim(c.owner), ''), '') = '' THEN 'Vacant'
        ELSE coalesce(
          nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
          nullif(btrim(c.owner), ''),
          'Vacant'
        )
      END AS owner_name,
      pp.division,
      coalesce(nullif(btrim(p."Position"::text), ''), pp.position) AS position,
      pp.price AS current_price,
      pp.eligible,
      public.gpfl_player_month_points(v_gs_id, sp.player_id, v_month) AS month_points,
      public.gpfl_player_month_apps(v_gs_id, sp.player_id, v_month) AS month_apps
    FROM public.gpfl_squad_players sp
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
    LEFT JOIN public."Clubs" c ON c."ShortName" = pp.club_short_name
    WHERE sp.entry_id = v_entry.id
  ) x;

  SELECT coalesce(jsonb_agg(to_jsonb(m2) ORDER BY m2.month_sort), '[]'::jsonb)
  INTO v_months
  FROM (
    SELECT
      mp.gpsl_month,
      coalesce(public.competition_gpsl_month_sort(mp.gpsl_month), 99) AS month_sort,
      mp.points,
      mp.hit_points,
      mp.chip_used,
      mp.is_provisional,
      mp.auto_sub_log
    FROM public.gpfl_entry_month_points mp
    WHERE mp.entry_id = v_entry.id
  ) m2;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
    'joined', true,
    'gpfl_season_id', v_gs_id,
    'season', v_season,
    'settings', v_cfg,
    'entry', to_jsonb(v_entry),
    'formation', v_formation,
    'xi_banks', v_xi_banks,
    'xi_rules', jsonb_build_object(
      'mode', 'banks',
      'gk', jsonb_build_object('min', 1, 'max', 1),
      'def', jsonb_build_object('min', 3, 'max', 5),
      'mid', jsonb_build_object('min', 2, 'max', 5),
      'fwd', jsonb_build_object('min', 1, 'max', 3)
    ),
    'squad', v_squad,
    'month_points', v_months,
    'editing_open', v_open,
    'target_month', v_month,
    'transfer_hit_points', coalesce(v_cfg_row.transfer_hit_points, -4),
    'provisional', jsonb_build_object(
      'month', v_entry.provisional_month,
      'points', coalesce(v_entry.provisional_points, 0)
    ),
    'chips', jsonb_build_object(
      'enabled', coalesce(v_cfg_row.chips_enabled, true),
      'active', v_entry.active_chip,
      'active_month', v_entry.active_chip_month,
      'wildcard', jsonb_build_object(
        'enabled', coalesce(v_cfg_row.chip_wildcard_enabled, true),
        'available', coalesce(v_entry.chip_wildcard_available, true)
      ),
      'triple_captain', jsonb_build_object(
        'enabled', coalesce(v_cfg_row.chip_triple_captain_enabled, true),
        'available', coalesce(v_entry.chip_triple_captain_available, true)
      ),
      'bench_boost', jsonb_build_object(
        'enabled', coalesce(v_cfg_row.chip_bench_boost_enabled, true),
        'available', coalesce(v_entry.chip_bench_boost_available, true)
      )
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_my_entry() TO authenticated;

-- ---------------------------------------------------------------------------
-- Re-stamp pool + squad groups (DMF → mid, LWF/RWF stay mid, etc.)
-- ---------------------------------------------------------------------------
DO $migrate$
DECLARE
  v_gs_id bigint;
BEGIN
  SELECT public.gpfl_current_season_id() INTO v_gs_id;

  IF v_gs_id IS NOT NULL THEN
    UPDATE public.gpfl_player_prices pp
    SET position_group = public.gpfl_position_group(pp.position),
        position = public.gpfl_normalize_card_pos(pp.position)
    WHERE pp.gpfl_season_id = v_gs_id;

    UPDATE public.gpfl_squad_players sp
    SET position_group = public.gpfl_position_group(
      coalesce(
        (
          SELECT nullif(btrim(p."Position"::text), '')
          FROM public."Players" p
          WHERE p."Konami_ID"::text = sp.player_id
          LIMIT 1
        ),
        (
          SELECT pp.position
          FROM public.gpfl_player_prices pp
          JOIN public.gpfl_entries e ON e.id = sp.entry_id
          WHERE pp.gpfl_season_id = e.gpfl_season_id
            AND pp.player_id = sp.player_id
          LIMIT 1
        )
      )
    )
    WHERE sp.entry_id IN (
      SELECT e.id FROM public.gpfl_entries e WHERE e.gpfl_season_id = v_gs_id
    );
  END IF;
END;
$migrate$;

GRANT EXECUTE ON FUNCTION public.gpfl_normalize_card_pos(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_scoring_position_group(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_assert_xi_banks(int, int, int, int) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_pos_fits_slot(text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_position_group(text) TO authenticated, anon;
