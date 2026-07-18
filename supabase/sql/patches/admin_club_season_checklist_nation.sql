-- =============================================================================
-- Club season checklist: add active nation (issue in UI if owned club has none).
-- Run after admin_club_season_checklist.sql + competition_international.sql.
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.admin_club_season_checklist();

CREATE OR REPLACE FUNCTION public.admin_club_season_checklist()
RETURNS TABLE (
  club_short_name text,
  club_name text,
  division text,
  owner_tag text,
  owner_email text,
  manager_name text,
  manager_rating smallint,
  nation_code text,
  nation_name text,
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
  v_star_min smallint := 70;
  v_has_designations boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_star_min := public.club_squad_star_min_rating();
  ELSE
    SELECT coalesce(gs.star_tax_min_rating, 70)
    INTO v_star_min
    FROM public.global_settings gs
    WHERE gs.id = 1;
  END IF;

  v_has_designations := to_regclass('public.club_squad_player_designations') IS NOT NULL;

  IF v_has_designations THEN
    RETURN QUERY
    SELECT
      c."ShortName"::text,
      c."Club"::text,
      ccs.division::text,
      coalesce(
        public.owner_registry_resolve_tag(c.owner_id),
        CASE
          WHEN c.owner_id IS NOT NULL THEN split_part(u.email::text, '@', 1)
          ELSE NULL
        END
      )::text,
      u.email::text,
      m.name::text,
      m.rating::smallint,
      ion.nation_code::text,
      coalesce(n.name, ion.nation_code)::text,
      ooo_p."Name"::text,
      (
        SELECT count(*)::int
        FROM public."Players" p
        WHERE p."Contracted_Team" = c."ShortName"
      ),
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
      ),
      coalesce(cf.balance, 0)::numeric,
      (
        CASE
          WHEN to_regprocedure('public.competition_club_wage_bill_total(text, bigint)') IS NOT NULL
            THEN public.competition_club_wage_bill_total(c."ShortName", v_season_id)
          ELSE 0
        END + coalesce(m.weekly_wage, 0)
      )::numeric,
      coalesce(c.voluntary_contract_releases_remaining, 0)::int,
      coalesce(c.foreign_interest_remaining, 0)::int,
      (
        SELECT count(*)::int
        FROM public.competition_finance_ledger l
        WHERE l.club_short_name = c."ShortName"
          AND l.entry_type = 'gov_fine_compensation'
          AND (v_season_id IS NULL OR l.season_id = v_season_id)
      ),
      (
        SELECT count(*)::int
        FROM public."Players" p
        WHERE p."Contracted_Team" = c."ShortName"
          AND p."Age" IS NOT NULL
          AND btrim(p."Age"::text) <> ''
          AND btrim(p."Age"::text)::numeric <= 21
      )
    FROM public."Clubs" c
    LEFT JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = c."ShortName"
      AND ccs.season_id = v_season_id
    LEFT JOIN auth.users u ON u.id = c.owner_id
    LEFT JOIN public."Managers" m ON m.id = c.manager_id
    LEFT JOIN public."Club_Finances" cf ON cf.club_name = c."ShortName"
    LEFT JOIN public.international_owner_nations ion
      ON ion.club_short_name = c."ShortName"
      AND ion.is_active = true
    LEFT JOIN public.international_nations n ON n.code = ion.nation_code
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
  ELSE
    RETURN QUERY
    SELECT
      c."ShortName"::text,
      c."Club"::text,
      ccs.division::text,
      coalesce(
        public.owner_registry_resolve_tag(c.owner_id),
        CASE
          WHEN c.owner_id IS NOT NULL THEN split_part(u.email::text, '@', 1)
          ELSE NULL
        END
      )::text,
      u.email::text,
      m.name::text,
      m.rating::smallint,
      ion.nation_code::text,
      coalesce(n.name, ion.nation_code)::text,
      NULL::text,
      (
        SELECT count(*)::int
        FROM public."Players" p
        WHERE p."Contracted_Team" = c."ShortName"
      ),
      (
        SELECT count(*)::int
        FROM public."Players" p
        WHERE p."Contracted_Team" = c."ShortName"
          AND nullif(
            regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
            ''
          )::integer >= v_star_min
      ),
      coalesce(cf.balance, 0)::numeric,
      (
        CASE
          WHEN to_regprocedure('public.competition_club_wage_bill_total(text, bigint)') IS NOT NULL
            THEN public.competition_club_wage_bill_total(c."ShortName", v_season_id)
          ELSE 0
        END + coalesce(m.weekly_wage, 0)
      )::numeric,
      coalesce(c.voluntary_contract_releases_remaining, 0)::int,
      coalesce(c.foreign_interest_remaining, 0)::int,
      (
        SELECT count(*)::int
        FROM public.competition_finance_ledger l
        WHERE l.club_short_name = c."ShortName"
          AND l.entry_type = 'gov_fine_compensation'
          AND (v_season_id IS NULL OR l.season_id = v_season_id)
      ),
      (
        SELECT count(*)::int
        FROM public."Players" p
        WHERE p."Contracted_Team" = c."ShortName"
          AND p."Age" IS NOT NULL
          AND btrim(p."Age"::text) <> ''
          AND btrim(p."Age"::text)::numeric <= 21
      )
    FROM public."Clubs" c
    LEFT JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = c."ShortName"
      AND ccs.season_id = v_season_id
    LEFT JOIN auth.users u ON u.id = c.owner_id
    LEFT JOIN public."Managers" m ON m.id = c.manager_id
    LEFT JOIN public."Club_Finances" cf ON cf.club_name = c."ShortName"
    LEFT JOIN public.international_owner_nations ion
      ON ion.club_short_name = c."ShortName"
      AND ion.is_active = true
    LEFT JOIN public.international_nations n ON n.code = ion.nation_code
    WHERE c."ShortName" <> 'FOREIGN'
    ORDER BY c."Club";
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_season_checklist() TO authenticated;

NOTIFY pgrst, 'reload schema';
