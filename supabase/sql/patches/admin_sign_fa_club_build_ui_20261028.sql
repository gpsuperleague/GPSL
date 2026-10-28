-- =============================================================================
-- Admin sign free agents: club build context + nation-filtered search
-- UI: admin_sign_players.html
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_sign_fa_club_build_context(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_nation text;
  v_nation_key text := '';
  v_balance numeric := 0;
  v_tax_pct numeric := 0;
  v_star_min int := 79;
  v_star_cap int := 2;
  v_manager jsonb;
  v_players jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  SELECT c."Nation" INTO v_nation
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  BEGIN
    v_nation_key := public.normalize_nation_key(v_nation);
  EXCEPTION WHEN OTHERS THEN
    v_nation_key := lower(btrim(coalesce(v_nation, '')));
  END;

  SELECT coalesce(f.balance, 0) INTO v_balance
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club
  LIMIT 1;

  BEGIN
    SELECT coalesce(g.gov_income_tax_pct, 0) INTO v_tax_pct
    FROM public.global_settings g
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_tax_pct := 0;
  END;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_star_min := public.club_squad_star_min_rating();
  END IF;
  IF to_regprocedure('public.club_squad_star_cap(text)') IS NOT NULL THEN
    v_star_cap := public.club_squad_star_cap(v_club);
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY
           CASE
             WHEN r.position IN ('GK') THEN 1
             WHEN r.position IN ('LB', 'CB', 'RB') THEN 2
             WHEN r.position IN ('DMF', 'LMF', 'CMF', 'RMF', 'AMF') THEN 3
             ELSE 4
           END,
           r.market_value DESC NULLS LAST,
           r.player_name
         ), '[]'::jsonb)
  INTO v_players
  FROM (
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Nation" AS nation,
      p."Rating" AS rating,
      CASE
        WHEN p."Age" IS NULL OR btrim(p."Age"::text) = '' THEN NULL
        ELSE round(btrim(p."Age"::text)::numeric)::int
      END AS age,
      coalesce(
        nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
        0
      ) AS market_value,
      (
        public.normalize_nation_key(p."Nation") = v_nation_key
        AND v_nation_key <> ''
      ) AS is_home_grown,
      (
        p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 21
      ) AS is_u21,
      coalesce(
        nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), ''),
        '0'
      )::int >= v_star_min AS is_star,
      upper(btrim(coalesce(p."Position", ''))) = 'GK' AS is_gk
    FROM public."Players" p
    WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
  ) r;

  SELECT to_jsonb(m) INTO v_manager
  FROM (
    SELECT
      mgr.id AS manager_id,
      mgr.name AS manager_name,
      mgr.rating AS manager_rating,
      mgr.market_value AS manager_market_value
    FROM public."Managers" mgr
    WHERE upper(nullif(btrim(mgr.contracted_club::text), '')) = v_club
    ORDER BY mgr.id
    LIMIT 1
  ) m;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'club_nation', v_nation,
    'club_nation_key', v_nation_key,
    'balance', v_balance,
    'income_tax_pct', v_tax_pct,
    'star_min_rating', v_star_min,
    'star_cap', v_star_cap,
    'min_home_grown', 8,
    'min_under_21', 5,
    'min_squad_size', 24,
    'max_squad_size', 28,
    'target_squad_size', 24,
    'min_goalkeepers', 1,
    'manager', v_manager,
    'players', v_players,
    'fa_nations', coalesce((
      SELECT jsonb_agg(n ORDER BY n)
      FROM (
        SELECT DISTINCT nullif(btrim(p."Nation"::text), '') AS n
        FROM public."Players" p
        WHERE nullif(btrim(p."Contracted_Team"::text), '') IS NULL
          AND coalesce(p.pesdb_unavailable, false) = false
          AND nullif(btrim(p."Nation"::text), '') IS NOT NULL
        ORDER BY 1
        LIMIT 300
      ) x
      WHERE n IS NOT NULL
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_sign_fa_club_build_context(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_sign_fa_club_build_context(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_search_free_agents_for_sign(
  p_query text DEFAULT NULL,
  p_limit int DEFAULT 30,
  p_nation text DEFAULT NULL,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_raw text := btrim(coalesce(p_query, ''));
  v_q text := lower(v_raw);
  v_norm text := NULL;
  v_nation text := nullif(btrim(coalesce(p_nation, '')), '');
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_nation_key text := '';
  v_star_min int := 79;
  v_lim int := greatest(1, least(coalesce(p_limit, 30), 80));
  v_has_norm boolean := to_regprocedure('public.gpdb_normalize_search_text(text)') IS NOT NULL;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF length(v_q) < 2 AND v_nation IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  IF length(v_q) >= 2 AND v_has_norm THEN
    v_norm := public.gpdb_normalize_search_text(v_raw);
  END IF;

  IF v_club <> '' THEN
    BEGIN
      SELECT public.normalize_nation_key(c."Nation") INTO v_nation_key
      FROM public."Clubs" c
      WHERE upper(c."ShortName") = v_club
      LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
      v_nation_key := '';
    END;
  END IF;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_star_min := public.club_squad_star_min_rating();
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(r) ORDER BY r.rating DESC NULLS LAST, r.player_name)
    FROM (
      SELECT
        p."Konami_ID"::text AS player_id,
        p."Name" AS player_name,
        p."Position" AS position,
        p."Rating" AS rating,
        p."Nation" AS nation,
        CASE
          WHEN p."Age" IS NULL OR btrim(p."Age"::text) = '' THEN NULL
          ELSE round(btrim(p."Age"::text)::numeric)::int
        END AS age,
        coalesce(
          nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
          0
        ) AS market_value,
        coalesce(p.pesdb_unavailable, false) AS legacy,
        (
          v_nation_key <> ''
          AND public.normalize_nation_key(p."Nation") = v_nation_key
        ) AS is_home_grown,
        (
          p."Age" IS NOT NULL
          AND btrim(p."Age"::text) <> ''
          AND btrim(p."Age"::text)::numeric <= 21
        ) AS is_u21,
        coalesce(
          nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), ''),
          '0'
        )::int >= v_star_min AS is_star,
        upper(btrim(coalesce(p."Position", ''))) = 'GK' AS is_gk
      FROM public."Players" p
      WHERE nullif(btrim(p."Contracted_Team"::text), '') IS NULL
        AND coalesce(p.pesdb_unavailable, false) = false
        AND (
          v_nation IS NULL
          OR p."Nation" ILIKE v_nation
          OR (
            v_has_norm
            AND public.normalize_nation_key(p."Nation")
              = public.normalize_nation_key(v_nation)
          )
        )
        AND (
          length(v_q) < 2
          OR p."Konami_ID"::text = v_raw
          OR (
            v_norm IS NOT NULL
            AND v_norm <> ''
            AND (
              coalesce(p.name_search_key, public.gpdb_normalize_search_text(p."Name"))
                LIKE '%' || v_norm || '%'
            )
          )
          OR (
            v_norm IS NULL
            AND lower(p."Name") LIKE '%' || v_q || '%'
          )
        )
        AND (
          to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NULL
          OR NOT public.gpdb_player_is_season_excluded(p."Konami_ID"::text)
        )
      ORDER BY p."Rating" DESC NULLS LAST, p."Name"
      LIMIT v_lim
    ) r
  ), '[]'::jsonb);
END;
$function$;

-- Drop 2-arg overload so PostgREST resolves a single signature
DROP FUNCTION IF EXISTS public.admin_search_free_agents_for_sign(text, int);

REVOKE ALL ON FUNCTION public.admin_search_free_agents_for_sign(text, int, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_search_free_agents_for_sign(text, int, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.admin_sign_fa_club_build_context(text)') IS NOT NULL AS context_rpc,
  to_regprocedure('public.admin_search_free_agents_for_sign(text,int,text,text)') IS NOT NULL AS search4_rpc;
