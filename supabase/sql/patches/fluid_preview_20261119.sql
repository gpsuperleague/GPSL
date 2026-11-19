-- Match Centre preview: include the hidden fluid shape when one is saved.
-- The player rows stay the visible eleven. Check-in is unchanged.

DO $fluid_preview$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_match_club_preview(text,bigint)'::regprocedure),
    E'\r\n',
    E'\n'
  );
  IF position('''fluid''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$    'formation_name', v_formation_name,$old$, E'\r\n', E'\n');
  v_new := replace($new$    'formation_name', v_formation_name,
    'fluid', CASE
      WHEN coalesce(v_layout #>> '{fluid,on}', '') = 'true' THEN jsonb_build_object(
        'on', true,
        'side', coalesce(nullif(v_layout #>> '{fluid,side}', ''), 'defensive'),
        'other_formation_id', nullif(btrim(v_layout #>> '{fluid,other,formation_id}'), '')
      )
      ELSE NULL
    END,$new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'preview return formation_name not found';
  END IF;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END;
$fluid_preview$;

SELECT position(
  '''fluid''' IN replace(
    pg_get_functiondef('public.competition_match_club_preview(text,bigint)'::regprocedure),
    E'\r\n',
    E'\n'
  )
) > 0 AS preview_has_fluid;
