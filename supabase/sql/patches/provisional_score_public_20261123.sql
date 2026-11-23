-- A pending league score is on the public table, so the scoreline is public too.
-- Safe re-run.

DO $open$
DECLARE
  v_def text;
  v_old text := 'AND (is_gpsl_admin() OR my_club_shortname() = f.home_club_short_name OR my_club_shortname() = f.away_club_short_name)';
BEGIN
  v_def := pg_get_viewdef('public.competition_fixtures_public'::regclass, true);
  IF position(v_old IN v_def) = 0 THEN
    IF position('is_gpsl_admin()' IN v_def) = 0 THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'pending score filter not found';
  END IF;
  v_def := replace(v_def, v_old, '');
  IF right(btrim(v_def), 1) = ';' THEN
    v_def := left(btrim(v_def), length(btrim(v_def)) - 1);
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.competition_fixtures_public WITH (security_invoker = false) AS ' || v_def;
END;
$open$;

GRANT SELECT ON public.competition_fixtures_public TO authenticated;

SELECT position(
  'is_gpsl_admin()' IN pg_get_viewdef('public.competition_fixtures_public'::regclass, true)
) AS still_hidden;
