-- =============================================================================
-- Player base-value table update (Aug 2026 league sheet)
-- =============================================================================
-- Replaces gpsl_pv_base_value with the new Rating → base matrix.
-- Rating < 60 → 0; 60–92 as listed; >92 clamps to 92.
-- Age / potential / position / young-star % tables are unchanged.
--
-- After this: re-run player_value_recalc_preview.sql (optional), then
-- player_value_recalc_apply.sql (or apply_one) to rewrite market_value /
-- Maximum_Reserve_Price / Calc_Potential on Players.
-- Also redeploy/refresh frontend so data/player_value_tables.json is live.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_pv_base_value(p_rating integer)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_rating IS NULL OR p_rating < 60 THEN 0
    ELSE (
      SELECT v FROM (VALUES
        (60,100000),(61,250000),(62,500000),(63,750000),(64,1000000),
        (65,1500000),(66,2000000),(67,3000000),(68,4000000),(69,5000000),
        (70,6000000),(71,8000000),(72,10000000),(73,12000000),(74,14000000),
        (75,16000000),(76,18000000),(77,20000000),(78,25000000),(79,30000000),
        (80,40000000),(81,50000000),(82,60000000),(83,75000000),(84,85000000),
        (85,90000000),(86,95000000),(87,100000000),(88,110000000),(89,120000000),
        (90,130000000),(91,140000000),(92,150000000)
      ) t(k, v)
      WHERE k = LEAST(92, p_rating)
    )
  END;
$$;

COMMENT ON FUNCTION public.gpsl_pv_base_value(integer) IS
  'Player MV base by Rating (league sheet Aug 2026). <60=0; 60-92 table; >92=92.';
