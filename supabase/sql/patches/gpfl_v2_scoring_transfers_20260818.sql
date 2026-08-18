-- =============================================================================
-- GPFL v2 — scoring with auto-subs + chips, transfer hits, bench order,
-- dream team and transfer market stats.
--
-- Run AFTER gpfl_v2_core_20260818.sql.
--
-- Play-money only. Never touches competition_finance_ledger or club balances.
-- Safe re-run.
-- =============================================================================

SET statement_timeout = '300s';

-- ---------------------------------------------------------------------------
-- 1. Month scoring — effective XI, captain / triple captain, transfer hits
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_score_month(
  p_gpsl_month text,
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint := p_gpfl_season_id;
  v_comp_id bigint;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_entries int := 0;
  v_subs int := 0;
  v_entry record;
  v_fx record;
  v_base numeric;
  v_hits numeric;
  v_total numeric;
  v_log jsonb;
  v_chip text;
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
    RAISE EXCEPTION 'No GPFL season';
  END IF;
  IF v_month = '' THEN
    RAISE EXCEPTION 'gpsl_month required';
  END IF;

  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  -- Refresh per-fixture player points for the month
  FOR v_fx IN
    SELECT f.id AS fixture_id, m.player_id
    FROM public.competition_fixtures f
    JOIN public.competition_match_player_stats m ON m.fixture_id = f.id
    WHERE f.season_id = v_comp_id
      AND f.status = 'played'
      AND lower(coalesce(f.gpsl_month, '')) = v_month
      AND f.competition_type = ANY (v_cfg.competition_types)
  LOOP
    PERFORM public.gpfl_score_player_fixture(v_fx.fixture_id, v_fx.player_id);
  END LOOP;

  FOR v_entry IN
    SELECT * FROM public.gpfl_entries e
    WHERE e.gpfl_season_id = v_gs_id
      AND e.status = 'active'
  LOOP
    SELECT
      coalesce(sum(x.points), 0),
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'slot', x.pitch_slot,
            'position_group', x.position_group,
            'out', x.replaced_player_id,
            'in', x.player_id,
            'points', x.points,
            'was_captain', x.is_captain
          )
          ORDER BY x.pitch_slot
        ) FILTER (WHERE x.replaced_player_id IS NOT NULL),
        '[]'::jsonb
      )
    INTO v_base, v_log
    FROM public.gpfl_effective_xi(v_entry.id, v_month) x;

    SELECT coalesce(sum(t.hit_points), 0) INTO v_hits
    FROM public.gpfl_transfers t
    WHERE t.entry_id = v_entry.id
      AND t.is_hit = true
      AND lower(coalesce(t.gpsl_month, '')) = v_month;

    -- hit_points are stored negative
    v_total := coalesce(v_base, 0) + least(coalesce(v_hits, 0), 0);

    v_chip := NULL;
    IF coalesce(v_cfg.chips_enabled, true)
       AND v_entry.active_chip IS NOT NULL
       AND (
         v_entry.active_chip_month IS NULL
         OR lower(btrim(v_entry.active_chip_month)) = v_month
       )
    THEN
      v_chip := lower(btrim(v_entry.active_chip));
    END IF;

    v_subs := v_subs + coalesce(jsonb_array_length(v_log), 0);

    INSERT INTO public.gpfl_entry_month_points AS mp (
      entry_id, gpsl_month, points, hit_points, chip_used,
      is_provisional, auto_sub_log, scored_at
    ) VALUES (
      v_entry.id, v_month, v_total, least(coalesce(v_hits, 0), 0), v_chip,
      false, coalesce(v_log, '[]'::jsonb), now()
    )
    ON CONFLICT (entry_id, gpsl_month) DO UPDATE
      SET points = EXCLUDED.points,
          hit_points = EXCLUDED.hit_points,
          chip_used = EXCLUDED.chip_used,
          is_provisional = false,
          auto_sub_log = EXCLUDED.auto_sub_log,
          scored_at = now();

    UPDATE public.gpfl_entries e
    SET total_points = coalesce((
          SELECT sum(m.points)
          FROM public.gpfl_entry_month_points m
          WHERE m.entry_id = e.id
            AND m.is_provisional = false
        ), 0),
        free_transfers_remaining = v_cfg.free_transfers_per_month,
        transfers_used_month = v_month,
        transfers_made_month = 0,
        provisional_points = 0,
        provisional_month = NULL,
        active_chip = CASE
          WHEN e.active_chip_month IS NULL THEN NULL
          WHEN lower(btrim(e.active_chip_month)) = v_month THEN NULL
          ELSE e.active_chip
        END,
        active_chip_month = CASE
          WHEN e.active_chip_month IS NULL THEN NULL
          WHEN lower(btrim(e.active_chip_month)) = v_month THEN NULL
          ELSE e.active_chip_month
        END
    WHERE e.id = v_entry.id;

    v_entries := v_entries + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpfl_season_id', v_gs_id,
    'entries_scored', v_entries,
    'auto_subs', v_subs
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_score_month(text, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Provisional (live) points for a month in progress
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_refresh_provisional(
  p_gpsl_month text DEFAULT NULL,
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint := p_gpfl_season_id;
  v_comp_id bigint;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_entry record;
  v_fx record;
  v_base numeric;
  v_hits numeric;
  v_total numeric;
  v_log jsonb;
  v_chip text;
  v_entries int := 0;
BEGIN
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season');
  END IF;

  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  IF v_month = '' THEN
    v_month := coalesce(public.gpfl_target_month(v_comp_id), '');
  END IF;
  IF v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_month');
  END IF;

  FOR v_fx IN
    SELECT f.id AS fixture_id, m.player_id
    FROM public.competition_fixtures f
    JOIN public.competition_match_player_stats m ON m.fixture_id = f.id
    WHERE f.season_id = v_comp_id
      AND f.status = 'played'
      AND lower(coalesce(f.gpsl_month, '')) = v_month
      AND f.competition_type = ANY (v_cfg.competition_types)
  LOOP
    PERFORM public.gpfl_score_player_fixture(v_fx.fixture_id, v_fx.player_id);
  END LOOP;

  FOR v_entry IN
    SELECT * FROM public.gpfl_entries e
    WHERE e.gpfl_season_id = v_gs_id
      AND e.status = 'active'
  LOOP
    SELECT
      coalesce(sum(x.points), 0),
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'slot', x.pitch_slot,
            'position_group', x.position_group,
            'out', x.replaced_player_id,
            'in', x.player_id,
            'points', x.points,
            'was_captain', x.is_captain
          )
          ORDER BY x.pitch_slot
        ) FILTER (WHERE x.replaced_player_id IS NOT NULL),
        '[]'::jsonb
      )
    INTO v_base, v_log
    FROM public.gpfl_effective_xi(v_entry.id, v_month) x;

    SELECT coalesce(sum(t.hit_points), 0) INTO v_hits
    FROM public.gpfl_transfers t
    WHERE t.entry_id = v_entry.id
      AND t.is_hit = true
      AND lower(coalesce(t.gpsl_month, '')) = v_month;

    v_total := coalesce(v_base, 0) + least(coalesce(v_hits, 0), 0);

    v_chip := NULL;
    IF coalesce(v_cfg.chips_enabled, true)
       AND v_entry.active_chip IS NOT NULL
       AND (
         v_entry.active_chip_month IS NULL
         OR lower(btrim(v_entry.active_chip_month)) = v_month
       )
    THEN
      v_chip := lower(btrim(v_entry.active_chip));
    END IF;

    -- Never overwrite a finalised month
    INSERT INTO public.gpfl_entry_month_points AS mp (
      entry_id, gpsl_month, points, hit_points, chip_used,
      is_provisional, auto_sub_log, scored_at
    ) VALUES (
      v_entry.id, v_month, v_total, least(coalesce(v_hits, 0), 0), v_chip,
      true, coalesce(v_log, '[]'::jsonb), now()
    )
    ON CONFLICT (entry_id, gpsl_month) DO UPDATE
      SET points = EXCLUDED.points,
          hit_points = EXCLUDED.hit_points,
          chip_used = EXCLUDED.chip_used,
          auto_sub_log = EXCLUDED.auto_sub_log,
          scored_at = now()
      WHERE mp.is_provisional = true;

    UPDATE public.gpfl_entries e
    SET provisional_points = v_total,
        provisional_month = v_month
    WHERE e.id = v_entry.id;

    v_entries := v_entries + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpfl_season_id', v_gs_id,
    'entries_updated', v_entries,
    'provisional', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_refresh_provisional(text, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. my_entry — editing window, bench order, chips, provisional
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
      'settings', v_cfg
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
      'settings', v_cfg
    );
  END IF;

  PERFORM public.gpfl_sync_free_agents(v_gs_id);
  SELECT * INTO v_entry FROM public.gpfl_entries e WHERE e.id = v_entry.id;

  IF v_entry.formation_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'formation_id', v_entry.formation_id,
      'slots', coalesce(jsonb_agg(
        jsonb_build_object(
          'slot_id', fs.slot_id,
          'required_pos', fs.required_pos,
          'sort_order', fs.sort_order
        ) ORDER BY fs.sort_order
      ), '[]'::jsonb)
    )
    INTO v_formation
    FROM public.gpfl_formation_slots fs
    WHERE fs.formation_id = v_entry.formation_id;
  END IF;

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
-- 4. Set XI — formation slots + bench order
--    Drop older overloads first so the new default-arg signature is unambiguous.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.gpfl_set_xi(text[], text);
DROP FUNCTION IF EXISTS public.gpfl_set_xi(text, jsonb, text);

