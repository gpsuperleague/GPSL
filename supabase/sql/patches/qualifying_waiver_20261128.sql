-- Admin tick: this person does not have to qualify before taking a club.
-- Safe to re-run.

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS qualifying_waived boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.owner_qualifying_is_subject(p_owner_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM auth.users u
    JOIN public.gpsl_qualifying_settings s ON s.id = 1
    WHERE u.id = p_owner_id
      AND u.created_at >= s.required_from
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = p_owner_id
      AND r.qualifying_waived
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_owner_set_qualifying_waiver(
  p_owner_id uuid,
  p_waived boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'Choose an owner';
  END IF;

  UPDATE public.gpsl_owner_registry r
  SET qualifying_waived = coalesce(p_waived, false)
  WHERE r.owner_id = p_owner_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'That person is not on the owner board';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'waived', coalesce(p_waived, false)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_owner_qualifying_waiver_map()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_object_agg(r.owner_id::text, true)
      FROM public.gpsl_owner_registry r
      WHERE r.qualifying_waived
    ),
    '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_owner_set_qualifying_waiver(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_owner_qualifying_waiver_map() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_set_qualifying_waiver(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_qualifying_waiver_map() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'column', EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpsl_owner_registry'
      AND column_name = 'qualifying_waived'
  ),
  'setter', to_regprocedure('public.admin_owner_set_qualifying_waiver(uuid,boolean)') IS NOT NULL
) AS result;
