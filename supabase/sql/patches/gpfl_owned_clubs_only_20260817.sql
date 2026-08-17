-- =============================================================================
-- GPFL: exclude vacant (unowned) clubs from the player pool
-- Contracted + owned clubs only. Safe re-run.
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
  v_comp_id bigint;
  v_cfg public.gpfl_settings%rowtype;
  v_rows jsonb;
  v_total int;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season', 'players', '[]'::jsonb);
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  SELECT competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons WHERE id = v_gs_id;

  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT count(*)::int INTO v_total
  FROM public.gpfl_player_prices pp
  JOIN public."Players" p ON p."Konami_ID"::text = pp.player_id
  JOIN public.competition_club_seasons ccs
    ON ccs.club_short_name = p."Contracted_Team"
   AND ccs.season_id = v_comp_id
  JOIN public."Clubs" c
    ON c."ShortName" = p."Contracted_Team"
   AND c.owner_id IS NOT NULL
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND p."Contracted_Team" IS NOT NULL
    AND btrim(p."Contracted_Team") <> ''
    AND ccs.division = ANY (v_cfg.divisions)
    AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
    AND (p_division IS NULL OR ccs.division = p_division OR pp.division = p_division)
    AND (
      p_club IS NULL
      OR p."Contracted_Team" = p_club
      OR pp.club_short_name = p_club
      OR coalesce(c."Club", '') ILIKE p_club
    )
    AND (p_max_price IS NULL OR pp.price <= p_max_price)
    AND (
      v_q IS NULL
      OR pp.player_name ILIKE '%' || v_q || '%'
      OR p."Name" ILIKE '%' || v_q || '%'
      OR p."Contracted_Team" ILIKE '%' || v_q || '%'
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
      coalesce(nullif(btrim(p."Name"), ''), pp.player_name) AS player_name,
      p."Contracted_Team" AS club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), p."Contracted_Team") AS club_name,
      coalesce(
        nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
        nullif(btrim(c.owner), ''),
        'Owner'
      ) AS owner_name,
      ccs.division,
      coalesce(nullif(btrim(p."Position"::text), ''), pp.position) AS position,
      pp.position_group,
      pp.price,
      pp.market_value_raw
    FROM public.gpfl_player_prices pp
    JOIN public."Players" p ON p."Konami_ID"::text = pp.player_id
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = p."Contracted_Team"
     AND ccs.season_id = v_comp_id
    JOIN public."Clubs" c
      ON c."ShortName" = p."Contracted_Team"
     AND c.owner_id IS NOT NULL
    WHERE pp.gpfl_season_id = v_gs_id
      AND pp.eligible = true
      AND p."Contracted_Team" IS NOT NULL
      AND btrim(p."Contracted_Team") <> ''
      AND ccs.division = ANY (v_cfg.divisions)
      AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
      AND (p_division IS NULL OR ccs.division = p_division OR pp.division = p_division)
      AND (
        p_club IS NULL
        OR p."Contracted_Team" = p_club
        OR pp.club_short_name = p_club
        OR coalesce(c."Club", '') ILIKE p_club
      )
      AND (p_max_price IS NULL OR pp.price <= p_max_price)
      AND (
        v_q IS NULL
        OR pp.player_name ILIKE '%' || v_q || '%'
        OR p."Name" ILIKE '%' || v_q || '%'
        OR p."Contracted_Team" ILIKE '%' || v_q || '%'
        OR pp.club_short_name ILIKE '%' || v_q || '%'
        OR coalesce(c."Club", '') ILIKE '%' || v_q || '%'
        OR coalesce(public.competition_owner_display_name(c.owner_id), '') ILIKE '%' || v_q || '%'
        OR coalesce(c.owner, '') ILIKE '%' || v_q || '%'
      )
    ORDER BY pp.price DESC, coalesce(p."Name", pp.player_name)
    LIMIT greatest(1, least(coalesce(p_limit, 80), 200))
    OFFSET greatest(0, coalesce(p_offset, 0))
  ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'total', v_total,
    'players', v_rows,
    'contracted_only', true,
    'owned_clubs_only', true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_add_player(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_comp_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_price public.gpfl_player_prices%rowtype;
  v_count int;
  v_club_count int;
  v_pos_count int;
  v_slot_cap int;
  v_club text;
  v_owner uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.enabled, true) THEN RAISE EXCEPTION 'GPFL disabled'; END IF;

  v_gs_id := public.gpfl_current_season_id();
  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons WHERE id = v_gs_id;

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  SELECT p."Contracted_Team" INTO v_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id;

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'Player is not contracted — not available in GPFL';
  END IF;

  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Vacant clubs are not available in GPFL';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_comp_id
      AND ccs.club_short_name = v_club
      AND ccs.division = ANY (v_cfg.divisions)
  ) THEN
    RAISE EXCEPTION 'Player club is outside the GPFL pool divisions';
  END IF;

  SELECT * INTO v_price
  FROM public.gpfl_player_prices
  WHERE gpfl_season_id = v_gs_id AND player_id = p_player_id AND eligible = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not in GPFL pool'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpfl_squad_players
    WHERE entry_id = v_entry.id AND player_id = p_player_id AND slot_status = 'active'
  ) THEN
    RAISE EXCEPTION 'Already in your squad';
  END IF;

  DELETE FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND player_id = p_player_id AND slot_status = 'needs_replace';

  SELECT count(*)::int INTO v_count
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';
  IF v_count >= v_cfg.squad_size THEN
    RAISE EXCEPTION 'Squad full (% players)', v_cfg.squad_size;
  END IF;

  SELECT count(*)::int INTO v_club_count
  FROM public.gpfl_squad_players sp
  JOIN public.gpfl_player_prices pp
    ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
  WHERE sp.entry_id = v_entry.id
    AND sp.slot_status = 'active'
    AND pp.club_short_name = v_club;
  IF v_club_count >= v_cfg.max_per_club THEN
    RAISE EXCEPTION 'Max % players from one club', v_cfg.max_per_club;
  END IF;

  SELECT count(*)::int INTO v_pos_count
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id
    AND slot_status = 'active'
    AND position_group = v_price.position_group;

  v_slot_cap := CASE v_price.position_group
    WHEN 'gk' THEN v_cfg.slot_gk
    WHEN 'def' THEN v_cfg.slot_def
    WHEN 'mid' THEN v_cfg.slot_mid
    ELSE v_cfg.slot_fwd
  END;
  IF v_pos_count >= v_slot_cap THEN
    RAISE EXCEPTION 'No % slots left', upper(v_price.position_group);
  END IF;

  IF v_entry.budget_remaining < v_price.price THEN
    RAISE EXCEPTION 'Not enough GPFL budget (need ₿%, have ₿%)',
      round(v_price.price), round(v_entry.budget_remaining);
  END IF;

  IF v_entry.status = 'active' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.gpfl_squad_players
      WHERE entry_id = v_entry.id AND slot_status = 'needs_replace'
    ) THEN
      IF v_entry.free_transfers_remaining <= 0 THEN
        RAISE EXCEPTION 'No free transfers left this month';
      END IF;
      UPDATE public.gpfl_entries
      SET free_transfers_remaining = free_transfers_remaining - 1
      WHERE id = v_entry.id;
    END IF;
  END IF;

  INSERT INTO public.gpfl_squad_players (
    entry_id, player_id, position_group, purchase_price, slot_status
  ) VALUES (
    v_entry.id, p_player_id, v_price.position_group, v_price.price, 'active'
  );

  UPDATE public.gpfl_entries
  SET budget_remaining = budget_remaining - v_price.price
  WHERE id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_list_players(text, text, text, text, numeric, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_add_player(text) TO authenticated;
