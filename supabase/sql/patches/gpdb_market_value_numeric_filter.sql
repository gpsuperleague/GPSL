-- =============================================================================
-- GPDB: numeric market_value for range filters
--
-- Players.market_value is often text (or filtered as text). PostgREST
-- .gte()/.lte() then compare lexicographically, so e.g. "39975000" passes
-- lte "4000000" ('3' < '4') while "900000" can fail ('9' > '4').
--
-- Adds market_value_n on gpdb_players_view for correct numeric MV filters.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE VIEW public.gpdb_players_view
WITH (security_invoker = true) AS
SELECT
  p.*,
  nullif(btrim(p.market_value::text), '')::numeric AS market_value_n,
  COALESCE(
    NULLIF(p.contract_wage, 0),
    round(
      greatest(
        coalesce(nullif(btrim(p.market_value::text), ''), '0')::numeric,
        0
      ) * coalesce(gs.wage_pct_championship, 4::numeric) / 100.0,
      0
    )
  ) AS effective_wage
FROM public."Players" p
LEFT JOIN public.global_settings gs ON gs.id = 1;

GRANT SELECT ON public.gpdb_players_view TO authenticated;
GRANT SELECT ON public.gpdb_players_view TO anon;

NOTIFY pgrst, 'reload schema';
