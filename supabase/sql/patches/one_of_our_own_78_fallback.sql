-- =============================================================================
-- One of our Own — 78 fallback for nations without a 79+ free agent
-- =============================================================================
-- Nations with at least one free-agent star (Rating >= 79) still draw from 79+.
-- Nations with no 79+ free agent draw a random free agent at Rating = 78.
-- =============================================================================

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
        'eligible_count', pool.cnt
      )
      ORDER BY c."Club"
    )
    FROM public."Clubs" c
    LEFT JOIN public.club_one_of_our_own_draws d ON d.club_short_name = c."ShortName"
    LEFT JOIN public."Players" dp ON dp."Konami_ID"::text = d.player_id
    CROSS JOIN LATERAL (
      SELECT EXISTS (
        SELECT 1
        FROM public."Players" p
        WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
          AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
          AND public.normalize_nation_key(p."Nation") <> ''
          AND btrim(p."Rating"::text) <> ''
          AND btrim(p."Rating"::text)::numeric >= 79
      ) AS has_star
    ) star
    CROSS JOIN LATERAL (
      SELECT
        CASE WHEN star.has_star THEN '79+' ELSE '78' END AS band,
        (
          SELECT count(*)::int
          FROM public."Players" p
          WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
            AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
            AND public.normalize_nation_key(p."Nation") <> ''
            AND btrim(p."Rating"::text) <> ''
            AND (
              CASE
                WHEN star.has_star THEN btrim(p."Rating"::text)::numeric >= 79
                ELSE btrim(p."Rating"::text)::numeric = 78
              END
            )
        ) AS cnt
    ) pool
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
  v_fee numeric;
  v_history_id bigint;
  v_results jsonb := '[]'::jsonb;
  v_drawn int := 0;
  v_has_star boolean;
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

    SELECT EXISTS (
      SELECT 1
      FROM public."Players" p
      WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
        AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_nation)
        AND public.normalize_nation_key(p."Nation") <> ''
        AND btrim(p."Rating"::text) <> ''
        AND btrim(p."Rating"::text)::numeric >= 79
    )
    INTO v_has_star;

    v_band := CASE WHEN v_has_star THEN '79+' ELSE '78' END;

    -- Star nations: random FA Rating >= 79. Non-star nations: random FA Rating = 78.
    SELECT
      p."Konami_ID"::text,
      p."Name",
      round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0))
    INTO v_player_id, v_player_name, v_fee
    FROM public."Players" p
    WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
      AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_nation)
      AND public.normalize_nation_key(p."Nation") <> ''
      AND btrim(p."Rating"::text) <> ''
      AND (
        CASE
          WHEN v_has_star THEN btrim(p."Rating"::text)::numeric >= 79
          ELSE btrim(p."Rating"::text)::numeric = 78
        END
      )
    ORDER BY random()
    LIMIT 1;

    IF NOT FOUND THEN
      v_results := v_results || jsonb_build_object(
        'club', v_club,
        'status', 'no_eligible_player',
        'nation', v_nation,
        'eligible_band', v_band
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

GRANT EXECUTE ON FUNCTION public.competition_admin_one_of_our_own_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_draw_one_of_our_own(text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
