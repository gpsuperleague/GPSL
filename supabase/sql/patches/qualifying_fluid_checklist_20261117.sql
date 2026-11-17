-- Fluid formation has to be on the qualifying recording.
-- The staff alert lists the same checks the member sees on step 3.

CREATE OR REPLACE FUNCTION public.qualifying_checklist_labels()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT jsonb_build_object(
    'pa3', 'PA3 or PA4',
    'advanced', 'Advanced skill only',
    'matchroom', 'Match-room settings shown',
    'manager', 'Manager shown',
    'subtactic', 'Subtactic shown',
    'fluid', 'Fluid formation shown',
    'squad', 'Squad shown',
    'no_individual', 'No individual player instructions',
    'no_drag', 'No dragging players on the formation',
    'recording', 'Recording runs from the settings through to the ratings'
  );
$function$;

DO $alert_checks$
DECLARE
  v_def text;
  v_old text := $old$Tick the matchday card on Qualifying videos.$old$;
  v_new text := $new$On the open recording, tick:
PA3 or PA4
Advanced skill only
Match-room settings shown
Manager shown
Subtactic shown
Fluid formation shown
Squad shown
No individual player instructions
No dragging players on the formation
Recording runs from the settings through to the ratings$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.qualifying_videos_ingest_post(text,text,text,text,timestamptz)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('Fluid formation shown' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'qualifying video alert text not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$alert_checks$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'fluid_label', (public.qualifying_checklist_labels() ->> 'fluid') = 'Fluid formation shown',
  'alert_lists_fluid', position(
    'Fluid formation shown'
    IN pg_get_functiondef('public.qualifying_videos_ingest_post(text,text,text,text,timestamptz)'::regprocedure)
  ) > 0
) AS info;
