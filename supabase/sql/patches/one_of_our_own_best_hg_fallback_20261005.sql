-- =============================================================================
-- One of our Own draw — third band: "best HG"
-- =============================================================================
-- Bands (free agents whose Nation matches the club):
--   1) 79+     nation has a free-agent star  → random FA rated >= 79
--   2) 78      no star, but 78s exist         → random FA rated 78
--   3) best HG neither of the above           → highest-rated HG free agent;
--              ties → youngest; then highest market value (deterministic)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.ooo_player_rating_num(p_rating text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(regexp_replace(coalesce(btrim(p_rating), ''), '[^0-9.]', '', 'g'), '')::numeric;
$$;

CREATE OR REPLACE FUNCTION public.ooo_player_age_num(p_age text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(regexp_replace(coalesce(btrim(p_age), ''), '[^0-9]', '', 'g'), '')::integer;
$$;

-- Band + pool size for one nation
CREATE OR REPLACE FUNCTION public.ooo_nation_band(p_nation text)
RETURNS TABLE (band text, cnt integer, best_rating numeric)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH fa AS (
    SELECT public.ooo_player_rating_num(p."Rating"::text) AS r
    FROM public."Players" p
    WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
      AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(p_nation)
      AND public.normalize_nation_key(p."Nation") <> ''
  ),
  s AS (
    SELECT
      count(*) FILTER (WHERE r >= 79)::int AS n79,
      count(*) FILTER (WHERE r = 78)::int AS n78,
      count(*) FILTER (WHERE r IS NOT NULL)::int AS nall,
      max(r) AS top
    FROM fa
  )
  SELECT
    CASE
      WHEN s.n79 > 0 THEN '79+'
      WHEN s.n78 > 0 THEN '78'
      ELSE 'best HG'
    END,
    CASE
      WHEN s.n79 > 0 THEN s.n79
      WHEN s.n78 > 0 THEN s.n78
      ELSE s.nall
    END,
    s.top
  FROM s;
$$;

CREATE OR REPLACE FUNCTION public.competition_admin_one_of_our_own_overview()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'short_name', c."ShortName",
        'club', c."Club",
        'nation', c."Nation",
        'already_drawn', (d.id IS NOT NULL),
        'drawn_player_id', d.player_id,
        'drawn_player_name', dp."Name",
        'drawn_fee', d.fee,
        'eligible_band', pool.band,
        'eligible_count', pool.cnt,
        'best_rating', pool.best_rating
      )
      ORDER BY c."Club"
    )
    FROM public."Clubs" c
    LEFT JOIN public.club_one_of_our_own_draws d ON d.club_short_name = c."ShortName"
    LEFT JOIN public."Players" dp ON dp."Konami_ID"::text = d.player_id
    CROSS JOIN LATERAL public.ooo_nation_band(c."Nation") pool
    WHERE c."ShortName" <> 'FOREIGN'
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_draw_one_of_our_own(
  p_club_short_names text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_club text;
  v_nation text;
  v_player_id text;
  v_player_name text;
  v_player_rating numeric;
  v_fee numeric;
  v_history_id bigint;
  v_results jsonb := '[]'::jsonb;
  v_drawn int := 0;
  v_band text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_club_short_names IS NULL OR array_length(p_club_short_names, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one club';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season — start a season before drawing';
  END IF;

  FOREACH v_club IN ARRAY p_club_short_names
  LOOP
    v_club := btrim(v_club);
    CONTINUE WHEN v_club = '';

    IF EXISTS (
      SELECT 1 FROM public.club_one_of_our_own_draws d
      WHERE d.club_short_name = v_club
    ) THEN
      v_results := v_results || jsonb_build_object('club', v_club, 'status', 'skipped_already');
      CONTINUE;
    END IF;

    SELECT c."Nation" INTO v_nation
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;

    IF NOT FOUND THEN
      v_results := v_results || jsonb_build_object('club', v_club, 'status', 'club_not_found');
      CONTINUE;
    END IF;

    SELECT b.band INTO v_band FROM public.ooo_nation_band(v_nation) b;
    v_player_id := NULL;

    SELECT
      p."Konami_ID"::text,
      p."Name",
      public.ooo_player_rating_num(p."Rating"::text),
      round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0))
    INTO v_player_id, v_player_name, v_player_rating, v_fee
    FROM public."Players" p
    WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
      AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_nation)
      AND public.normalize_nation_key(p."Nation") <> ''
      AND public.ooo_player_rating_num(p."Rating"::text) IS NOT NULL
      AND (
        CASE v_band
          WHEN '79+' THEN public.ooo_player_rating_num(p."Rating"::text) >= 79
          WHEN '78' THEN public.ooo_player_rating_num(p."Rating"::text) = 78
          ELSE true
        END
      )
    ORDER BY
      CASE WHEN v_band = 'best HG' THEN public.ooo_player_rating_num(p."Rating"::text) END DESC NULLS LAST,
      CASE WHEN v_band = 'best HG' THEN public.ooo_player_age_num(p."Age"::text) END ASC NULLS LAST,
      CASE WHEN v_band = 'best HG'
        THEN coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0)
      END DESC NULLS LAST,
      random()
    LIMIT 1;

    IF v_player_id IS NULL THEN
      v_results := v_results || jsonb_build_object(
        'club', v_club,
        'status', 'no_eligible_player',
        'nation', v_nation,
        'eligible_band', 'none'
      );
      CONTINUE;
    END IF;

    BEGIN
      PERFORM public.player_assign_to_club(v_player_id, v_club, NULL::numeric, false);

      INSERT INTO public."Transfer_History" (
        player_id, seller_club_id, buyer_club_id, fee, agent_fee, transfer_time, listing_id
      )
      VALUES (
        v_player_id, NULL, v_club, v_fee, 0, now(), NULL
      )
      RETURNING id INTO v_history_id;

      PERFORM public.post_club_ledger(
        v_club,
        'transfer_purchase',
        -v_fee,
        'One of our Own draw: ' || coalesce(v_player_name, v_player_id),
        jsonb_build_object(
          'transfer_history_id', v_history_id,
          'player_id', v_player_id,
          'one_of_our_own', true,
          'eligible_band', v_band
        ),
        v_season_id,
        NULL,
        true,
        true
      );

      INSERT INTO public.club_one_of_our_own_draws (
        club_short_name, player_id, fee, season_id, transfer_history_id
      )
      VALUES (
        v_club, v_player_id, v_fee, v_season_id, v_history_id
      );

      v_drawn := v_drawn + 1;
      v_results := v_results || jsonb_build_object(
        'club', v_club,
        'status', 'drawn',
        'player_id', v_player_id,
        'player_name', v_player_name,
        'rating', v_player_rating,
        'fee', v_fee,
        'nation', v_nation,
        'eligible_band', v_band
      );
    EXCEPTION WHEN OTHERS THEN
      v_results := v_results || jsonb_build_object(
        'club', v_club, 'status', 'error', 'message', SQLERRM
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'drawn', v_drawn,
    'results', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.ooo_nation_band(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_one_of_our_own_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_draw_one_of_our_own(text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