CREATE OR REPLACE FUNCTION public.gpfl_set_xi(
  p_formation_id text,
  p_slot_map jsonb,
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
  v_slot record;
  v_pid text;
  v_player_pos text;
  v_seen text[] := ARRAY[]::text[];
  v_cap_ok boolean := false;
  v_i int;
  v_order smallint := 1;
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

  IF p_formation_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.gpfl_formation_slots WHERE formation_id = p_formation_id
  ) THEN
    RAISE EXCEPTION 'Unknown formation %', coalesce(p_formation_id, '(null)');
  END IF;

  IF p_slot_map IS NULL OR jsonb_typeof(p_slot_map) <> 'object' THEN
    RAISE EXCEPTION 'p_slot_map must be a JSON object of slot_id → player_id';
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

  FOR v_slot IN
    SELECT * FROM public.gpfl_formation_slots fs
    WHERE fs.formation_id = p_formation_id
    ORDER BY fs.sort_order
  LOOP
    v_pid := nullif(btrim(coalesce(p_slot_map ->> v_slot.slot_id, '')), '');
    IF v_pid IS NULL THEN
      RAISE EXCEPTION 'Fill every pitch slot (% needs a player)', v_slot.slot_id;
    END IF;
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

    SELECT pp.position INTO v_player_pos
    FROM public.gpfl_player_prices pp
    WHERE pp.gpfl_season_id = v_gs_id AND pp.player_id = v_pid;

    IF v_player_pos IS NULL THEN
      SELECT p."Position"::text INTO v_player_pos
      FROM public."Players" p
      WHERE p."Konami_ID"::text = v_pid;
    END IF;

    IF NOT public.gpfl_pos_fits_slot(v_player_pos, v_slot.required_pos) THEN
      RAISE EXCEPTION '% (%) cannot play % slot (needs %)',
        v_pid, coalesce(v_player_pos, '?'), v_slot.slot_id, v_slot.required_pos;
    END IF;

    IF v_pid = p_captain_id THEN
      v_cap_ok := true;
    END IF;

    UPDATE public.gpfl_squad_players sp
    SET is_starter = true,
        pitch_slot = v_slot.slot_id,
        is_captain = (v_pid = p_captain_id)
    WHERE sp.entry_id = v_entry.id AND sp.player_id = v_pid;
  END LOOP;

  IF NOT v_cap_ok THEN
    RAISE EXCEPTION 'Captain must be one of the 11 starters';
  END IF;

  IF coalesce(array_length(v_seen, 1), 0) <> v_cfg.starters THEN
    RAISE EXCEPTION 'Expected % starters', v_cfg.starters;
  END IF;

  -- Bench priority: explicit order first, then anything left over
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
  SET formation_id = p_formation_id
  WHERE e.id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_set_xi(text, jsonb, text, text[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Transfers in / out with hits
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_add_player(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_comp_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_price public.gpfl_player_prices%rowtype;
  v_count int;
  v_club_count int;
  v_pos_count int;
  v_slot_cap int;
  v_club text;
  v_owner uuid;
  v_month text;
  v_forced boolean := false;
  v_wildcard boolean := false;
  v_is_hit boolean := false;
  v_hit numeric := 0;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.enabled, true) THEN RAISE EXCEPTION 'GPFL disabled'; END IF;

  v_gs_id := public.gpfl_current_season_id();
  IF v_gs_id IS NULL THEN RAISE EXCEPTION 'No GPFL season'; END IF;
  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  SELECT * INTO v_entry
  FROM public.gpfl_entries e
  WHERE e.gpfl_season_id = v_gs_id
    AND e.owner_id = v_uid
    AND e.status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  PERFORM public.gpfl_assert_editing_open(v_entry);

  v_month := coalesce(public.gpfl_target_month(v_comp_id), 'august');

  -- Pool rules: contracted, owned club, GPFL division
  SELECT p."Contracted_Team" INTO v_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id;

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'Player is not contracted — not available in GPFL';
  END IF;

  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Vacant clubs are not available in GPFL';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_comp_id
      AND ccs.club_short_name = v_club
      AND ccs.division = ANY (v_cfg.divisions)
  ) THEN
    RAISE EXCEPTION 'Player club is outside the GPFL pool divisions';
  END IF;

  SELECT * INTO v_price
  FROM public.gpfl_player_prices pp
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.player_id = p_player_id
    AND pp.eligible = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not in GPFL pool'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpfl_squad_players sp
    WHERE sp.entry_id = v_entry.id
      AND sp.player_id = p_player_id
      AND sp.slot_status = 'active'
  ) THEN
    RAISE EXCEPTION 'Already in your squad';
  END IF;

  DELETE FROM public.gpfl_squad_players sp
  WHERE sp.entry_id = v_entry.id
    AND sp.player_id = p_player_id
    AND sp.slot_status = 'needs_replace';

  SELECT count(*)::int INTO v_count
  FROM public.gpfl_squad_players sp
  WHERE sp.entry_id = v_entry.id AND sp.slot_status = 'active';
  IF v_count >= v_cfg.squad_size THEN
    RAISE EXCEPTION 'Squad full (% players)', v_cfg.squad_size;
  END IF;

  SELECT count(*)::int INTO v_club_count
  FROM public.gpfl_squad_players sp
  JOIN public.gpfl_player_prices pp
    ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
  WHERE sp.entry_id = v_entry.id
    AND sp.slot_status = 'active'
    AND pp.club_short_name = v_club;
  IF v_club_count >= v_cfg.max_per_club THEN
    RAISE EXCEPTION 'Max % players from one club', v_cfg.max_per_club;
  END IF;

  SELECT count(*)::int INTO v_pos_count
  FROM public.gpfl_squad_players sp
  WHERE sp.entry_id = v_entry.id
    AND sp.slot_status = 'active'
    AND sp.position_group = v_price.position_group;

  v_slot_cap := CASE v_price.position_group
    WHEN 'gk' THEN v_cfg.slot_gk
    WHEN 'def' THEN v_cfg.slot_def
    WHEN 'mid' THEN v_cfg.slot_mid
    ELSE v_cfg.slot_fwd
  END;
  IF v_pos_count >= v_slot_cap THEN
    RAISE EXCEPTION 'No % slots left', upper(v_price.position_group);
  END IF;

  IF v_entry.budget_remaining < v_price.price THEN
    RAISE EXCEPTION 'Not enough GPFL budget (need ₿%, have ₿%)',
      round(v_price.price), round(v_entry.budget_remaining);
  END IF;

  IF v_entry.status = 'active' THEN
    v_forced := EXISTS (
      SELECT 1 FROM public.gpfl_squad_players sp
      WHERE sp.entry_id = v_entry.id AND sp.slot_status = 'needs_replace'
    );

    v_wildcard := coalesce(v_cfg.chips_enabled, true)
      AND coalesce(v_cfg.chip_wildcard_enabled, true)
      AND lower(btrim(coalesce(v_entry.active_chip, ''))) = 'wildcard'
      AND (
        v_entry.active_chip_month IS NULL
        OR lower(btrim(v_entry.active_chip_month)) = v_month
      );

    IF v_forced OR v_wildcard THEN
      -- Free: forced free-agent replacement or wildcard active
      NULL;
    ELSIF coalesce(v_entry.free_transfers_remaining, 0) > 0 THEN
      UPDATE public.gpfl_entries e
      SET free_transfers_remaining = e.free_transfers_remaining - 1
      WHERE e.id = v_entry.id;
    ELSE
      v_is_hit := true;
      v_hit := -abs(coalesce(v_cfg.transfer_hit_points, -4));

      UPDATE public.gpfl_entries e
      SET transfer_hits_season = coalesce(e.transfer_hits_season, 0) + 1
      WHERE e.id = v_entry.id;
    END IF;

    UPDATE public.gpfl_entries e
    SET transfers_made_month = coalesce(e.transfers_made_month, 0) + 1
    WHERE e.id = v_entry.id;
  END IF;

  INSERT INTO public.gpfl_squad_players (
    entry_id, player_id, position_group, purchase_price, slot_status
  ) VALUES (
    v_entry.id, p_player_id, v_price.position_group, v_price.price, 'active'
  );

  UPDATE public.gpfl_entries e
  SET budget_remaining = e.budget_remaining - v_price.price
  WHERE e.id = v_entry.id;

  -- Log the move (pair with an unmatched sale this month when there is one)
  IF v_entry.status = 'active' THEN
    UPDATE public.gpfl_transfers t
    SET player_in = p_player_id,
        is_hit = v_is_hit,
        hit_points = v_hit
    WHERE t.id = (
      SELECT t2.id
      FROM public.gpfl_transfers t2
      WHERE t2.entry_id = v_entry.id
        AND lower(coalesce(t2.gpsl_month, '')) = v_month
        AND t2.player_in IS NULL
        AND t2.player_out IS NOT NULL
      ORDER BY t2.created_at DESC, t2.id DESC
      LIMIT 1
    );

    IF NOT FOUND THEN
      INSERT INTO public.gpfl_transfers (
        gpfl_season_id, entry_id, player_in, player_out, gpsl_month, is_hit, hit_points
      ) VALUES (
        v_gs_id, v_entry.id, p_player_id, NULL, v_month, v_is_hit, v_hit
      );
    END IF;
  END IF;

  RETURN public.gpfl_my_entry();
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_remove_player(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_gs_id bigint;
  v_comp_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_sp public.gpfl_squad_players%rowtype;
  v_month text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  v_gs_id := public.gpfl_current_season_id();
  IF v_gs_id IS NULL THEN RAISE EXCEPTION 'No GPFL season'; END IF;

  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  SELECT * INTO v_entry
  FROM public.gpfl_entries e
  WHERE e.gpfl_season_id = v_gs_id
    AND e.owner_id = v_uid
    AND e.status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  PERFORM public.gpfl_assert_editing_open(v_entry);

  v_month := coalesce(public.gpfl_target_month(v_comp_id), 'august');

  SELECT * INTO v_sp
  FROM public.gpfl_squad_players sp
  WHERE sp.entry_id = v_entry.id AND sp.player_id = p_player_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not in squad'; END IF;

  -- Selling is always a plain refund. Any points hit was charged on the
  -- incoming half of the transfer.
  IF v_sp.slot_status = 'active' THEN
    UPDATE public.gpfl_entries e
    SET budget_remaining = e.budget_remaining + v_sp.purchase_price
    WHERE e.id = v_entry.id;
  END IF;

  DELETE FROM public.gpfl_squad_players sp WHERE sp.id = v_sp.id;

  IF v_entry.status = 'active' AND v_sp.slot_status = 'active' THEN
    UPDATE public.gpfl_transfers t
    SET player_out = p_player_id
    WHERE t.id = (
      SELECT t2.id
      FROM public.gpfl_transfers t2
      WHERE t2.entry_id = v_entry.id
        AND lower(coalesce(t2.gpsl_month, '')) = v_month
        AND t2.player_out IS NULL
        AND t2.player_in IS NOT NULL
      ORDER BY t2.created_at DESC, t2.id DESC
      LIMIT 1
    );

    IF NOT FOUND THEN
      INSERT INTO public.gpfl_transfers (
        gpfl_season_id, entry_id, player_in, player_out, gpsl_month, is_hit, hit_points
      ) VALUES (
        v_gs_id, v_entry.id, NULL, p_player_id, v_month, false, 0
      );
    END IF;
  END IF;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_add_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_remove_player(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Dream team for a month (4-4-2 shape from the whole pool)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_dream_team(p_gpsl_month text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint := public.gpfl_current_season_id();
  v_comp_id bigint;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_rows jsonb;
  v_total numeric;
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season', 'players', '[]'::jsonb);
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  IF v_month = '' THEN
    v_month := coalesce(public.gpfl_target_month(v_comp_id), '');
  END IF;
  IF v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_month', 'players', '[]'::jsonb);
  END IF;

  SELECT
    coalesce(jsonb_agg(to_jsonb(picked) ORDER BY picked.group_sort, picked.rn), '[]'::jsonb),
    coalesce(sum(picked.points), 0)
  INTO v_rows, v_total
  FROM (
    WITH scored AS (
      SELECT
        pfp.player_id,
        sum(pfp.points) AS pts,
        count(*)::int AS fixtures
      FROM public.gpfl_player_fixture_points pfp
      LEFT JOIN public.competition_fixtures f ON f.id = pfp.fixture_id
      WHERE pfp.gpfl_season_id = v_gs_id
        AND lower(coalesce(pfp.gpsl_month, f.gpsl_month, '')) = v_month
      GROUP BY pfp.player_id
    ),
    pool AS (
      SELECT
        s.player_id,
        s.pts,
        s.fixtures,
        pp.position_group,
        pp.price,
        coalesce(nullif(btrim(p."Name"), ''), pp.player_name) AS player_name,
        coalesce(nullif(btrim(p."Position"::text), ''), pp.position) AS position,
        p."Contracted_Team" AS club_short_name,
        coalesce(nullif(btrim(c."Club"), ''), p."Contracted_Team") AS club_name,
        ccs.division
      FROM scored s
      JOIN public.gpfl_player_prices pp
        ON pp.gpfl_season_id = v_gs_id AND pp.player_id = s.player_id
      JOIN public."Players" p ON p."Konami_ID"::text = s.player_id
      JOIN public."Clubs" c
        ON c."ShortName" = p."Contracted_Team"
       AND c.owner_id IS NOT NULL
      JOIN public.competition_club_seasons ccs
        ON ccs.club_short_name = p."Contracted_Team"
       AND ccs.season_id = v_comp_id
       AND ccs.division = ANY (v_cfg.divisions)
    ),
    ranked AS (
      SELECT
        pool.*,
        row_number() OVER (
          PARTITION BY pool.position_group
          ORDER BY pool.pts DESC, pool.price DESC, pool.player_name
        ) AS rn
      FROM pool
    )
    SELECT
      r.player_id,
      r.player_name,
      r.club_short_name,
      r.club_name,
      r.division,
      r.position,
      r.position_group,
      r.price,
      r.fixtures,
      round(r.pts, 2) AS points,
      public.gpfl_ownership_pct(v_gs_id, r.player_id) AS ownership_pct,
      CASE r.position_group
        WHEN 'gk' THEN 1
        WHEN 'def' THEN 2
        WHEN 'mid' THEN 3
        ELSE 4
      END AS group_sort,
      r.rn
    FROM ranked r
    WHERE (r.position_group = 'gk' AND r.rn <= 1)
       OR (r.position_group = 'def' AND r.rn <= 4)
       OR (r.position_group = 'mid' AND r.rn <= 4)
       OR (r.position_group = 'fwd' AND r.rn <= 2)
  ) picked;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'gpsl_month', v_month,
    'shape', '4-4-2',
    'total_points', v_total,
    'players', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_dream_team(text) TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- 7. Most transferred in / out
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_top_transfers(
  p_gpsl_month text DEFAULT NULL,
  p_limit int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_comp_id bigint;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_lim int := greatest(1, least(coalesce(p_limit, 10), 50));
  v_in jsonb;
  v_out jsonb;
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'no_gpfl_season',
      'transfers_in', '[]'::jsonb, 'transfers_out', '[]'::jsonb
    );
  END IF;

  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  IF v_month = '' THEN
    v_month := coalesce(public.gpfl_target_month(v_comp_id), '');
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.transfers DESC, r.player_name), '[]'::jsonb)
  INTO v_in
  FROM (
    SELECT
      t.player_in AS player_id,
      coalesce(nullif(btrim(p."Name"), ''), pp.player_name, t.player_in) AS player_name,
      coalesce(pp.club_short_name, p."Contracted_Team") AS club_short_name,
      pp.position_group,
      pp.price,
      count(*)::int AS transfers,
      count(*) FILTER (WHERE t.is_hit)::int AS hits,
      public.gpfl_ownership_pct(v_gs_id, t.player_in) AS ownership_pct
    FROM public.gpfl_transfers t
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = t.player_in
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_in
    WHERE t.gpfl_season_id = v_gs_id
      AND t.player_in IS NOT NULL
      AND (v_month = '' OR lower(coalesce(t.gpsl_month, '')) = v_month)
    GROUP BY t.player_in, p."Name", pp.player_name, pp.club_short_name,
             p."Contracted_Team", pp.position_group, pp.price
    ORDER BY count(*) DESC
    LIMIT v_lim
  ) r;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.transfers DESC, r.player_name), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT
      t.player_out AS player_id,
      coalesce(nullif(btrim(p."Name"), ''), pp.player_name, t.player_out) AS player_name,
      coalesce(pp.club_short_name, p."Contracted_Team") AS club_short_name,
      pp.position_group,
      pp.price,
      count(*)::int AS transfers,
      public.gpfl_ownership_pct(v_gs_id, t.player_out) AS ownership_pct
    FROM public.gpfl_transfers t
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = t.player_out
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_out
    WHERE t.gpfl_season_id = v_gs_id
      AND t.player_out IS NOT NULL
      AND (v_month = '' OR lower(coalesce(t.gpsl_month, '')) = v_month)
    GROUP BY t.player_out, p."Name", pp.player_name, pp.club_short_name,
             p."Contracted_Team", pp.position_group, pp.price
    ORDER BY count(*) DESC
    LIMIT v_lim
  ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'gpsl_month', nullif(v_month, ''),
    'transfers_in', v_in,
    'transfers_out', v_out
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_top_transfers(text, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Player board — contracted + owned clubs only, now with ownership %
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_list_players(
  p_position_group text DEFAULT NULL,
  p_division text DEFAULT NULL,
  p_club text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_max_price numeric DEFAULT NULL,
  p_limit int DEFAULT 80,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_comp_id bigint;
  v_cfg public.gpfl_settings%rowtype;
  v_rows jsonb;
  v_total int;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season', 'players', '[]'::jsonb);
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT count(*)::int INTO v_total
  FROM public.gpfl_player_prices pp
  JOIN public."Players" p ON p."Konami_ID"::text = pp.player_id
  JOIN public.competition_club_seasons ccs
    ON ccs.club_short_name = p."Contracted_Team"
   AND ccs.season_id = v_comp_id
  JOIN public."Clubs" c
    ON c."ShortName" = p."Contracted_Team"
   AND c.owner_id IS NOT NULL
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND p."Contracted_Team" IS NOT NULL
    AND btrim(p."Contracted_Team") <> ''
    AND ccs.division = ANY (v_cfg.divisions)
    AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
    AND (p_division IS NULL OR ccs.division = p_division OR pp.division = p_division)
    AND (
      p_club IS NULL
      OR p."Contracted_Team" = p_club
      OR pp.club_short_name = p_club
      OR coalesce(c."Club", '') ILIKE p_club
    )
    AND (p_max_price IS NULL OR pp.price <= p_max_price)
    AND (
      v_q IS NULL
      OR pp.player_name ILIKE '%' || v_q || '%'
      OR p."Name" ILIKE '%' || v_q || '%'
      OR p."Contracted_Team" ILIKE '%' || v_q || '%'
      OR pp.club_short_name ILIKE '%' || v_q || '%'
      OR coalesce(c."Club", '') ILIKE '%' || v_q || '%'
      OR coalesce(public.competition_owner_display_name(c.owner_id), '') ILIKE '%' || v_q || '%'
      OR coalesce(c.owner, '') ILIKE '%' || v_q || '%'
    );

  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      pp.player_id,
      coalesce(nullif(btrim(p."Name"), ''), pp.player_name) AS player_name,
      p."Contracted_Team" AS club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), p."Contracted_Team") AS club_name,
      coalesce(
        nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
        nullif(btrim(c.owner), ''),
        'Owner'
      ) AS owner_name,
      ccs.division,
      coalesce(nullif(btrim(p."Position"::text), ''), pp.position) AS position,
      pp.position_group,
      pp.price,
      pp.market_value_raw,
      public.gpfl_ownership_pct(v_gs_id, pp.player_id) AS ownership_pct,
      coalesce((
        SELECT sum(pfp.points)
        FROM public.gpfl_player_fixture_points pfp
        WHERE pfp.gpfl_season_id = v_gs_id
          AND pfp.player_id = pp.player_id
      ), 0) AS total_points
    FROM public.gpfl_player_prices pp
    JOIN public."Players" p ON p."Konami_ID"::text = pp.player_id
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = p."Contracted_Team"
     AND ccs.season_id = v_comp_id
    JOIN public."Clubs" c
      ON c."ShortName" = p."Contracted_Team"
     AND c.owner_id IS NOT NULL
    WHERE pp.gpfl_season_id = v_gs_id
      AND pp.eligible = true
      AND p."Contracted_Team" IS NOT NULL
      AND btrim(p."Contracted_Team") <> ''
      AND ccs.division = ANY (v_cfg.divisions)
      AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
      AND (p_division IS NULL OR ccs.division = p_division OR pp.division = p_division)
      AND (
        p_club IS NULL
        OR p."Contracted_Team" = p_club
        OR pp.club_short_name = p_club
        OR coalesce(c."Club", '') ILIKE p_club
      )
      AND (p_max_price IS NULL OR pp.price <= p_max_price)
      AND (
        v_q IS NULL
        OR pp.player_name ILIKE '%' || v_q || '%'
        OR p."Name" ILIKE '%' || v_q || '%'
        OR p."Contracted_Team" ILIKE '%' || v_q || '%'
        OR pp.club_short_name ILIKE '%' || v_q || '%'
        OR coalesce(c."Club", '') ILIKE '%' || v_q || '%'
        OR coalesce(public.competition_owner_display_name(c.owner_id), '') ILIKE '%' || v_q || '%'
        OR coalesce(c.owner, '') ILIKE '%' || v_q || '%'
      )
    ORDER BY pp.price DESC, coalesce(p."Name", pp.player_name)
    LIMIT greatest(1, least(coalesce(p_limit, 80), 200))
    OFFSET greatest(0, coalesce(p_offset, 0))
  ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'total', v_total,
    'players', v_rows,
    'contracted_only', true,
    'owned_clubs_only', true,
    'editing_open', public.gpfl_editing_open(v_comp_id)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_list_players(text, text, text, text, numeric, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
