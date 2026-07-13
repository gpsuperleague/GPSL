-- =============================================================================
-- Admin workflow checklist (manual ticks for Admin menu tasks)
-- UI: admin_workflow_checklist.html
-- Scoped to competition_seasons.id (current season). Safe to re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_workflow_checklist (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  task_key text NOT NULL,
  is_done boolean NOT NULL DEFAULT false,
  note text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  PRIMARY KEY (season_id, task_key)
);

CREATE INDEX IF NOT EXISTS admin_workflow_checklist_season_idx
  ON public.admin_workflow_checklist (season_id);

COMMENT ON TABLE public.admin_workflow_checklist IS
  'Manual Admin menu workflow ticks per season (excludes Testing/Owners in UI).';

ALTER TABLE public.admin_workflow_checklist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_workflow_checklist_admin ON public.admin_workflow_checklist;
CREATE POLICY admin_workflow_checklist_admin ON public.admin_workflow_checklist
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_workflow_checklist TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_workflow_checklist_set(
  p_season_id bigint,
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
  IF p_season_id IS NULL THEN
    RAISE EXCEPTION 'season_id required';
  END IF;
  IF v_key = '' THEN
    RAISE EXCEPTION 'task_key required';
  END IF;

  INSERT INTO public.admin_workflow_checklist AS t (
    season_id, task_key, is_done, note, updated_at, updated_by
  ) VALUES (
    p_season_id,
    v_key,
    coalesce(p_is_done, false),
    NULLIF(trim(coalesce(p_note, '')), ''),
    now(),
    auth.uid()
  )
  ON CONFLICT (season_id, task_key) DO UPDATE
  SET
    is_done = EXCLUDED.is_done,
    note = COALESCE(EXCLUDED.note, t.note),
    updated_at = now(),
    updated_by = auth.uid();

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'task_key', v_key,
    'is_done', coalesce(p_is_done, false)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_workflow_checklist_set(bigint, text, boolean, text)
  TO authenticated;
