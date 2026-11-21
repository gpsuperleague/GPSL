-- Admin posting as their own club: 1500 characters.
-- Everyone else, and league posts, stay at 1000.

ALTER TABLE public.natter_posts
  DROP CONSTRAINT IF EXISTS natter_posts_body_len;

ALTER TABLE public.natter_posts
  ADD CONSTRAINT natter_posts_body_len
  CHECK (char_length(body) >= 1 AND char_length(body) <= 1500);

DO $patch$
DECLARE
  v_def text;
  v_new text;
  v_old text;
  v_repl text;
BEGIN
  SELECT replace(pg_get_functiondef('public.natter_create_post(text, text)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  v_old := replace($old$
  IF char_length(v_body) > 1000 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_long', 'max_chars', 1000);
  END IF;$old$, E'\r\n', E'\n');

  v_repl := replace($new$
  IF char_length(v_body) > CASE WHEN public.is_gpsl_admin() THEN 1500 ELSE 1000 END THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'too_long',
      'max_chars', CASE WHEN public.is_gpsl_admin() THEN 1500 ELSE 1000 END
    );
  END IF;$new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'natter_create_post char check not found';
  END IF;

  v_new := replace(v_def, v_old, v_repl);
  EXECUTE v_new || ';';

  SELECT replace(pg_get_functiondef('public.natter_get_compose_state()'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  v_old := replace($old2$'max_chars', 1000$old2$, E'\r\n', E'\n');
  v_repl := $new2$'max_chars', CASE WHEN public.is_gpsl_admin() THEN 1500 ELSE 1000 END$new2$;

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'natter_get_compose_state max_chars not found';
  END IF;

  EXECUTE replace(v_def, v_old, v_repl) || ';';
END;
$patch$;

NOTIFY pgrst, 'reload schema';

SELECT position(
  'CASE WHEN public.is_gpsl_admin() THEN 1500 ELSE 1000 END' IN replace(
    pg_get_functiondef('public.natter_create_post(text, text)'::regprocedure),
    E'\r\n',
    E'\n'
  )
) > 0 AS create_has_1500;
