-- =============================================================================
-- Bookies: search any eligible player by name and add them as a selection
-- Default market lists stay top-40 by weight/position rules.
-- Search is an add-on path for players not on that board.
-- Safe re-run.
-- =============================================================================

-- Search contracted, position-eligible players for an open player market
CREATE OR REPLACE FUNCTION public.bookies_search_players_for_market(
  p_market_id bigint,
  p_query text,
  p_limit int DEFAULT 12
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_m public.bookies_markets%ROWTYPE;
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
  v_norm text;
  v_lim int := greatest(1, least(coalesce(p_limit, 12), 25));
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF v_q IS NULL OR char_length(v_q) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT * INTO v_m FROM public.bookies_markets WHERE id = p_market_id;
  IF NOT FOUND OR v_m.market_kind <> 'player' THEN
    RAISE EXCEPTION 'Player market not found';
  END IF;

  BEGIN
    v_norm := public.gpdb_normalize_search_text(v_q);
  EXCEPTION
    WHEN OTHERS THEN
      v_norm := lower(v_q);
  END;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.rank_w DESC, x.player_name), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name"::text AS player_name,
      p."Position"::text AS position,
      public.player_contracted_club_key(p."Contracted_Team") AS club,
      public.bookies_player_rating_num(p."Rating"::text) AS rating,
      EXISTS (
        SELECT 1 FROM public.bookies_selections s
        WHERE s.market_id = p_market_id
          AND s.selection_key = p."Konami_ID"::text
          AND coalesce((s.metadata->>'withdrawn')::boolean, false) IS NOT TRUE
      ) AS already_listed,
      public.bookies_player_rating_num(p."Rating"::text) AS rank_w
    FROM public."Players" p
    WHERE coalesce(btrim(public.player_contracted_club_key(p."Contracted_Team")), '') <> ''
      AND public.player_contracted_club_key(p."Contracted_Team") IN (
        SELECT ccs.club_short_name
        FROM public.competition_club_seasons ccs
        WHERE ccs.season_id = v_m.season_id
          AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      )
      AND public.bookies_player_eligible(v_m.market_code, p."Konami_ID"::text)
      AND (
        (p.name_search_key IS NOT NULL AND p.name_search_key LIKE '%' || v_norm || '%')
        OR lower(p."Name"::text) LIKE '%' || lower(v_q) || '%'
      )
    ORDER BY public.bookies_player_rating_num(p."Rating"::text) DESC, p."Name"
    LIMIT v_lim
  ) x;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_search_players_for_market(bigint, text, int) TO authenticated;

-- Ensure a selection exists for an eligible player (adds if missing, returns selection)
CREATE OR REPLACE FUNCTION public.bookies_ensure_player_selection(
  p_market_id bigint,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_m public.bookies_markets%ROWTYPE;
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_name text;
  v_pos text;
  v_club text;
  v_rating numeric;
  v_w numeric;
  v_sel_id bigint;
  v_label text;
  v_sort int;
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_pid = '' THEN
    RAISE EXCEPTION 'Player id required';
  END IF;

  SELECT * INTO v_m FROM public.bookies_markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND OR v_m.market_kind <> 'player' THEN
    RAISE EXCEPTION 'Player market not found';
  END IF;

  IF v_m.status <> 'open' THEN
    RAISE EXCEPTION 'Market is not open for betting';
  END IF;

  IF NOT public.bookies_player_eligible(v_m.market_code, v_pid) THEN
    RAISE EXCEPTION 'That player is not eligible for this market (position rules)';
  END IF;

  SELECT
    p."Name"::text,
    p."Position"::text,
    public.player_contracted_club_key(p."Contracted_Team"),
    public.bookies_player_rating_num(p."Rating"::text)
  INTO v_name, v_pos, v_club, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF coalesce(btrim(v_club), '') = '' THEN
    RAISE EXCEPTION 'Player is not contracted to a GPSL club';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_m.season_id
      AND ccs.club_short_name = v_club
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  ) THEN
    RAISE EXCEPTION 'Player club is not in a league division this season';
  END IF;

  -- Clean sheets: only one GK per club (prefer existing selection)
  IF lower(v_m.market_code) LIKE 'clean_sheets%' THEN
    SELECT s.id INTO v_sel_id
    FROM public.bookies_selections s
    WHERE s.market_id = p_market_id
      AND coalesce(s.metadata->>'club', '') = v_club
      AND coalesce((s.metadata->>'withdrawn')::boolean, false) IS NOT TRUE
    LIMIT 1;
    IF v_sel_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.bookies_selections s
      WHERE s.id = v_sel_id AND s.selection_key = v_pid
    ) THEN
      RAISE EXCEPTION 'This club already has a GK listed for clean sheets';
    END IF;
  END IF;

  SELECT s.id INTO v_sel_id
  FROM public.bookies_selections s
  WHERE s.market_id = p_market_id
    AND s.selection_key = v_pid
  LIMIT 1;

  IF v_sel_id IS NOT NULL THEN
    UPDATE public.bookies_selections
    SET metadata = coalesce(metadata, '{}'::jsonb) - 'withdrawn'
    WHERE id = v_sel_id;

    SELECT jsonb_build_object(
      'ok', true,
      'created', false,
      'selection_id', s.id,
      'selection_key', s.selection_key,
      'label', s.label,
      'odds_decimal', s.odds_decimal,
      'odds_fractional', s.odds_fractional,
      'market_id', s.market_id
    )
    INTO v_out
    FROM public.bookies_selections s
    WHERE s.id = v_sel_id;

    RETURN v_out;
  END IF;

  -- Conservative on-demand weight from rating (+ tiny club strength for GKs)
  v_w := greatest(0.5, coalesce(v_rating, 70) / 40.0);
  IF lower(v_m.market_code) LIKE 'clean_sheets%' THEN
    BEGIN
      v_w := v_w + public.bookies_club_strength(v_club, v_m.season_id) / 8.0;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  END IF;

  SELECT coalesce(max(sort_order), 0) + 1 INTO v_sort
  FROM public.bookies_selections
  WHERE market_id = p_market_id;

  v_label := v_name || ' (' || coalesce(public.club_display_name(v_club), v_club) || ')';

  INSERT INTO public.bookies_selections (
    market_id, selection_key, label, odds_decimal, sort_order, weight, metadata
  )
  VALUES (
    p_market_id,
    v_pid,
    v_label,
    20,
    v_sort,
    v_w,
    jsonb_build_object(
      'club', v_club,
      'position', v_pos,
      'via', 'name_search',
      'rating', v_rating
    )
  )
  RETURNING id INTO v_sel_id;

  IF v_sel_id IS NULL THEN
    RAISE EXCEPTION 'Could not add player (eligibility blocked)';
  END IF;

  PERFORM public.bookies_apply_odds_from_weights(p_market_id);

  RETURN (
    SELECT jsonb_build_object(
      'ok', true,
      'created', true,
      'selection_id', s.id,
      'selection_key', s.selection_key,
      'label', s.label,
      'odds_decimal', s.odds_decimal,
      'odds_fractional', s.odds_fractional,
      'market_id', s.market_id
    )
    FROM public.bookies_selections s
    WHERE s.id = v_sel_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_ensure_player_selection(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
