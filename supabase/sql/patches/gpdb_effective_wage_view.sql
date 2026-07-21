-- GPDB: effective (per-season) wage for filters — actual contract wage or forecast from MV.
-- Self-contained: does not require calculate_standard_player_wage() (inline Championship %).

CREATE OR REPLACE VIEW public.gpdb_players_view
WITH (security_invoker = true) AS
SELECT
  p.*,
  COALESCE(
    NULLIF(p.contract_wage, 0),
    round(
      greatest(
        coalesce(nullif(btrim(p.market_value::text), ''), '0')::numeric,
        0
      ) * coalesce(gs.wage_pct_championship, 4::numeric) / 100.0,
      0
    )
  ) AS effective_wage,
  nullif(btrim(p.market_value::text), '')::numeric AS market_value_n
FROM public."Players" p
LEFT JOIN public.global_settings gs ON gs.id = 1;

GRANT SELECT ON public.gpdb_players_view TO authenticated;
GRANT SELECT ON public.gpdb_players_view TO anon;
