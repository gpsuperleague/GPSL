-- =============================================================================
-- Player market value: remove the Calc Potential cliff + recalc everyone
-- =============================================================================
-- Before: rating = PES max -> rating + tier bonus (+2 if <=19); otherwise the
-- PES max itself. A 77 rated player with a 79 max scored 79 (-75%) while a
-- maxed 77 / 77 scored 89 (+7.5%) — e.g. Gnabry (30, 77) valued at ₿7M.
-- After: greatest(PES max, rating + tier bonus + young bonus). Players with a
-- high ceiling are unchanged; nobody is worth less for having headroom.
--
-- Market value, Maximum Reserve Price (1.5 x MV) and the stored Calc Potential
-- are recalculated for every player (intl / Next Gen boosts kept).
-- Wages follow market value, so affected players' wages rise too.
--
-- Preview first: player_value_potential_cliff_preview_20261008.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_pv_calc_potential(
  p_rating integer, p_pes_max integer, p_age integer
)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_rating IS NULL OR p_pes_max IS NULL THEN coalesce(p_pes_max, p_rating)
    ELSE greatest(
      p_pes_max,
      p_rating + public.gpsl_pv_rating_bonus(p_rating)
        + CASE WHEN coalesce(p_age, 99) <= 19 THEN 2 ELSE 0 END
    )
  END;
$$;

SELECT public.gpsl_player_value_recalc_apply() AS recalc;

-- Check: Gnabry and the old smoke test (79 CB age 24, maxed -> unchanged)
SELECT
  p."Name", p."Rating", p."Potential", p."Age", p."Position",
  p."Calc_Potential", p.market_value, p."Maximum_Reserve_Price",
  public.gpsl_pv_market_value(79, 79, 24, 'CB') AS smoke_test_should_be_42412500
FROM public."Players" p
WHERE p."Name" ILIKE '%gnabry%';
