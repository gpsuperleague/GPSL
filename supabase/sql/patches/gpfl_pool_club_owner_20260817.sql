-- =============================================================================
-- GPFL: show full club name + owner on player pool / squad
-- Owner is live from Clubs (so it can influence pick decisions).
-- Safe re-run. Run after gpfl_fantasy_league_20260817.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpfl_list_players(
  p_position_group text DEFAULT NULL,
  p_division text DEFAULT NULL,
  p_club text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_max_price numeric DEFAULT NULL,
  p_limit int DEFAULT 80,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_rows jsonb;
  v_total int;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season', 'players', '[]'::jsonb);
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.gpfl_player_prices pp
  LEFT JOIN public."Clubs" c ON c."ShortName" = pp.club_short_name
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
    AND (p_division IS NULL OR pp.division = p_division)
    AND (
      p_club IS NULL
      OR pp.club_short_name = p_club
      OR coalesce(c."Club", '') ILIKE p_club
    )
    AND (p_max_price IS NULL OR pp.price <= p_max_price)
    AND (
      v_q IS NULL
      OR pp.player_name ILIKE '%' || v_q || '%'
      OR pp.club_short_name ILIKE '%' || v_q || '%'
      OR coalesce(c."Club", '') ILIKE '%' || v_q || '%'
      OR coalesce(public.competition_owner_display_name(c.owner_id), '') ILIKE '%' || v_q || '%'
      OR coalesce(c.owner, '') ILIKE '%' || v_q || '%'
    );

  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      pp.player_id,
      pp.player_name,
      pp.club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), pp.club_short_name) AS club_name,
      CASE
        WHEN c.owner_id IS NULL AND coalesce(nullif(btrim(c.owner), ''), '') = '' THEN 'Vacant'
        ELSE coalesce(
          nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
          nullif(btrim(c.owner), ''),
          'Vacant'
        )
      END AS owner_name,
      pp.division,
      pp.position,
      pp.position_group,
      pp.price,
      pp.market_value_raw
    FROM public.gpfl_player_prices pp
    LEFT JOIN public."Clubs" c ON c."ShortName" = pp.club_short_name
    WHERE pp.gpfl_season_id = v_gs_id
      AND pp.eligible = true
      AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
      AND (p_division IS NULL OR pp.division = p_division)
      AND (
        p_club IS NULL
        OR pp.club_short_name = p_club
        OR coalesce(c."Club", '') ILIKE p_club
      )
      AND (p_max_price IS NULL OR pp.price <= p_max_price)
      AND (
        v_q IS NULL
        OR pp.player_name ILIKE '%' || v_q || '%'
        OR pp.club_short_name ILIKE '%' || v_q || '%'
        OR coalesce(c."Club", '') ILIKE '%' || v_q || '%'
        OR coalesce(public.competition_owner_display_name(c.owner_id), '') ILIKE '%' || v_q || '%'
        OR coalesce(c.owner, '') ILIKE '%' || v_q || '%'
      )
    ORDER BY pp.price DESC, pp.player_name
    LIMIT greatest(1, least(coalesce(p_limit, 80), 200))
    OFFSET greatest(0, coalesce(p_offset, 0))
  ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'total', v_total,
    'players', v_rows
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_my_entry()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_cfg jsonb;
  v_squad jsonb;
  v_season jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_cfg := public.gpfl_settings_get();
  v_gs_id := public.gpfl_current_season_id();

  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', null,
      'settings', v_cfg
    );
  END IF;

  SELECT to_jsonb(gs.*) INTO v_season
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid;

  IF NOT FOUND OR v_entry.status = 'withdrawn' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', v_gs_id,
      'season', v_season,
      'settings', v_cfg
    );
  END IF;

  PERFORM public.gpfl_sync_free_agents(v_gs_id);
  SELECT * INTO v_entry
  FROM public.gpfl_entries WHERE id = v_entry.id;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY
    CASE x.position_group WHEN 'gk' THEN 1 WHEN 'def' THEN 2 WHEN 'mid' THEN 3 ELSE 4 END,
    x.player_name
  ), '[]'::jsonb)
  INTO v_squad
  FROM (
    SELECT
      sp.id,
      sp.player_id,
      sp.position_group,
      sp.purchase_price,
      sp.is_starter,
      sp.is_captain,
      sp.slot_status,
      pp.player_name,
      pp.club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), pp.club_short_name) AS club_name,
      CASE
        WHEN c.owner_id IS NULL AND coalesce(nullif(btrim(c.owner), ''), '') = '' THEN 'Vacant'
        ELSE coalesce(
          nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
          nullif(btrim(c.owner), ''),
          'Vacant'
        )
      END AS owner_name,
      pp.division,
      pp.position,
      pp.price AS current_price,
      pp.eligible
    FROM public.gpfl_squad_players sp
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
    LEFT JOIN public."Clubs" c ON c."ShortName" = pp.club_short_name
    WHERE sp.entry_id = v_entry.id
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
    'joined', true,
    'gpfl_season_id', v_gs_id,
    'season', v_season,
    'settings', v_cfg,
    'entry', to_jsonb(v_entry),
    'squad', v_squad
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_list_players(text, text, text, text, numeric, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_my_entry() TO authenticated;
