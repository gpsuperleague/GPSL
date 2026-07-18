-- =============================================================================
-- Impact chart: no +3 band for manager proficiency 73–83 (min/max = 0).
-- +3 starts at proficiency 84. Safe to re-run.
-- =============================================================================

UPDATE public.manager_proficiency_expectancy
SET
  boost3_min = 0,
  boost3_max = 0,
  updated_at = now()
WHERE proficiency BETWEEN 73 AND 83;
