-- Keep today's category order, then let the admin drag to set sort_order.
-- The video-report list follows that same order.

WITH ranked AS (
  SELECT
    code,
    (row_number() OVER (ORDER BY category, sort_order, label) * 10)::smallint AS n
  FROM public.competition_fine_tariff
)
UPDATE public.competition_fine_tariff t
SET sort_order = ranked.n
FROM ranked
WHERE t.code = ranked.code
  AND t.sort_order IS DISTINCT FROM ranked.n;

CREATE OR REPLACE FUNCTION public.competition_admin_reorder_fine_tariffs(p_codes text[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text;
  v_i int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_codes IS NULL THEN
    RAISE EXCEPTION 'No tariffs';
  END IF;

  FOREACH v_code IN ARRAY p_codes LOOP
    v_code := btrim(coalesce(v_code, ''));
    IF v_code = '' THEN
      CONTINUE;
    END IF;
    v_i := v_i + 1;
    UPDATE public.competition_fine_tariff
    SET sort_order = (v_i * 10)::smallint,
        updated_at = now()
    WHERE code = v_code;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_admin_reorder_fine_tariffs(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_admin_reorder_fine_tariffs(text[]) TO authenticated, service_role;

DO $order$
DECLARE
  v_oid oid := to_regprocedure('public.match_video_report_breach_codes()');
  v_def text;
  v_old text := 'ORDER BY t.category, t.sort_order, t.label';
  v_new text := 'ORDER BY t.sort_order, t.label';
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_video_report_breach_codes not found';
  END IF;
  v_def := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 AND position(v_old IN v_def) = 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'video report tariff order not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$order$;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.competition_admin_reorder_fine_tariffs(text[])') IS NOT NULL AS reorder_fn,
  position(
    'ORDER BY t.sort_order, t.label'
    IN pg_get_functiondef('public.match_video_report_breach_codes()'::regprocedure)
  ) > 0 AS video_uses_sort,
  (SELECT count(*) FROM public.competition_fine_tariff) AS tariffs,
  (SELECT count(DISTINCT sort_order) FROM public.competition_fine_tariff) AS distinct_orders;
