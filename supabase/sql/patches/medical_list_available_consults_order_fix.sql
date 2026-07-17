-- =============================================================================
-- Fix: medical_list_available_consults ORDER BY used x.id but column is consult_id
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.medical_list_available_consults(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_out jsonb;
BEGIN
  IF v_club IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  PERFORM public.medical_sync_named_consults(v_club);

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.matches_removed DESC, x.consult_id), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT
      c.id AS consult_id,
      c.matches_removed AS param_int,
      c.matches_removed,
      c.inventory_id,
      c.group_name,
      c.consultant_name,
      c.label,
      c.label AS consultancy_label,
      CASE WHEN c.inventory_id IS NULL THEN 'vault' ELSE 'prize' END AS kind,
      c.status
    FROM public.club_medical_consults c
    WHERE c.club_short_name = v_club
      AND c.status = 'available'
  ) x;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.medical_room_prize_tokens(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.medical_list_available_consults(p_club);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_list_available_consults(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_room_prize_tokens(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
