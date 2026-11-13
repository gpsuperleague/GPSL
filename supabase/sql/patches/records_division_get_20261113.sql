-- Old record pages ask for one catalog and should keep seeing Super League
-- league rows. The new page asks for every division.

DROP FUNCTION IF EXISTS public.gpsl_records_get(text);

CREATE OR REPLACE FUNCTION public.gpsl_records_get(
  p_catalog text DEFAULT NULL,
  p_tier text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cat text := nullif(lower(btrim(coalesce(p_catalog, ''))), '');
  v_tier text := nullif(lower(btrim(coalesce(p_tier, ''))), '');
  v_meta jsonb;
  v_rows jsonb;
BEGIN
  SELECT to_jsonb(m) - 'id' INTO v_meta
  FROM public.gpsl_alltime_records_meta m
  WHERE id = 1;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.catalog, r.record_id, r.tier), '[]'::jsonb)
  INTO v_rows
  FROM public.gpsl_alltime_records r
  WHERE (v_cat IS NULL OR r.catalog = v_cat)
    AND (
      v_tier = 'all'
      OR (v_tier IS NULL AND (r.catalog <> 'league' OR r.tier = 'superleague'))
      OR (v_tier IS NOT NULL AND v_tier <> 'all' AND r.tier = v_tier)
    );

  RETURN jsonb_build_object(
    'ok', true,
    'catalog', v_cat,
    'tier', v_tier,
    'meta', v_meta,
    'records', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_records_get(text, text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';

SELECT
  count(*) FILTER (WHERE tier = 'superleague') AS superleague,
  count(*) FILTER (WHERE tier = 'championship') AS championship
FROM public.gpsl_alltime_records
WHERE catalog = 'league';
