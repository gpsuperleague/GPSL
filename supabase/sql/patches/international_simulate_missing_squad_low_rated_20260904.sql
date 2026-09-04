-- =============================================================================
-- FIX: international simulate — potm "false"::int + missing-squad testing XI
--
-- Error: invalid input syntax for type integer: "false"
-- Cause: international_apply_player_stats did
--   coalesce((v_item->>'potm')::boolean, false)
--   OR coalesce((v_item->>'potm')::int, 0) > 0
-- When potm is JSON false, the left side is false so Postgres still evaluates
-- the ::int cast on text "false" and blows up.
--
-- Also: when a nation has no matchday / call-up XI, assemble a random low-rated
-- testing XI from that nation's GPDB pool (prefer ≤65, else ≤72, else anyone).
-- Selected matchday or active call-up squads are still used when present.
--
-- Safe re-run in Supabase SQL Editor, then retry Simulate.
-- =============================================================================

SET lock_timeout = '15s';
SET statement_timeout = '60s';

-- ---------------------------------------------------------------------------
-- Safe potm / clean_sheet parsing (boolean or numeric, never boolean→int)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_apply_player_stats(
  p_player_stats jsonb,
  p_record_appearances boolean DEFAULT true
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_pid text;
  v_goals int;
  v_assists int;
  v_rating numeric;
  v_potm int;
  v_cs int;
  v_count int := 0;
  v_potm_raw jsonb;
  v_cs_raw jsonb;
BEGIN
  IF p_player_stats IS NULL OR jsonb_typeof(p_player_stats) <> 'array' THEN
    RETURN 0;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_player_stats)
  LOOP
    v_pid := nullif(btrim(coalesce(v_item->>'player_id', v_item->>'Konami_ID', '')), '');
    IF v_pid IS NULL THEN
      CONTINUE;
    END IF;

    v_goals := greatest(coalesce((v_item->>'goals')::int, 0), 0);
    v_assists := greatest(coalesce((v_item->>'assists')::int, 0), 0);
    v_rating := nullif(v_item->>'rating', '')::numeric;

    v_potm_raw := v_item->'potm';
    v_potm := CASE
      WHEN v_potm_raw IS NULL OR v_potm_raw = 'null'::jsonb THEN 0
      WHEN jsonb_typeof(v_potm_raw) = 'boolean' THEN
        CASE WHEN (v_item->>'potm')::boolean THEN 1 ELSE 0 END
      WHEN jsonb_typeof(v_potm_raw) = 'number' THEN
        CASE WHEN coalesce((v_item->>'potm')::numeric, 0) > 0 THEN 1 ELSE 0 END
      WHEN lower(coalesce(v_item->>'potm', '')) IN ('true', 't', 'yes', '1') THEN 1
      WHEN lower(coalesce(v_item->>'potm', '')) IN ('false', 'f', 'no', '0', '') THEN 0
      ELSE CASE WHEN coalesce(nullif(v_item->>'potm', '')::numeric, 0) > 0 THEN 1 ELSE 0 END
    END;

    v_cs_raw := coalesce(v_item->'clean_sheet', v_item->'clean_sheets');
    v_cs := CASE
      WHEN v_cs_raw IS NULL OR v_cs_raw = 'null'::jsonb THEN 0
      WHEN jsonb_typeof(v_cs_raw) = 'boolean' THEN
        CASE WHEN (v_cs_raw #>> '{}')::boolean THEN 1 ELSE 0 END
      WHEN jsonb_typeof(v_cs_raw) = 'number' THEN
        CASE WHEN coalesce((v_cs_raw #>> '{}')::numeric, 0) > 0 THEN 1 ELSE 0 END
      WHEN lower(coalesce(v_cs_raw #>> '{}', '')) IN ('true', 't', 'yes', '1') THEN 1
      WHEN lower(coalesce(v_cs_raw #>> '{}', '')) IN ('false', 'f', 'no', '0', '') THEN 0
      ELSE CASE WHEN coalesce(nullif(v_cs_raw #>> '{}', '')::numeric, 0) > 0 THEN 1 ELSE 0 END
    END;

    INSERT INTO public.international_player_career (
      player_id, caps, goals, assists, potm, clean_sheets,
      rating_sum, rating_count, updated_at
    )
    VALUES (
      v_pid, 1, v_goals, v_assists, v_potm, v_cs,
      coalesce(v_rating, 0), CASE WHEN v_rating IS NOT NULL THEN 1 ELSE 0 END, now()
    )
    ON CONFLICT (player_id) DO UPDATE
    SET caps = public.international_player_career.caps + 1,
        goals = public.international_player_career.goals + EXCLUDED.goals,
        assists = public.international_player_career.assists + EXCLUDED.assists,
        potm = public.international_player_career.potm + EXCLUDED.potm,
        clean_sheets = public.international_player_career.clean_sheets + EXCLUDED.clean_sheets,
        rating_sum = public.international_player_career.rating_sum + EXCLUDED.rating_sum,
        rating_count = public.international_player_career.rating_count + EXCLUDED.rating_count,
        updated_at = now();

    IF p_record_appearances
       AND to_regprocedure('public.international_record_callup_appearance(text)') IS NOT NULL THEN
      PERFORM public.international_record_callup_appearance(v_pid);
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Nation XI loader: selected squad when present; else low-rated testing XI
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_sim_load_nation_side(p_nation_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := upper(nullif(btrim(p_nation_code), ''));
  v_rows jsonb := '[]'::jsonb;
  v_n int := 0;
  v_name text;
  v_source text := 'none';
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'Nation code required';
  END IF;

  SELECT n.name INTO v_name
  FROM public.international_nations n
  WHERE n.code = v_nation;

  -- 1) Saved matchday pitch XI (preferred when present)
  IF to_regclass('public.international_matchday_squad_player') IS NOT NULL THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', sp.player_id,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(sp.pitch_slot, p."Position"),
          'pitch_slot', sp.pitch_slot,
          'profile_pos', p."Position",
          'on_natural', public.match_sim_on_natural_position(sp.pitch_slot, p."Position"),
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        )
        ORDER BY sp.sort_order NULLS LAST, sp.pitch_slot, p."Name"
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM public.international_matchday_squad_player sp
    JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
    WHERE sp.nation_code = v_nation
      AND sp.slot_kind = 'pitch';

    v_n := jsonb_array_length(v_rows);
    IF v_n >= 11 THEN
      v_source := 'matchday';
    END IF;
  END IF;

  -- 2) Active call-ups by rating (still a deliberate squad)
  IF v_n < 11 AND to_regclass('public.international_squad_callups') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(x.obj ORDER BY x.ord), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', c.player_id,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL, p."Position"),
          'pitch_slot', NULL,
          'profile_pos', p."Position",
          'on_natural', true,
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        ) AS obj,
        row_number() OVER (
          ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
        ) AS ord
      FROM public.international_squad_callups c
      JOIN public."Players" p ON p."Konami_ID"::text = c.player_id
      WHERE c.nation_code = v_nation
        AND c.is_active = true
      LIMIT 11
    ) x;

    v_n := jsonb_array_length(v_rows);
    IF v_n >= 11 THEN
      v_source := 'callups';
    END IF;
  END IF;

  -- 3) Testing fallback: random low-rated pool from this nationality
  --    Prefer ≤65; if short, fill from ≤72; then anyone. ORDER BY band keeps
  --    better (lower) bands first while randomising within each band.
  IF v_n < 11 THEN
    SELECT coalesce(jsonb_agg(x.obj ORDER BY x.ord), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL, p."Position"),
          'pitch_slot', NULL,
          'profile_pos', p."Position",
          'on_natural', true,
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          ),
          'testing_xi', true
        ) AS obj,
        row_number() OVER (
          ORDER BY
            CASE
              WHEN public.match_sim_player_rating_num(p."Rating"::text, 99) <= 65 THEN 1
              WHEN public.match_sim_player_rating_num(p."Rating"::text, 99) <= 72 THEN 2
              ELSE 3
            END,
            -- Prefer at least one GK early in the random pack
            CASE
              WHEN public.match_sim_role_from_slot(NULL, p."Position") = 'gk' THEN 0
              ELSE 1
            END,
            random()
        ) AS ord
      FROM public."Players" p
      WHERE public.international_normalize_nation_label(p."Nation")
              = public.international_normalize_nation_label(coalesce(v_name, v_nation))
         OR public.international_normalize_nation_label(p."Nation") = v_nation
      LIMIT 11
    ) x;

    v_n := jsonb_array_length(v_rows);
    IF v_n >= 11 THEN
      v_source := 'low_rated_pool';
    END IF;
  END IF;

  IF v_n < 11 THEN
    RAISE EXCEPTION
      'Nation % needs at least 11 players to simulate (have %). Call up a squad or refresh the GPDB pool.',
      v_nation, v_n;
  END IF;

  -- Optional bench from matchday (only when we used the selected pitch XI)
  IF v_source = 'matchday'
     AND to_regclass('public.international_matchday_squad_player') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.international_matchday_squad_player sp
       WHERE sp.nation_code = v_nation AND sp.slot_kind = 'bench'
     ) THEN
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', b.player_id,
            'name', b.name,
            'rating', b.rating,
            'role', b.role,
            'pitch_slot', NULL,
            'profile_pos', b.profile_pos,
            'on_natural', true,
            'started', false,
            'subbed_on', true,
            'is_star', b.is_star
          )
          ORDER BY b.ord
        )
        FROM (
          SELECT
            sp.player_id,
            p."Name" AS name,
            public.match_sim_player_rating_num(p."Rating"::text, 70) AS rating,
            public.match_sim_role_from_slot(NULL, p."Position") AS role,
            p."Position" AS profile_pos,
            public.match_sim_is_star(
              public.match_sim_player_rating_num(p."Rating"::text, 70)
            ) AS is_star,
            row_number() OVER (
              ORDER BY sp.sort_order NULLS LAST, p."Name"
            ) AS ord
          FROM public.international_matchday_squad_player sp
          JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
          WHERE sp.nation_code = v_nation
            AND sp.slot_kind = 'bench'
          LIMIT 5
        ) b
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  END IF;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_apply_player_stats(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_load_nation_side(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
