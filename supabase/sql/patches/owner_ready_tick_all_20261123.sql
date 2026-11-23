-- Tick or clear every matchday recording box in one call.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.owner_ready_tick_many(
  p_fixture_id bigint,
  p_item_keys text[],
  p_ticked boolean DEFAULT true
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '20s'
AS $function$
DECLARE
  v_key text;
  v_n int := 0;
BEGIN
  IF p_fixture_id IS NULL THEN
    RAISE EXCEPTION 'Fixture required';
  END IF;
  IF p_item_keys IS NULL OR cardinality(p_item_keys) = 0 THEN
    RETURN 0;
  END IF;
  IF cardinality(p_item_keys) > 40 THEN
    RAISE EXCEPTION 'Too many checklist items';
  END IF;

  FOREACH v_key IN ARRAY p_item_keys
  LOOP
    PERFORM public.owner_ready_tick(v_key, coalesce(p_ticked, true), p_fixture_id);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_ready_tick_many(bigint, text[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_ready_tick_many(bigint, text[], boolean) TO authenticated;

SELECT to_regprocedure('public.owner_ready_tick_many(bigint,text[],boolean)') IS NOT NULL AS ready;
