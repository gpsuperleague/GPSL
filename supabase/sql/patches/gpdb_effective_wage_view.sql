-- GPDB: effective (per-season) wage for filters — actual contract wage or forecast from MV.
-- Forecast uses Championship % (same baseline as GPDB free-agent filter in gpdb_v2.js).

CREATE OR REPLACE VIEW public.gpdb_players_view
WITH (security_invoker = true) AS
SELECT
  p.*,
  COALESCE(
    NULLIF(p.contract_wage, 0),
    public.calculate_standard_player_wage(p.market_value, 'championship'::text)
  ) AS effective_wage
FROM public."Players" p;

GRANT SELECT ON public.gpdb_players_view TO authenticated;
GRANT SELECT ON public.gpdb_players_view TO anon;
