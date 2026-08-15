-- Bookies odds: nearest whole number (min 2, max 101)
-- Safe re-run. Then use Refresh odds on Bookies, or this updates open markets.

CREATE OR REPLACE FUNCTION public.bookies_apply_odds_from_weights(p_market_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sum numeric;
  v_margin numeric := 0.08;
BEGIN
  SELECT coalesce(sum(greatest(weight, 0.25)), 0) INTO v_sum
  FROM public.bookies_selections
  WHERE market_id = p_market_id;

  IF v_sum <= 0 THEN
    UPDATE public.bookies_selections
    SET odds_decimal = 10
    WHERE market_id = p_market_id;
    RETURN;
  END IF;

  UPDATE public.bookies_selections s
  SET odds_decimal = least(
        101,
        greatest(
          2,
          round(
            ((v_sum / greatest(s.weight, 0.25)) * (1.0 + v_margin))::numeric,
            0
          )
        )
      )
  WHERE s.market_id = p_market_id;
END;
$function$;

-- Re-apply to all non-settled markets
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
