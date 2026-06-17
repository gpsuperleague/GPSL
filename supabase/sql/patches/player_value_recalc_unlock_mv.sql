-- =============================================================================
-- UNLOCK market_value updates on public."Players"
-- =============================================================================
-- ROOT CAUSE (confirmed): trg_player_value → apply_calc_value() overwrites
-- market_value on every INSERT/UPDATE using legacy calc_value().
--
-- FIX: run player_value_recalc_triggers.sql (replaces apply_calc_value with
-- gpsl_pv_* formulas). Do NOT drop the triggers unless you want MV unmanaged.
-- =============================================================================

-- Inspect triggers (read-only)
SELECT
  t.tgname,
  pg_get_triggerdef(t.oid, true) AS trigger_def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relname = 'Players'
  AND NOT t.tgisinternal;

