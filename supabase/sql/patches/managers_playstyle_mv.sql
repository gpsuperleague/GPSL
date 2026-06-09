-- =============================================================================
-- Manager MV — sum of playstyle tier values; wages = 50% of MV per year (÷52 weekly)
-- Run after managers_system.sql. Safe to re-run (recalculates all manager MV + wages).
-- =============================================================================

ALTER TABLE public.global_settings
  ALTER COLUMN manager_wage_pct SET DEFAULT 50.000;

UPDATE public.global_settings
SET manager_wage_pct = 50.000
WHERE id = 1
  AND manager_wage_pct IS DISTINCT FROM 50.000;

CREATE OR REPLACE FUNCTION public.manager_playstyle_tier_value(p_rating smallint)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_rating, 0) <= 60 THEN 0::bigint
    WHEN p_rating <= 65 THEN 1000000::bigint
    WHEN p_rating <= 70 THEN 2000000::bigint
    WHEN p_rating <= 73 THEN 5000000::bigint
    WHEN p_rating <= 76 THEN 8000000::bigint
    WHEN p_rating <= 79 THEN 16000000::bigint
    WHEN p_rating <= 83 THEN 25000000::bigint
    WHEN p_rating <= 85 THEN 40000000::bigint
    WHEN p_rating <= 90 THEN 60000000::bigint
    ELSE 60000000::bigint
  END;
$$;

CREATE OR REPLACE FUNCTION public.manager_market_value_from_playstyles(
  p_possession smallint,
  p_quick_counter smallint,
  p_long_ball_counter smallint,
  p_out_wide smallint,
  p_long_ball smallint
)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    public.manager_playstyle_tier_value(p_possession)
    + public.manager_playstyle_tier_value(p_quick_counter)
    + public.manager_playstyle_tier_value(p_long_ball_counter)
    + public.manager_playstyle_tier_value(p_out_wide)
    + public.manager_playstyle_tier_value(p_long_ball);
$$;

CREATE OR REPLACE FUNCTION public.manager_weekly_wage_for(p_market_value bigint)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
  SELECT greatest(
    0,
    round(
      coalesce(p_market_value, 0)::numeric
      * coalesce(
          (SELECT manager_wage_pct FROM public.global_settings WHERE id = 1 LIMIT 1),
          50.0
        )
      / 100.0
      / 52.0
    )::bigint
  );
$$;

COMMENT ON FUNCTION public.manager_market_value_from_playstyles IS
  'MV tiers per playstyle: 0–60 ₿0; 61–65 ₿1m; 66–70 ₿2m; 71–73 ₿5m; 74–76 ₿8m; 77–79 ₿16m; 80–83 ₿25m; 84–85 ₿40m; 86–90 ₿60m.';

-- Recalculate catalog MV from playstyle columns
UPDATE public."Managers" m
SET
  market_value = public.manager_market_value_from_playstyles(
    m.possession,
    m.quick_counter,
    m.long_ball_counter,
    m.out_wide,
    m.long_ball
  ),
  rating = greatest(
    m.possession,
    m.quick_counter,
    m.long_ball_counter,
    m.out_wide,
    m.long_ball
  ),
  weekly_wage = public.manager_weekly_wage_for(
    public.manager_market_value_from_playstyles(
      m.possession,
      m.quick_counter,
      m.long_ball_counter,
      m.out_wide,
      m.long_ball
    )
  ),
  updated_at = now();
