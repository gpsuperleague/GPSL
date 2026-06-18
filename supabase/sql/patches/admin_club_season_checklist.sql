-- =============================================================================
-- Admin: club season checklist (all clubs — owner, squad, wages, fines, etc.)
-- Run once in Supabase SQL Editor. UI: admin_club_checklist.html
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_club_season_checklist()
RETURNS TABLE (
  club_short_name text,
  club_name text,
  division text,
  owner_tag text,
  owner_email text,
  manager_name text,
  manager_rating smallint,
  ooo_player_name text,
  squad_size int,
  star_count int,
  current_balance numeric,
  total_wages numeric,
  contract_releases_remaining int,
  foreign_sales_remaining int,
  fines_count int,
  u21_count int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_star_min smallint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  v_star_min := public.club_squad_star_min_rating();

  RETURN QUERY
  SELECT
    c."ShortName"::text AS club_short_name,
    c."Club"::text AS club_name,
    ccs.division::text AS division,
    coalesce(
      public.owner_registry_resolve_tag(c.owner_id),
      CASE
        WHEN c.owner_id IS NOT NULL THEN split_part(u.email::text, '@', 1)
        ELSE NULL
      END
    )::text AS owner_tag,
    u.email::text AS owner_email,
    m.name::text AS manager_name,
    m.rating::smallint AS manager_rating,
    ooo_p."Name"::text AS ooo_player_name,
    (
      SELECT count(*)::int
      FROM public."Players" p
      WHERE p."Contracted_Team" = c."ShortName"
    ) AS squad_size,
    (
      SELECT count(*)::int
      FROM public."Players" p
      WHERE p."Contracted_Team" = c."ShortName"
        AND nullif(
          regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
          ''
        )::integer >= v_star_min
        AND (
          ooo_d.player_id IS NULL
          OR p."Konami_ID"::text <> ooo_d.player_id
        )
    ) AS star_count,
    coalesce(cf.balance, 0)::numeric AS current_balance,
    (
      public.competition_club_wage_bill_total(c."ShortName", v_season_id)
      + coalesce(m.weekly_wage, 0)
    )::numeric AS total_wages,
    coalesce(c.voluntary_contract_releases_remaining, 0)::int AS contract_releases_remaining,
    coalesce(c.foreign_interest_remaining, 0)::int AS foreign_sales_remaining,
    (
      SELECT count(*)::int
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = c."ShortName"
        AND l.entry_type = 'gov_fine_compensation'
        AND (v_season_id IS NULL OR l.season_id = v_season_id)
    ) AS fines_count,
    (
      SELECT count(*)::int
      FROM public."Players" p
      WHERE p."Contracted_Team" = c."ShortName"
        AND p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 21
    ) AS u21_count
  FROM public."Clubs" c
  LEFT JOIN public.competition_club_seasons ccs
    ON ccs.club_short_name = c."ShortName"
    AND ccs.season_id = v_season_id
  LEFT JOIN auth.users u ON u.id = c.owner_id
  LEFT JOIN public."Managers" m ON m.id = c.manager_id
  LEFT JOIN public."Club_Finances" cf ON cf.club_name = c."ShortName"
  LEFT JOIN LATERAL (
    SELECT d.player_id
    FROM public.club_squad_player_designations d
    WHERE d.club_short_name = c."ShortName"
      AND d.designation = 'one_of_our_own'
    LIMIT 1
  ) ooo_d ON true
  LEFT JOIN public."Players" ooo_p ON ooo_p."Konami_ID"::text = ooo_d.player_id
  WHERE c."ShortName" <> 'FOREIGN'
  ORDER BY c."Club";
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_season_checklist() TO authenticated;

NOTIFY pgrst, 'reload schema';
