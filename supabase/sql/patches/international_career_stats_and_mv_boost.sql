-- =============================================================================
-- International career: clean sheets + 5% market-value boost for squad windows
--
-- 1) Add clean_sheets to international_player_career (overall, not per season)
-- 2) Track appearances_in_cycle on each call-up row
-- 3) Refresh public views used by GPDB / national team / league stats
-- 4) 5% MV boost when player has ≥4 apps in a qualifying squad window:
--      - currently in a national squad (is_active), OR
--      - was called up in the previous WC cycle (cycle_id = prior cycle)
--    = two squad windows (current + previous); boost only after 4 matches
-- 5) Recalc MV on call-up / release (and when cycle apps are recorded)
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- Prerequisite: player_value_recalc_functions.sql (gpsl_pv_*),
--               international_callup_gpdb_fix.sql (call-up RPCs).
-- After run: optionally SELECT public.gpsl_player_value_recalc_apply();
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Career: clean sheets
-- ---------------------------------------------------------------------------

ALTER TABLE public.international_player_career
  ADD COLUMN IF NOT EXISTS clean_sheets integer NOT NULL DEFAULT 0
  CHECK (clean_sheets >= 0);

COMMENT ON COLUMN public.international_player_career.clean_sheets IS
  'Lifetime international clean sheets (overall, not per season).';

-- ---------------------------------------------------------------------------
-- Call-up: apps in this WC / call-up cycle (for MV boost gate)
-- ---------------------------------------------------------------------------

ALTER TABLE public.international_squad_callups
  ADD COLUMN IF NOT EXISTS appearances_in_cycle integer NOT NULL DEFAULT 0
  CHECK (appearances_in_cycle >= 0);

ALTER TABLE public.international_squad_callups
  ADD COLUMN IF NOT EXISTS prev_cycle_id bigint
  REFERENCES public.international_wc_cycles (id);

ALTER TABLE public.international_squad_callups
  ADD COLUMN IF NOT EXISTS prev_appearances_in_cycle integer NOT NULL DEFAULT 0
  CHECK (prev_appearances_in_cycle >= 0);

COMMENT ON COLUMN public.international_squad_callups.appearances_in_cycle IS
  'International matches played during this call-up / WC cycle. MV +5% needs ≥4.';

COMMENT ON COLUMN public.international_squad_callups.prev_appearances_in_cycle IS
  'Apps from the previous call-up stint (kept when re-called into a new cycle).';

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.international_squad_public;
CREATE VIEW public.international_squad_public
WITH (security_invoker = false)
AS
SELECT
  sc.nation_code,
  n.name AS nation_name,
  n.flag_emoji,
  sc.player_id,
  p."Name" AS player_name,
  p."Position" AS player_position,
  p."Age" AS player_age,
  p."Rating" AS player_rating,
  sc.club_short_name,
  sc.called_at,
  coalesce(sc.appearances_in_cycle, 0) AS appearances_in_cycle,
  coalesce(ipc.caps, 0) AS intl_caps,
  coalesce(ipc.goals, 0) AS intl_goals,
  coalesce(ipc.assists, 0) AS intl_assists,
  coalesce(ipc.potm, 0) AS intl_potm,
  coalesce(ipc.clean_sheets, 0) AS intl_clean_sheets,
  CASE
    WHEN coalesce(ipc.rating_count, 0) > 0
      THEN round(ipc.rating_sum / ipc.rating_count, 2)
    ELSE NULL
  END AS intl_avg_rating
FROM public.international_squad_callups sc
JOIN public.international_nations n ON n.code = sc.nation_code
LEFT JOIN public."Players" p ON p."Konami_ID"::text = sc.player_id
LEFT JOIN public.international_player_career ipc ON ipc.player_id = sc.player_id
WHERE sc.is_active = true;

GRANT SELECT ON public.international_squad_public TO authenticated;

DROP VIEW IF EXISTS public.international_player_career_public;
CREATE VIEW public.international_player_career_public
WITH (security_invoker = false)
AS
SELECT
  ipc.player_id,
  p."Name" AS player_name,
  p."Nation" AS nation,
  p."Contracted_Team" AS club_short_name,
  c."Club" AS club_name,
  ipc.caps,
  ipc.goals,
  ipc.assists,
  ipc.potm,
  coalesce(ipc.clean_sheets, 0) AS clean_sheets,
  CASE
    WHEN ipc.rating_count > 0 THEN round(ipc.rating_sum / ipc.rating_count, 2)
    ELSE NULL
  END AS avg_rating,
  ipc.updated_at
FROM public.international_player_career ipc
LEFT JOIN public."Players" p ON p."Konami_ID"::text = ipc.player_id
LEFT JOIN public."Clubs" c ON c."ShortName" = p."Contracted_Team";

