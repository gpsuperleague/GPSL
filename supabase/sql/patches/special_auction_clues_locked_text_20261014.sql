-- =============================================================================
-- Snap clues: never send the text of a locked clue to the browser.
-- (special_auction_visible_clues used to return every clue's text with
--  visible = false, so clues 2–4 were readable in dev tools from minute 0.)
-- Locked clues now come back with text = null and has_text = true.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_visible_clues(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a public.special_auctions%rowtype;
  v_mins numeric := 0;
  v_out jsonb := '[]'::jsonb;
  v_clue text;
  v_vis boolean;
  v_n int;
  v_at int[] := ARRAY[0, 20, 40, 50];
  v_disc int[] := ARRAY[20, 10, 5, 0];
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND OR a.status IN ('draft', 'cancelled') THEN
    RETURN '[]'::jsonb;
  END IF;

  IF now() >= a.start_time THEN
    v_mins := extract(epoch FROM (now() - a.start_time)) / 60.0;
  ELSE
    RETURN '[]'::jsonb;
  END IF;

  FOR v_n IN 1..4 LOOP
    v_clue := CASE v_n
      WHEN 1 THEN a.clue_1 WHEN 2 THEN a.clue_2
      WHEN 3 THEN a.clue_3 ELSE a.clue_4
    END;
    CONTINUE WHEN v_clue IS NULL OR btrim(v_clue) = '';
    v_vis := v_mins >= v_at[v_n] OR a.status NOT IN ('scheduled', 'active');
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'n', v_n,
      'at_min', v_at[v_n],
      'discount_pct', v_disc[v_n],
      'visible', v_vis,
      'has_text', true,
      'text', CASE WHEN v_vis THEN v_clue ELSE NULL END
    ));
  END LOOP;

  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION public.special_auction_visible_clues(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: before the snap starts this is [] ; during it, locked clues show text = null
SELECT id, title, status, public.special_auction_visible_clues(id) AS clues_owner_sees
FROM public.special_auctions
WHERE auction_type = 'snap' AND status IN ('scheduled', 'active')
ORDER BY start_time;
