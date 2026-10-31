-- Enrich handpick_basket_list with Age / wage for reg strip + squad ghosts.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.handpick_basket_list(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' OR NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'club', NULL,
      'handpick_intake', false,
      'player_ids', '[]'::jsonb,
      'players', '[]'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'handpick_intake', EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE upper(c."ShortName") = v_club
        AND coalesce(c.handpick_intake, false)
    ),
    'player_ids', coalesce((
      SELECT jsonb_agg(b.player_id ORDER BY b.added_at, b.player_id)
      FROM public.club_handpick_basket b
      WHERE b.club_short_name = v_club
    ), '[]'::jsonb),
    'players', coalesce((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.added_at, r.player_name)
      FROM (
        SELECT
          b.player_id,
          b.added_at,
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
          coalesce(
            nullif(regexp_replace(coalesce(p.contract_wage::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          ) AS contract_wage,
          nullif(btrim(p."Contracted_Team"::text), '') AS contracted_team
        FROM public.club_handpick_basket b
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = b.player_id
        WHERE b.club_short_name = v_club
      ) r
    ), '[]'::jsonb)
  );
END;
$function$;

-- Search: include age for live strip updates when adding from search
CREATE OR REPLACE FUNCTION public.handpick_search_free_agents(
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
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' AND NOT public.is_gpsl_admin() THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_club
      AND coalesce(c.handpick_intake, false)
  ) AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Club is not in handpick intake';
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
        coalesce(
          nullif(regexp_replace(coalesce(p.contract_wage::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
          0
        ) AS contract_wage,
        coalesce(p.pesdb_unavailable, false) AS legacy
      FROM public."Players" p
      WHERE nullif(btrim(p."Contracted_Team"::text), '') IS NULL
        AND coalesce(p.pesdb_unavailable, false) = false
        AND (
          nullif(btrim(coalesce(p_nation, '')), '') IS NULL
          OR lower(btrim(p."Nation"::text)) = lower(btrim(p_nation))
        )
        AND (
          length(btrim(coalesce(p_query, ''))) < 2
          OR lower(p."Name") LIKE '%' || lower(btrim(p_query)) || '%'
          OR p."Konami_ID"::text = btrim(p_query)
        )
        AND (
          to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NULL
          OR NOT public.gpdb_player_is_season_excluded(p."Konami_ID"::text)
        )
        AND (
          to_regprocedure('public.player_foreign_contract_locked(text)') IS NULL
          OR NOT public.player_foreign_contract_locked(p."Konami_ID"::text)
        )
      ORDER BY p."Rating" DESC NULLS LAST, p."Name"
      LIMIT greatest(1, least(coalesce(p_limit, 30), 80))
    ) r
  ), '[]'::jsonb);
END;
$function$;

-- Owner path of handpick_club_context: include nation / age / wage for reg strip
CREATE OR REPLACE FUNCTION public.handpick_club_context(p_club_short_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_my text;
  v_ctx jsonb;
  v_pending jsonb;
  v_handpick boolean := false;
  v_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    IF public.is_gpsl_admin() THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'club_required');
    END IF;
    v_my := public.my_club_shortname();
    v_club := upper(btrim(coalesce(v_my, '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed for this club';
  END IF;

  SELECT coalesce(c.handpick_intake, false), c."Club"
  INTO v_handpick, v_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF public.is_gpsl_admin()
     AND to_regprocedure('public.admin_sign_fa_club_build_context(text)') IS NOT NULL THEN
    v_ctx := public.admin_sign_fa_club_build_context(v_club);
    -- Enrich admin context players with catalogue wage when missing
    IF v_ctx ? 'players' THEN
      v_ctx := v_ctx || jsonb_build_object(
        'players', coalesce((
          SELECT jsonb_agg(to_jsonb(r) ORDER BY r.player_name)
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
              coalesce(
                nullif(regexp_replace(coalesce(p.contract_wage::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                0
              ) AS contract_wage
            FROM public."Players" p
            WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
          ) r
        ), '[]'::jsonb)
      );
    END IF;
  ELSE
    SELECT jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_nation', c."Nation",
      'balance', coalesce(f.balance, 0),
      'income_tax_pct', coalesce((SELECT g.gov_income_tax_pct FROM public.global_settings g LIMIT 1), 0),
      'manager', (
        SELECT to_jsonb(m)
        FROM (
          SELECT mgr.id AS manager_id, mgr.name AS manager_name,
                 mgr.rating AS manager_rating, mgr.market_value AS manager_market_value
          FROM public."Managers" mgr
          WHERE upper(nullif(btrim(mgr.contracted_club::text), '')) = v_club
          LIMIT 1
        ) m
      ),
      'players', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'player_name', p."Name",
          'position', p."Position",
          'nation', p."Nation",
          'rating', p."Rating",
          'age', CASE
            WHEN p."Age" IS NULL OR btrim(p."Age"::text) = '' THEN NULL
            ELSE round(btrim(p."Age"::text)::numeric)::int
          END,
          'market_value', coalesce(
            nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          ),
          'contract_wage', coalesce(
            nullif(regexp_replace(coalesce(p.contract_wage::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          )
        ) ORDER BY p."Name")
        FROM public."Players" p
        WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
      ), '[]'::jsonb),
      'min_squad_size', 24,
      'max_squad_size', 28,
      'target_squad_size', 24,
      'min_home_grown', 8,
      'min_under_21', 5,
      'min_goalkeepers', 1,
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
    )
    INTO v_ctx
    FROM public."Clubs" c
    LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = v_club
    WHERE upper(c."ShortName") = v_club;
  END IF;

  SELECT to_jsonb(s) INTO v_pending
  FROM public.club_handpick_submissions s
  WHERE s.club_short_name = v_club
    AND s.status = 'pending'
  ORDER BY s.submitted_at DESC
  LIMIT 1;

  RETURN coalesce(v_ctx, jsonb_build_object('ok', false))
    || jsonb_build_object(
      'handpick_intake', v_handpick,
      'club_name', v_name,
      'cash_reset', false,
      'pending_submission', v_pending,
      'is_admin', public.is_gpsl_admin()
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_club_context(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_club_context(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
