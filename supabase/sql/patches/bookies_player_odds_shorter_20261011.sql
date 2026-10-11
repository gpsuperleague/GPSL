-- =============================================================================
-- Bookies: much shorter starting odds on player markets (top scorers etc.)
--
-- Player markets were priced as total weight ÷ own weight across ~40 players,
-- so everyone opened around 33-1 to 50-1. Player markets now open on a
-- rank ladder (rank by the player's weight — goals, apps, rating):
--   1st 3-1 · 2nd 7-2 · 3rd 4-1 · 4th 9-2 · 5th 5-1 · 6-7th 6-1 · 8-10th 8-1
--   11-15th 10-1 · 16-20th 14-1 · 21-30th 20-1 · 31st+ 25-1
-- Money on a player still shortens his price (same ₿20 ≈ +1 weight steam).
-- Club markets keep the existing weight-based pricing.
-- Safe re-run. Re-prices every open/closed market at the end.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_player_rank_price(p_rank int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_rank <= 1 THEN 4.00   -- 3-1
    WHEN p_rank = 2 THEN 4.50    -- 7-2
    WHEN p_rank = 3 THEN 5.00    -- 4-1
    WHEN p_rank = 4 THEN 5.50    -- 9-2
    WHEN p_rank = 5 THEN 6.00    -- 5-1
    WHEN p_rank <= 7 THEN 7.00   -- 6-1
    WHEN p_rank <= 10 THEN 9.00  -- 8-1
    WHEN p_rank <= 15 THEN 11.00 -- 10-1
    WHEN p_rank <= 20 THEN 15.00 -- 14-1
    WHEN p_rank <= 30 THEN 21.00 -- 20-1
    ELSE 26.00                   -- 25-1
  END::numeric;
$function$;

CREATE OR REPLACE FUNCTION public.bookies_apply_odds_from_weights(p_market_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sum numeric := 0;
  v_margin numeric := 0.08;
  -- Every ₿20 matched ≈ +1 weight (shortens that selection)
  v_steam_div numeric := 20;
  v_kind text;
  r record;
  v_eff numeric;
  v_raw numeric;
  v_odds numeric;
BEGIN
  SELECT lower(coalesce(market_kind, '')) INTO v_kind
  FROM public.bookies_markets WHERE id = p_market_id;

  IF v_kind = 'player' THEN
    FOR r IN
      SELECT
        s.id,
        greatest(s.weight, 0.25) AS base_w,
        public.bookies_selection_open_stakes(s.id) AS steam,
        row_number() OVER (ORDER BY s.weight DESC NULLS LAST, s.sort_order, s.id)::int AS rnk
      FROM public.bookies_selections s
      WHERE s.market_id = p_market_id
    LOOP
      v_eff := r.base_w + (r.steam / v_steam_div);
      -- Rank price, then steam shortens the profit part in proportion
      v_raw := 1 + (public.bookies_player_rank_price(r.rnk) - 1) * (r.base_w / v_eff);
      v_odds := public.bookies_snap_uk_odds(v_raw);

      UPDATE public.bookies_selections
      SET odds_decimal = v_odds,
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
            'steam_stakes', r.steam,
            'effective_weight', round(v_eff, 2),
            'odds_ladder', 'uk_player_rank',
            'price_rank', r.rnk,
            'odds_moved', true
          )
      WHERE id = r.id;
    END LOOP;
    RETURN;
  END IF;

  FOR r IN
    SELECT
      s.id,
      greatest(s.weight, 0.25) AS base_w,
      public.bookies_selection_open_stakes(s.id) AS steam
    FROM public.bookies_selections s
    WHERE s.market_id = p_market_id
  LOOP
    v_eff := r.base_w + (r.steam / v_steam_div);
    v_sum := v_sum + v_eff;
  END LOOP;

  IF v_sum <= 0 THEN
    UPDATE public.bookies_selections
    SET odds_decimal = 11  -- 10-1
    WHERE market_id = p_market_id;
    RETURN;
  END IF;

  FOR r IN
    SELECT
      s.id,
      greatest(s.weight, 0.25) AS base_w,
      public.bookies_selection_open_stakes(s.id) AS steam
    FROM public.bookies_selections s
    WHERE s.market_id = p_market_id
  LOOP
    v_eff := r.base_w + (r.steam / v_steam_div);
    v_raw := (v_sum / greatest(v_eff, 0.25)) * (1.0 + v_margin);
    v_odds := public.bookies_snap_uk_odds(v_raw);

    UPDATE public.bookies_selections
    SET odds_decimal = v_odds,
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'steam_stakes', r.steam,
          'effective_weight', round(v_eff, 2),
          'odds_ladder', 'uk',
          'odds_moved', true
        )
    WHERE id = r.id;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_apply_odds_from_weights(bigint) TO authenticated;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id FROM public.bookies_markets WHERE status IN ('open', 'closed')
  LOOP
    PERFORM public.bookies_apply_odds_from_weights(r.id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

-- Report: top 8 prices in each player market
SELECT m.title, s.label, public.bookies_fractional_odds_label(s.odds_decimal) AS odds,
       (s.metadata->>'price_rank')::int AS price_rank
FROM public.bookies_markets m
JOIN public.bookies_selections s ON s.market_id = m.id
WHERE m.market_kind = 'player'
  AND m.status IN ('open', 'closed')
  AND coalesce((s.metadata->>'price_rank')::int, 99) <= 8
ORDER BY m.id, (s.metadata->>'price_rank')::int;
