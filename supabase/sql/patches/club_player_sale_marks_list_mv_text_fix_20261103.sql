-- Fix club_player_sale_marks_list: Players.market_value is text — cast before COALESCE.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.club_player_sale_marks_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_rows jsonb;
  v_total numeric := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'club', null, 'marks', '[]'::jsonb, 'total_market_value', 0);
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.market_value DESC NULLS LAST, x.player_name), '[]'::jsonb),
         coalesce(sum(x.market_value), 0)
  INTO v_rows, v_total
  FROM (
    SELECT
      m.player_id,
      m.note,
      m.updated_at,
      p."Name" AS player_name,
      p."Position" AS position,
      nullif(btrim(p."Rating"::text), '') AS overall_rating,
      coalesce(
        nullif(
          regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.\-]', '', 'g'),
          ''
        )::numeric,
        0
      ) AS market_value,
      EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.player_id::text = m.player_id
          AND l.seller_club_id = v_club
          AND l.status IN ('Active', 'Pending Window', 'Review', 'Seller Review')
      ) AS is_listed
    FROM public.club_player_sale_marks m
    JOIN public."Players" p
      ON p."Konami_ID"::text = m.player_id
     AND upper(nullif(btrim(p."Contracted_Team"), '')) = v_club
    WHERE m.club_short_name = v_club
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'marks', coalesce(v_rows, '[]'::jsonb),
    'total_market_value', coalesce(v_total, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_player_sale_marks_list()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_player_sale_marks_list()
  TO authenticated;

NOTIFY pgrst, 'reload schema';
