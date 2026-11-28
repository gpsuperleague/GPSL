-- Season 2 Discord check on the season owner board.
-- Admin records the DM and the reply. Deadline is one week from marking the message sent.
-- Safe to re-run.

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS season2_check_status text,
  ADD COLUMN IF NOT EXISTS season2_check_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS season2_check_deadline_at timestamptz;

ALTER TABLE public.gpsl_owner_registry
  DROP CONSTRAINT IF EXISTS gpsl_owner_registry_season2_check_status_check;

ALTER TABLE public.gpsl_owner_registry
  ADD CONSTRAINT gpsl_owner_registry_season2_check_status_check
  CHECK (
    season2_check_status IS NULL
    OR season2_check_status IN ('sent', 'season2', 'later', 'discord', 'away', 'no_reply')
  );

CREATE OR REPLACE FUNCTION public.admin_owner_set_season2_check(
  p_owner_id uuid,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
  v_sent timestamptz;
  v_deadline timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'Choose an owner';
  END IF;
  IF v_status IS NOT NULL AND v_status NOT IN ('sent', 'season2', 'later', 'discord', 'away', 'no_reply') THEN
    RAISE EXCEPTION 'Unknown Season 2 check';
  END IF;

  IF v_status IS NULL THEN
    UPDATE public.gpsl_owner_registry r
    SET season2_check_status = NULL,
        season2_check_sent_at = NULL,
        season2_check_deadline_at = NULL
    WHERE r.owner_id = p_owner_id;
  ELSIF v_status = 'sent' THEN
    v_sent := now();
    v_deadline := v_sent + interval '7 days';
    UPDATE public.gpsl_owner_registry r
    SET season2_check_status = 'sent',
        season2_check_sent_at = v_sent,
        season2_check_deadline_at = v_deadline
    WHERE r.owner_id = p_owner_id;
  ELSE
    UPDATE public.gpsl_owner_registry r
    SET season2_check_status = v_status
    WHERE r.owner_id = p_owner_id
    RETURNING r.season2_check_sent_at, r.season2_check_deadline_at
    INTO v_sent, v_deadline;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'That person is not on the owner board';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'status', v_status,
    'sent_at', v_sent,
    'deadline_at', v_deadline
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_owner_season2_check_map()
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
      SELECT jsonb_object_agg(
        r.owner_id::text,
        jsonb_build_object(
          'status', r.season2_check_status,
          'sent_at', r.season2_check_sent_at,
          'deadline_at', r.season2_check_deadline_at
        )
      )
      FROM public.gpsl_owner_registry r
      WHERE r.season2_check_status IS NOT NULL
    ),
    '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_owner_set_season2_check(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_owner_season2_check_map() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_set_season2_check(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_season2_check_map() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'status_column', EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpsl_owner_registry'
      AND column_name = 'season2_check_status'
  ),
  'setter', to_regprocedure('public.admin_owner_set_season2_check(uuid,text)') IS NOT NULL,
  'mapper', to_regprocedure('public.admin_owner_season2_check_map()') IS NOT NULL
) AS result;