GRANT SELECT ON public.international_player_career_public TO authenticated;

-- ---------------------------------------------------------------------------
-- MV boost eligibility: current/previous squad window AND ≥4 cycle apps
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_pv_international_boost_min_apps()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 4;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_pv_international_boost_eligible(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH cycles AS (
    SELECT id, cycle_no,
           row_number() OVER (ORDER BY cycle_no DESC) AS rn
    FROM public.international_wc_cycles
  ),
  cur AS (
    SELECT id FROM cycles WHERE rn = 1
  ),
  prev AS (
    SELECT id FROM cycles WHERE rn = 2
  ),
  min_apps AS (
    SELECT public.gpsl_pv_international_boost_min_apps() AS n
  )
  SELECT EXISTS (
    SELECT 1
    FROM public.international_squad_callups sc
    CROSS JOIN min_apps m
    WHERE sc.player_id = btrim(p_player_id)
      AND (
        -- Current squad window: active + ≥4 apps this cycle
        (
          sc.is_active = true
          AND coalesce(sc.appearances_in_cycle, 0) >= m.n
        )
        -- Previous squad window: released/stale row still on prior cycle
        OR (
          sc.cycle_id IS NOT NULL
          AND sc.cycle_id = (SELECT id FROM prev)
          AND coalesce(sc.appearances_in_cycle, 0) >= m.n
        )
        -- Previous window preserved after re-call into a newer cycle
        OR (
          sc.prev_cycle_id IS NOT NULL
          AND sc.prev_cycle_id = (SELECT id FROM prev)
          AND coalesce(sc.prev_appearances_in_cycle, 0) >= m.n
        )
        -- Only one cycle exists: treat current cycle as the sole window
        OR (
          (SELECT id FROM prev) IS NULL
          AND sc.is_active = true
          AND coalesce(sc.appearances_in_cycle, 0) >= m.n
        )
      )
  );
$$;

COMMENT ON FUNCTION public.gpsl_pv_international_boost_eligible(text) IS
  'True when player has ≥4 apps in the current national squad or previous WC-cycle call-up (2 squad windows).';

-- Increment cycle apps on active call-up (call from intl match confirm later).
-- Recalcs MV when the player crosses the 4-app threshold.
CREATE OR REPLACE FUNCTION public.international_record_callup_appearance(p_player_id text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_apps integer;
  v_before integer;
BEGIN
  SELECT coalesce(sc.appearances_in_cycle, 0)
  INTO v_before
  FROM public.international_squad_callups sc
  WHERE sc.player_id = v_pid
    AND sc.is_active = true
  LIMIT 1;

  IF v_before IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE public.international_squad_callups sc
  SET appearances_in_cycle = coalesce(sc.appearances_in_cycle, 0) + 1
  WHERE sc.player_id = v_pid
    AND sc.is_active = true
  RETURNING sc.appearances_in_cycle INTO v_apps;

  IF v_before < public.gpsl_pv_international_boost_min_apps()
     AND v_apps >= public.gpsl_pv_international_boost_min_apps() THEN
    PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
  ELSIF v_apps >= public.gpsl_pv_international_boost_min_apps() THEN
    -- Keep MV in sync if base formula changed; cheap single-row recalc
    PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
  END IF;

  RETURN coalesce(v_apps, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_pv_apply_international_boost(
  p_base_mv numeric,
  p_player_id text
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_base_mv IS NULL THEN NULL
    WHEN public.gpsl_pv_international_boost_eligible(p_player_id)
      THEN round(p_base_mv * 1.05)
    ELSE round(p_base_mv)
  END;
$$;

-- Recalc one player's stored MV + max reserve from rating/age/pos + intl boost
CREATE OR REPLACE FUNCTION public.gpsl_pv_recalc_player_market_value(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_base numeric;
  v_mv numeric;
  v_calc integer;
BEGIN
  SELECT
    public.gpsl_pv_int(p."Rating"::text) AS rating,
    coalesce(
      public.gpsl_pv_int(p."Potential"::text),
      public.gpsl_pv_int(p."Rating"::text)
    ) AS pes_max,
    public.gpsl_pv_int(p."Age"::text) AS age,
    p."Position"::text AS position
  INTO v_row
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF v_row.rating IS NULL THEN
    RETURN;
  END IF;

  v_calc := public.gpsl_pv_calc_potential(v_row.rating, v_row.pes_max, v_row.age);
  v_base := public.gpsl_pv_market_value(
    v_row.rating,
    v_row.pes_max,
    v_row.age,
    v_row.position
  );
  v_mv := public.gpsl_pv_apply_international_boost(v_base, btrim(p_player_id));

  UPDATE public."Players" p
  SET
    "Calc_Potential" = v_calc,
    market_value = v_mv,
    "Maximum_Reserve_Price" = round(v_mv * 1.5)
  WHERE p."Konami_ID"::text = btrim(p_player_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Players trigger: include international boost
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_calc_value()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
DECLARE
  v_rating integer;
  v_pes_max integer;
  v_age integer;
  v_base numeric;
BEGIN
  v_rating := public.gpsl_pv_int(NEW."Rating"::text);
  v_pes_max := coalesce(
    public.gpsl_pv_int(NEW."Potential"::text),
    v_rating
  );
  v_age := public.gpsl_pv_int(NEW."Age"::text);

  IF v_rating IS NULL THEN
    RETURN NEW;
  END IF;

  NEW."Calc_Potential" := public.gpsl_pv_calc_potential(v_rating, v_pes_max, v_age);
  v_base := public.gpsl_pv_market_value(
    v_rating,
    v_pes_max,
    v_age,
    NEW."Position"::text
  );
  NEW."market_value" := public.gpsl_pv_apply_international_boost(
    v_base,
    NEW."Konami_ID"::text
  );

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.apply_calc_value() IS
  'BEFORE INSERT/UPDATE on Players: Calc_Potential + market_value via gpsl_pv_* with 5% international boost (≥4 apps in current/previous squad window).';

-- Bulk apply: include intl boost
CREATE OR REPLACE FUNCTION public.gpsl_player_value_recalc_apply()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_updated integer := 0;
  v_eligible integer := 0;
BEGIN
  SELECT count(*)::integer INTO v_eligible
  FROM public."Players" p
  WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL;

  WITH calc AS (
    SELECT
      p."Konami_ID"::text AS konami_id,
      public.gpsl_pv_apply_international_boost(
        public.gpsl_pv_market_value(
          public.gpsl_pv_int(p."Rating"::text),
          coalesce(
            public.gpsl_pv_int(p."Potential"::text),
            public.gpsl_pv_int(p."Rating"::text)
          ),
          public.gpsl_pv_int(p."Age"::text),
          p."Position"::text
        ),
        p."Konami_ID"::text
      ) AS new_mv,
      public.gpsl_pv_calc_potential(
        public.gpsl_pv_int(p."Rating"::text),
        coalesce(
          public.gpsl_pv_int(p."Potential"::text),
          public.gpsl_pv_int(p."Rating"::text)
        ),
        public.gpsl_pv_int(p."Age"::text)
      ) AS new_calc
    FROM public."Players" p
    WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
  ),
  touched AS (
    UPDATE public."Players" p
    SET
      market_value = c.new_mv,
      "Maximum_Reserve_Price" = round(c.new_mv * 1.5),
      "Calc_Potential" = c.new_calc
    FROM calc c
    WHERE p."Konami_ID"::text = c.konami_id
      AND c.new_mv IS NOT NULL
      AND c.new_calc IS NOT NULL
    RETURNING p."Konami_ID"::text
  )
  SELECT count(*)::integer INTO v_updated FROM touched;

  RETURN jsonb_build_object(
    'ok', true,
    'eligible_players', v_eligible,
    'rows_updated', v_updated,
    'intl_boost_pct', 0.05,
    'warning',
      CASE
        WHEN v_updated = 0 AND v_eligible > 0
          THEN 'UPDATE matched 0 rows — re-run functions file first, then apply again'
        WHEN v_updated < v_eligible
          THEN 'Some players skipped (NULL new_mv / new_calc)'
        ELSE NULL
      END
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Call-up / release: recalc MV after squad change
-- ---------------------------------------------------------------------------

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
  ) AND v_squad_count >= 23 THEN
    RAISE EXCEPTION 'National squad is full (23 players)';
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

  -- Other-nation release may drop their boost; recalc if a row was touched
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
        -- Stash prior cycle apps when moving to a new WC cycle
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
          ELSE 0  -- fresh stint in same cycle after release
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

CREATE OR REPLACE FUNCTION public.international_release_callup(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_is_gk boolean;
  v_gk_count integer;
  v_pid text := btrim(p_player_id);
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'You have not been assigned a national team';
  END IF;

  SELECT upper(btrim(coalesce(p."Position", ''))) = 'GK'
  INTO v_is_gk
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF coalesce(v_is_gk, false) THEN
    v_gk_count := public.international_nation_active_gk_count(v_nation);
    IF v_gk_count <= 2 THEN
      RAISE EXCEPTION 'National squad must keep at least 2 goalkeepers';
    END IF;
  END IF;

  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE nation_code = v_nation
    AND player_id = v_pid
    AND is_active = true;

  PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_pv_international_boost_min_apps() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pv_international_boost_eligible(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pv_apply_international_boost(numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pv_recalc_player_market_value(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_player_value_recalc_apply() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_record_callup_appearance(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_call_up_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_release_callup(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
