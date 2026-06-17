-- =============================================================================
-- Recalculate player market values — SQL port of player_value_calcs.js
-- =============================================================================
-- Mirrors the JS exactly (data/player_value_tables.json):
--   * base value by Rating (60-93; clamp below 60 / above 93)
--   * Calc Potential (G): if Rating = Pes Max -> Pes Max + tier bonus + (age<=19?2:0)
--   * Market Value (J): base + base*potential% + base*age% + base*youngStar%
--                       + base*position%, floored ₿5M (<30) / ₿2M (>=30)
--   * Maximum reserve = 1.5 x market value
--
-- Pes Max source: Players."Potential" (falls back to Rating when missing — same
-- as the JS scrape fallback max_level_rating ?? potential ?? rating).
--
-- THIS FILE: installs functions only (fast — safe for Supabase SQL editor).
-- Preview (slow, full table scan): player_value_recalc_preview.sql
-- Apply writes: player_value_recalc_apply.sql or player_value_recalc_apply_one.sql
-- =============================================================================

-- Parse a possibly-text numeric column (e.g. "79", "24", "79.0") to int, else NULL.
CREATE OR REPLACE FUNCTION public.gpsl_pv_int(p_value text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_value IS NULL OR btrim(p_value) = '' THEN NULL
    WHEN btrim(p_value) ~ '^[0-9]+$' THEN btrim(p_value)::integer
    WHEN btrim(p_value) ~ '^[0-9]+[.][0-9]+$' THEN floor(btrim(p_value)::numeric)::integer
    ELSE nullif(regexp_replace(btrim(p_value), '[^0-9]', '', 'g'), '')::integer
  END;
$$;

-- Base value by Rating (every integer 60-93 defined; clamp outside).
CREATE OR REPLACE FUNCTION public.gpsl_pv_base_value(p_rating integer)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT v FROM (VALUES
    (60,2500000),(61,3000000),(62,3500000),(63,4000000),(64,4500000),
    (65,5000000),(66,5500000),(67,6000000),(68,6500000),(69,7500000),
    (70,10000000),(71,12500000),(72,15000000),(73,17500000),(74,20000000),
    (75,22500000),(76,25000000),(77,27500000),(78,30000000),(79,32500000),
    (80,40000000),(81,50000000),(82,60000000),(83,70000000),(84,80000000),
    (85,90000000),(86,100000000),(87,110000000),(88,115000000),(89,120000000),
    (90,130000000),(91,135000000),(92,140000000),(93,150000000)
  ) t(k, v)
  WHERE k = LEAST(93, GREATEST(60, p_rating));
$$;

-- Rating -> tier bonus (Excel LOOKUP: largest key <= rating).
CREATE OR REPLACE FUNCTION public.gpsl_pv_rating_bonus(p_rating integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT v FROM (VALUES
    (0,17),(61,18),(62,17),(63,16),(69,15),(73,14),(74,13),(76,12),(78,11),(79,11)
  ) t(k, v)
  WHERE k <= p_rating
  ORDER BY k DESC
  LIMIT 1;
$$;

-- Calc Potential (col G).
CREATE OR REPLACE FUNCTION public.gpsl_pv_calc_potential(
  p_rating integer, p_pes_max integer, p_age integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_rating IS NULL OR p_pes_max IS NULL THEN coalesce(p_pes_max, p_rating)
    WHEN p_rating = p_pes_max THEN
      p_pes_max + public.gpsl_pv_rating_bonus(p_rating)
        + CASE WHEN coalesce(p_age, 99) <= 19 THEN 2 ELSE 0 END
    ELSE p_pes_max
  END;
$$;

-- Potential % by Calc Value (keys 79-99; clamp outside).
CREATE OR REPLACE FUNCTION public.gpsl_pv_potential_pct(p_calc integer)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT v FROM (VALUES
    (79,-0.75),(80,-0.65),(81,-0.55),(82,-0.45),(83,-0.35),(84,-0.25),(85,-0.10),
    (86,0.0),(87,0.025),(88,0.05),(89,0.075),(90,0.10),(91,0.20),(92,0.35),
    (93,0.45),(94,0.48),(95,0.50),(96,0.60),(97,0.70),(98,0.78),(99,0.85)
  ) t(k, v)
  WHERE k = LEAST(99, GREATEST(79, p_calc));
$$;

-- Age % (16-50 defined; else -1 if age>=35, otherwise 0).
CREATE OR REPLACE FUNCTION public.gpsl_pv_age_pct(p_age integer)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(
    (SELECT v FROM (VALUES
      (16,0.75),(17,0.65),(18,0.45),(19,0.35),(20,0.30),(21,0.27),(22,0.24),
      (23,0.21),(24,0.18),(25,0.15),(26,0.12),(27,0.09),(28,0.06),(29,0.03),
      (30,0.0),(31,-0.05),(32,-0.10),(33,-0.15),(34,-0.20),
      (35,-1),(36,-1),(37,-1),(38,-1),(39,-1),(40,-1),(41,-1),(42,-1),(43,-1),
      (44,-1),(45,-1),(46,-1),(47,-1),(48,-1),(49,-1),(50,-1)
    ) t(k, v) WHERE k = p_age),
    CASE WHEN coalesce(p_age, 0) >= 35 THEN -1 ELSE 0 END
  );
$$;

-- Young-star % (ages 16-19 only; else 0).
CREATE OR REPLACE FUNCTION public.gpsl_pv_youngstar_pct(p_age integer)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(
    (SELECT v FROM (VALUES (16,0.5),(17,0.4),(18,0.3),(19,0.2)) t(k, v) WHERE k = p_age),
    0
  );
$$;

-- Position % (exact match on upper-cased position; else 0).
CREATE OR REPLACE FUNCTION public.gpsl_pv_position_pct(p_pos text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(
    (SELECT v FROM (VALUES
      ('GK',0.0),('CB',0.025),('RB',0.05),('LB',0.05),('DMF',0.05),
      ('CMF',0.075),('LMF',0.075),('RMF',0.075),('AMF',0.10),
      ('LWF',0.10),('RWF',0.10),('SS',0.125),('CF',0.15)
    ) t(k, v) WHERE k = upper(btrim(coalesce(p_pos, '')))),
    0
  );
$$;

-- Market Value (col J).
CREATE OR REPLACE FUNCTION public.gpsl_pv_market_value(
  p_rating integer, p_pes_max integer, p_age integer, p_position text
)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(
    CASE WHEN coalesce(p_age, 0) < 30 THEN 5000000 ELSE 2000000 END,
    round(
      base
      + base * public.gpsl_pv_potential_pct(public.gpsl_pv_calc_potential(p_rating, p_pes_max, p_age))
      + base * public.gpsl_pv_age_pct(p_age)
      + base * public.gpsl_pv_youngstar_pct(p_age)
      + base * public.gpsl_pv_position_pct(p_position)
    )
  )
  FROM (SELECT public.gpsl_pv_base_value(p_rating) AS base) s;
$$;

-- APPLY helper (optional — player_value_recalc_apply.sql uses inline UPDATE instead).
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
      public.gpsl_pv_market_value(
        public.gpsl_pv_int(p."Rating"::text),
        coalesce(
          public.gpsl_pv_int(p."Potential"::text),
          public.gpsl_pv_int(p."Rating"::text)
        ),
        public.gpsl_pv_int(p."Age"::text),
        p."Position"::text
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

NOTIFY pgrst, 'reload schema';

-- Smoke test (1 row — confirms functions installed)
SELECT public.gpsl_pv_market_value(79, 79, 24, 'CB') AS smoke_test_mv_should_be_42412500;

-- ---------------------------------------------------------------------------
-- Admin apply (SECURITY DEFINER — use if direct UPDATE returns 0 rows)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_admin_player_mv_recalc_one(p_konami_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_kid_wanted text := btrim(coalesce(p_konami_id, ''));
  v_row public."Players"%rowtype;
  v_new_mv numeric;
  v_new_calc integer;
  v_rows integer := 0;
  v_returning_mv text;
  v_returning_reserve text;
  v_returning_calc text;
BEGIN
  IF v_kid_wanted = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'konami_id required');
  END IF;

  SELECT p.* INTO v_row
  FROM public."Players" p
  WHERE btrim(p."Konami_ID"::text) = v_kid_wanted
     OR p."Konami_ID"::text = v_kid_wanted
  ORDER BY p."Konami_ID"
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'player not found',
      'konami_id_wanted', v_kid_wanted
    );
  END IF;

  v_new_mv := public.gpsl_pv_market_value(
    public.gpsl_pv_int(v_row."Rating"::text),
    coalesce(
      public.gpsl_pv_int(v_row."Potential"::text),
      public.gpsl_pv_int(v_row."Rating"::text)
    ),
    public.gpsl_pv_int(v_row."Age"::text),
    v_row."Position"::text
  );

  v_new_calc := public.gpsl_pv_calc_potential(
    public.gpsl_pv_int(v_row."Rating"::text),
    coalesce(
      public.gpsl_pv_int(v_row."Potential"::text),
      public.gpsl_pv_int(v_row."Rating"::text)
    ),
    public.gpsl_pv_int(v_row."Age"::text)
  );

  UPDATE public."Players" p
  SET
    market_value = v_new_mv,
    "Maximum_Reserve_Price" = round(v_new_mv * 1.5),
    "Calc_Potential" = v_new_calc
  WHERE p."Konami_ID" IS NOT DISTINCT FROM v_row."Konami_ID"
  RETURNING
    p.market_value::text,
    p."Maximum_Reserve_Price"::text,
    p."Calc_Potential"::text
  INTO v_returning_mv, v_returning_reserve, v_returning_calc;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', v_rows = 1,
    'konami_id_stored', v_row."Konami_ID"::text,
    'konami_id_wanted', v_kid_wanted,
    'name', v_row."Name",
    'old_mv', v_row.market_value,
    'new_mv', v_new_mv,
    'new_reserve', round(v_new_mv * 1.5),
    'new_calc_potential', v_new_calc,
    'rows_updated', v_rows,
    'returning_mv', v_returning_mv,
    'returning_reserve', v_returning_reserve,
    'returning_calc', v_returning_calc,
    'write_blocked',
      CASE
        WHEN v_rows = 1
         AND v_returning_mv IS NOT NULL
         AND v_returning_mv::numeric IS DISTINCT FROM v_new_mv
          THEN 'UPDATE ran but RETURNING mv != new_mv — check triggers/rules/views on Players'
        ELSE NULL
      END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_admin_player_mv_recalc_all()
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
      p."Konami_ID" AS kid,
      public.gpsl_pv_market_value(
        public.gpsl_pv_int(p."Rating"::text),
        coalesce(
          public.gpsl_pv_int(p."Potential"::text),
          public.gpsl_pv_int(p."Rating"::text)
        ),
        public.gpsl_pv_int(p."Age"::text),
        p."Position"::text
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
    WHERE p."Konami_ID" IS NOT DISTINCT FROM c.kid
      AND c.new_mv IS NOT NULL
      AND c.new_calc IS NOT NULL
    RETURNING p."Konami_ID"
  )
  SELECT count(*)::integer INTO v_updated FROM touched;

  RETURN jsonb_build_object(
    'ok', true,
    'eligible_players', v_eligible,
    'rows_updated', v_updated,
    'warning',
      CASE
        WHEN v_updated = 0 AND v_eligible > 0 THEN 'UPDATE matched 0 rows'
        WHEN v_updated < v_eligible THEN 'Some players skipped (NULL new_mv / new_calc)'
        ELSE NULL
      END
  );
END;
$function$;
