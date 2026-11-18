-- Recording checks say "clearly shown" on the qualifying card and the staff alert.

CREATE OR REPLACE FUNCTION public.qualifying_checklist_labels()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT jsonb_build_object(
    'pa3', 'PA3 or PA4',
    'advanced', 'Advanced skill only',
    'matchroom', 'Match-room settings clearly shown',
    'manager', 'Manager clearly shown',
    'subtactic', 'Subtactic clearly shown',
    'fluid', 'Fluid formation clearly shown',
    'squad', 'Squad clearly shown',
    'no_individual', 'No individual player instructions',
    'no_drag', 'No dragging players on the formation',
    'recording', 'Recording runs from the settings through to the ratings'
  );
$function$;

DO $alert$
DECLARE
  v_def text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.qualifying_videos_ingest_post(text,text,text,text,timestamptz)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_def := replace(v_def, 'Match-room settings shown', 'Match-room settings clearly shown');
  v_def := replace(v_def, 'Fluid formation shown', 'Fluid formation clearly shown');
  v_def := replace(v_def, 'Manager shown', 'Manager clearly shown');
  v_def := replace(v_def, 'Subtactic shown', 'Subtactic clearly shown');
  v_def := replace(v_def, 'Squad shown', 'Squad clearly shown');
  IF position('clearly shown' IN v_def) = 0 THEN
    RAISE NOTICE 'ingest alert has no shown lines — labels function is enough';
    RETURN;
  END IF;
  EXECUTE v_def;
END
$alert$;

SELECT public.qualifying_checklist_labels() ->> 'fluid' AS fluid_label;
