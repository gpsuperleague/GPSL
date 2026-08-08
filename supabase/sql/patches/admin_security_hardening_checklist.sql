-- =============================================================================
-- Admin security hardening checklist (manual ticks, not season-scoped)
-- UI: admin_security_hardening.html under Admin → Testing
-- Safe to re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_security_hardening_checklist (
  task_key text NOT NULL PRIMARY KEY,
  is_done boolean NOT NULL DEFAULT false,
  note text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL
);

COMMENT ON TABLE public.admin_security_hardening_checklist IS
  'Manual Admin → Testing → Security hardening ticks (shared across admins).';

ALTER TABLE public.admin_security_hardening_checklist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_security_hardening_checklist_admin
  ON public.admin_security_hardening_checklist;
CREATE POLICY admin_security_hardening_checklist_admin
  ON public.admin_security_hardening_checklist
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.admin_security_hardening_checklist TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_security_hardening_checklist_set(
  p_task_key text,
  p_is_done boolean,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text := trim(coalesce(p_task_key, ''));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'admin only';
  END IF;
  IF v_key = '' THEN
    RAISE EXCEPTION 'task_key required';
  END IF;

  INSERT INTO public.admin_security_hardening_checklist AS t (
    task_key, is_done, note, updated_at, updated_by
  ) VALUES (
    v_key,
    coalesce(p_is_done, false),
    NULLIF(trim(coalesce(p_note, '')), ''),
    now(),
    auth.uid()
  )
  ON CONFLICT (task_key) DO UPDATE
  SET
    is_done = EXCLUDED.is_done,
    note = COALESCE(EXCLUDED.note, t.note),
    updated_at = now(),
    updated_by = auth.uid();

  RETURN jsonb_build_object(
    'ok', true,
    'task_key', v_key,
    'is_done', coalesce(p_is_done, false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_security_hardening_checklist_set(text, boolean, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
