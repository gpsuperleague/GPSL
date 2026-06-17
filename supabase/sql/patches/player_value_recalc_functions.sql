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
-- THIS FILE ONLY CREATES FUNCTIONS + RUNS A PREVIEW (no data is changed).
-- Apply the values with player_value_recalc_apply.sql once the preview looks right.
-- =============================================================================

-- Parse a possibly-text numeric column (e.g. "79", " 24 ") to int, else NULL.
CREATE OR REPLACE FUNCTION public.gpsl_pv_int(p_value text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(regexp_replace(coalesce(btrim(p_value), ''), '[^0-9]', '', 'g'), '')::integer;
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

-- ---------------------------------------------------------------------------
-- PREVIEW — recalculated values vs current stored values (NO WRITES).
-- ---------------------------------------------------------------------------
WITH calc AS (
  SELECT
    p."Konami_ID",
    p."Name",
    public.gpsl_pv_int(p."Rating"::text)    AS rating,
    public.gpsl_pv_int(p."Potential"::text) AS potential,
    public.gpsl_pv_int(p."Age"::text)       AS age,
    btrim(p."Position"::text)               AS position,
    nullif(btrim(p.market_value::text), '')::numeric AS current_mv,
    public.gpsl_pv_market_value(
      public.gpsl_pv_int(p."Rating"::text),
      coalesce(public.gpsl_pv_int(p."Potential"::text), public.gpsl_pv_int(p."Rating"::text)),
      public.gpsl_pv_int(p."Age"::text),
      p."Position"::text
    ) AS new_mv
  FROM public."Players" p
  WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
)
SELECT
  "Konami_ID", "Name", rating, potential, age, position,
  current_mv, new_mv, (new_mv - current_mv) AS delta
FROM calc
ORDER BY abs(coalesce(new_mv, 0) - coalesce(current_mv, 0)) DESC;
