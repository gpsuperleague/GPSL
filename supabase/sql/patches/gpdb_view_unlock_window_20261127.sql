-- gpdb_players_view expands Players columns when it is created.
-- foreign_contract_unlock_window was added later, so GPDB's select 400s.
-- Append only. CREATE OR REPLACE can add a column at the end.

CREATE OR REPLACE VIEW public.gpdb_players_view
WITH (security_invoker = true) AS
SELECT
  p."Name",
  p."Position",
  p."Nation",
  p."Age",
  p."Rating",
  p."Potential",
  p."Calc_Potential",
  p."Playstyle",
  p."Maximum_Reserve_Price",
  p.market_value,
  p."Contracted_Team",
  p."Season_Signed",
  p."Konami_ID",
  p.contract_seasons_remaining,
  p.contract_wage,
  p.foreign_contract_club,
  p.foreign_contract_sold_season_id,
  p.foreign_contract_unlock_season_label,
  p.foreign_contract_lock_kind,
  p.pesdb_unavailable,
  p.pesdb_unavailable_since,
  p.name_search_key,
  p."Height",
  p."Stronger_Foot",
  p."Weak_Foot_Usage",
  p."Weak_Foot_Accuracy",
  COALESCE(
    NULLIF(p.contract_wage, 0::numeric),
    round(
      GREATEST(
        COALESCE(NULLIF(btrim(p.market_value), ''::text), '0'::text)::numeric,
        0::numeric
      ) * COALESCE(gs.wage_pct_championship, 4::numeric) / 100.0,
      0
    )
  ) AS effective_wage,
  NULLIF(btrim(p.market_value), ''::text)::numeric AS market_value_n,
  p.foreign_contract_unlock_window
FROM public."Players" p
LEFT JOIN public.global_settings gs ON gs.id = 1;

GRANT SELECT ON public.gpdb_players_view TO authenticated;
GRANT SELECT ON public.gpdb_players_view TO anon;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'has_window', EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpdb_players_view'
      AND column_name = 'foreign_contract_unlock_window'
  )
) AS result;
