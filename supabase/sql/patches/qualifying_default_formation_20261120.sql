-- Qualifying recording: sub tactic and Fluid have to be a default formation.
-- Staff cannot approve until that tick is on.

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
    'default_formation', 'Default formations only',
    'squad', 'Squad clearly shown',
    'no_individual', 'No individual player instructions',
    'no_drag', 'No dragging players on the formation',
    'recording', 'Recording runs from the settings through to the ratings'
  );
$function$;

DO $alert$
DECLARE
  v_def text;
  v_old text := 'Fluid formation clearly shown';
  v_new text := E'Fluid formation clearly shown\nDefault formations only';
BEGIN
  v_def := replace(
    pg_get_functiondef('public.qualifying_videos_ingest_post(text,text,text,text,timestamptz)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('Default formations only' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'qualifying video alert has no fluid line';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$alert$;

SELECT jsonb_build_object(
  'label', public.qualifying_checklist_labels() ->> 'default_formation',
  'alert', position(
    'Default formations only'
    IN pg_get_functiondef('public.qualifying_videos_ingest_post(text,text,text,text,timestamptz)'::regprocedure)
  ) > 0
) AS result;
