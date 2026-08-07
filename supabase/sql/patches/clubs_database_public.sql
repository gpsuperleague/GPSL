-- =============================================================================
-- Club Database (public browse) — GPDB/MGDB-style club catalog
-- Safe re-run.
-- =============================================================================

DROP VIEW IF EXISTS public.clubs_database_public;

CREATE VIEW public.clubs_database_public
WITH (security_invoker = false)
AS
WITH club_n AS (
  SELECT count(*)::smallint AS n
  FROM public."Clubs" c
  WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
),
squad_mv AS (
  SELECT
    nullif(btrim(p."Contracted_Team"), '') AS club_short_name,
    coalesce(
      sum(
        coalesce(
          nullif(regexp_replace(btrim(p.market_value::text), '[^0-9.\-]', '', 'g'), '')::numeric,
          0
        )
      ),
      0
    ) AS club_market_value
  FROM public."Players" p
  WHERE nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
  GROUP BY 1
),
prestige AS (
  SELECT
    p.club_short_name,
    p.prestige_rank,
    p.prestige_seed_rank
  FROM public.competition_club_prestige_public p
)
SELECT
  c."ShortName" AS club_short_name,
  c."Club" AS club_name,
  nullif(btrim(c."Nation"), '') AS nation,
  nullif(btrim(c."Stadium"), '') AS stadium_name,
  coalesce(c."Capacity", 0)::int AS stadium_capacity,
  coalesce(c.base_capacity, c."Capacity", 0)::int AS base_capacity,
  public.stadium_max_capacity(
    coalesce(c.base_capacity, c."Capacity", 0)::int
  ) AS stadium_max_capacity,
  greatest(
    public.stadium_max_capacity(
      coalesce(c.base_capacity, c."Capacity", 0)::int
    ) - coalesce(c."Capacity", 0)::int,
    0
  ) AS stadium_expansion_potential,
  pr.prestige_rank,
  public.competition_club_baseline_expected_position(
    coalesce(pr.prestige_rank, cn.n)::smallint,
    cn.n
  ) AS club_expectation,
  coalesce(sm.club_market_value, 0)::numeric AS club_market_value,
  round(coalesce(c."Capacity", 0)::numeric * 1500) AS stadium_value,
  round(coalesce(c."Capacity", 0)::numeric * 1500 * 0.125) AS stadium_maintenance_cost,
  round(coalesce(c."Capacity", 0)::numeric * 20) AS gate_money_full,
  round(coalesce(c."Capacity", 0)::numeric * 20 * 0.8) AS gate_money_80,
  nullif(btrim(c.owner), '') AS owner_tag,
  c.owner_id,
  m.name AS manager_name,
  m.rating AS manager_rating
FROM public."Clubs" c
CROSS JOIN club_n cn
LEFT JOIN prestige pr ON pr.club_short_name = c."ShortName"
LEFT JOIN squad_mv sm ON sm.club_short_name = c."ShortName"
LEFT JOIN public."Managers" m ON m.id = c.manager_id
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN';

COMMENT ON VIEW public.clubs_database_public IS
  'Browse catalog for Club Database: stadium, expectation, MV, maintenance, gate (100%/80%).';

GRANT SELECT ON public.clubs_database_public TO authenticated;
GRANT SELECT ON public.clubs_database_public TO anon;

NOTIFY pgrst, 'reload schema';
