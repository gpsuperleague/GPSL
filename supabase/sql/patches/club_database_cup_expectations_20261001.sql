-- =============================================================================
-- Club Database: show each club's cup target(s) next to the league expectation,
-- split by division (Superleague / Championship) so owners can compare.
--
-- Cup targets are a backup to the league expectation, not a second target:
-- they only rescue a SLIGHT league miss (see cup_targets_manager_club_20260928.sql).
--
-- Targets come from club_prestige_cup_targets (division + tier). The expected
-- league position itself is prestige-based and the same in either division.
--
-- Run after cup_targets_manager_club_20260928.sql and
-- gpdb_season_exclusions_managers_clubs_20260815.sql. Safe re-run.
-- =============================================================================

DROP VIEW IF EXISTS public.clubs_database_public;
DROP FUNCTION IF EXISTS public.club_cup_expectation_text(text);

CREATE OR REPLACE FUNCTION public.club_cup_expectation_text(
  p_club_short_name text,
  p_divisions text[]
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tier text;
  v_text text;
BEGIN
  BEGIN
    v_tier := public.competition_club_tier(p_club_short_name);
  EXCEPTION WHEN OTHERS THEN
    v_tier := NULL;
  END;

  SELECT string_agg(x.label, ' or ' ORDER BY x.sort_order, x.id)
  INTO v_text
  FROM (
    SELECT DISTINCT ON (lbl)
      lbl AS label, t.sort_order, t.id
    FROM public.club_prestige_cup_targets t
    CROSS JOIN LATERAL (
      SELECT coalesce(nullif(btrim(t.label), ''),
                      public.competition_cup_target_label(t.cup_code, t.cup_stage)) AS lbl
    ) l
    WHERE (t.division IS NULL OR t.division = ANY (p_divisions))
      AND (t.tier IS NULL OR t.tier = v_tier)
    ORDER BY lbl, t.sort_order, t.id
  ) x;

  RETURN v_text;
END;
$function$;

COMMENT ON FUNCTION public.club_cup_expectation_text(text, text[]) IS
  'Club cup target label(s) for the given divisions — backup that only rescues a slight league miss.';

GRANT EXECUTE ON FUNCTION public.club_cup_expectation_text(text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_cup_expectation_text(text, text[]) TO anon;

CREATE VIEW public.clubs_database_public
WITH (security_invoker = false)
AS
WITH club_n AS (
  SELECT count(*)::smallint AS n
  FROM public."Clubs" c
  WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
    AND NOT public.gpdb_club_is_season_excluded(c."ShortName", NULL)
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
),
base AS (
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
    )::smallint AS club_expectation,
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
  WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
    AND NOT public.gpdb_club_is_season_excluded(c."ShortName", NULL)
)
SELECT
  b.*,
  public.competition_club_expectation_label(b.club_expectation::smallint) AS club_expectation_label,
  public.club_cup_expectation_text(b.club_short_name, ARRAY['superleague']) AS club_cup_expectation_sl,
  public.club_cup_expectation_text(b.club_short_name, ARRAY['championship_a', 'championship_b']) AS club_cup_expectation_ch
FROM base b;

COMMENT ON VIEW public.clubs_database_public IS
  'Browse catalog for Club Database: stadium, league expectation + backup cup target (Superleague / Championship), MV, maintenance, gate (100%/80%).';

GRANT SELECT ON public.clubs_database_public TO authenticated;
GRANT SELECT ON public.clubs_database_public TO anon;

NOTIFY pgrst, 'reload schema';
