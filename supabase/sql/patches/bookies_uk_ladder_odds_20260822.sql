-- =============================================================================
-- Bookies: lock UK fractional ladder (not whole-number only)
--
-- Whole-number snap made every price look like "5-1", "10-1", …
-- This restores a proper bookie ladder (6-4, 11-8, 5-2, 7-2, …) and keeps
-- dynamic steam: money on a selection shortens that price.
--
-- Safe re-run. Then refresh Bookies in the browser (or click Refresh odds).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_fractional_odds_label(p_decimal numeric)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_profit numeric;
  v_best_n int := 1;
  v_best_d int := 1;
  v_best_err numeric := 1e9;
  v_n int;
  v_d int;
  v_err numeric;
  v_a int;
  v_b int;
  v_t int;
BEGIN
  IF p_decimal IS NULL OR p_decimal <= 1 THEN
    RETURN '—';
  END IF;

  v_profit := p_decimal - 1;

  -- Exact whole profit → classic "n-1"
  IF abs(v_profit - round(v_profit)) < 0.0005 AND round(v_profit) >= 1 THEN
    RETURN round(v_profit)::int::text || '-1';
  END IF;

  FOR v_d IN 1..20 LOOP
    v_n := greatest(1, round(v_profit * v_d)::int);
    v_err := abs((v_n::numeric / v_d) - v_profit);
    IF v_err < v_best_err - 1e-12
       OR (abs(v_err - v_best_err) < 1e-12 AND v_d < v_best_d) THEN
      v_best_err := v_err;
      v_best_n := v_n;
      v_best_d := v_d;
    END IF;
  END LOOP;

  v_a := v_best_n;
  v_b := v_best_d;
  WHILE v_b <> 0 LOOP
    v_t := v_b;
    v_b := v_a % v_b;
    v_a := v_t;
  END LOOP;

  RETURN (v_best_n / v_a)::text || '-' || (v_best_d / v_a)::text;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bookies_snap_uk_odds(p_raw numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  -- Decimal = 1 + (num/den). Standard UK board prices.
  v_ladder numeric[] := ARRAY[
    1.20,  -- 1-5
    1.25,  -- 1-4
    1.33,  -- 1-3
    1.40,  -- 2-5
    1.50,  -- 1-2
    1.53,  -- 8-15
    1.57,  -- 4-7
    1.62,  -- 8-13
    1.67,  -- 4-6 / 2-3
    1.73,  -- 8-11
    1.80,  -- 4-5
    1.83,  -- 5-6
    1.91,  -- 10-11
    2.00,  -- Evens / 1-1
    2.10,  -- 11-10
    2.20,  -- 6-5
    2.25,  -- 5-4
    2.38,  -- 11-8
    2.50,  -- 6-4 / 3-2
    2.63,  -- 13-8
    2.75,  -- 7-4
    2.80,  -- 9-5
    3.00,  -- 2-1
    3.25,  -- 9-4
    3.50,  -- 5-2
    3.75,  -- 11-4
    4.00,  -- 3-1
    4.50,  -- 7-2
    5.00,  -- 4-1
    5.50,  -- 9-2
    6.00,  -- 5-1
    7.00,  -- 6-1
    8.00,  -- 7-1
    9.00,  -- 8-1
    10.00, -- 9-1
    11.00, -- 10-1
    13.00, -- 12-1
    15.00, -- 14-1
    17.00, -- 16-1
    19.00, -- 18-1
    21.00, -- 20-1
    26.00, -- 25-1
    34.00, -- 33-1
    41.00, -- 40-1
    51.00, -- 50-1
    67.00, -- 66-1
    101.00 -- 100-1
  ];
  v_raw numeric := coalesce(p_raw, 11);
  v_best numeric := 11;
  v_best_err numeric := 1e9;
  v_p numeric;
  v_err numeric;
BEGIN
  IF v_raw < 1.15 THEN
    RETURN 1.20;
  END IF;
  IF v_raw > 101 THEN
    RETURN 101;
  END IF;

  FOREACH v_p IN ARRAY v_ladder LOOP
    v_err := abs(v_p - v_raw);
    IF v_err < v_best_err THEN
      v_best_err := v_err;
      v_best := v_p;
    END IF;
  END LOOP;

  RETURN v_best;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bookies_selection_open_stakes(p_selection_id bigint)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(sum(b.stake), 0)::numeric
  FROM public.bookies_bets b
  WHERE b.selection_id = p_selection_id
    AND b.status = 'open';
$$;

-- Dynamic steam + UK ladder (never whole-number-only rounding)
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
  r record;
  v_eff numeric;
  v_raw numeric;
  v_odds numeric;
BEGIN
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

GRANT EXECUTE ON FUNCTION public.bookies_fractional_odds_label(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_snap_uk_odds(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_apply_odds_from_weights(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_selection_open_stakes(bigint) TO authenticated;

-- Re-snap all open/closed boards now
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
