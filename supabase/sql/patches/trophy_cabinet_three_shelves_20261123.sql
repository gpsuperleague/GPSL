-- Cabinet display: 3 shelves, 10 places each.
-- Existing places on shelves 0 and 1 stay where they are.

ALTER TABLE public.competition_trophy_cabinet_place
  DROP CONSTRAINT IF EXISTS competition_trophy_cabinet_place_spot;

ALTER TABLE public.competition_trophy_cabinet_place
  ADD CONSTRAINT competition_trophy_cabinet_place_spot CHECK (
    (stored AND shelf IS NULL AND slot IS NULL)
    OR (
      NOT stored
      AND shelf BETWEEN 0 AND 2
      AND slot BETWEEN 0 AND 9
    )
  );

DO $save$
DECLARE
  v_def text;
  v_old text := 'OR v_shelf < 0 OR v_shelf > 1';
  v_new text := 'OR v_shelf < 0 OR v_shelf > 2';
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_trophy_cabinet_save(text,jsonb)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'cabinet save already allows three shelves';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'cabinet shelf bound needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$save$;

SELECT pg_get_constraintdef(oid) AS spot
FROM pg_constraint
WHERE conname = 'competition_trophy_cabinet_place_spot';
