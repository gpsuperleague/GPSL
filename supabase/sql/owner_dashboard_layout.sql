-- Per-owner dashboard tile order and selection (panel_ids = registry ids in dashboard_registry.js).

CREATE TABLE IF NOT EXISTS public.owner_dashboard_layout (
  owner_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  panel_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.owner_dashboard_layout IS
  'Owner-chosen dashboard shortcuts; panel_ids match dashboard_registry.js ids. sections + panel_labels are per-owner only.';

ALTER TABLE public.owner_dashboard_layout ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owners read own dashboard layout" ON public.owner_dashboard_layout;
CREATE POLICY "Owners read own dashboard layout"
  ON public.owner_dashboard_layout
  FOR SELECT
  TO authenticated
  USING (owner_id = auth.uid());

DROP POLICY IF EXISTS "Owners insert own dashboard layout" ON public.owner_dashboard_layout;
CREATE POLICY "Owners insert own dashboard layout"
  ON public.owner_dashboard_layout
  FOR INSERT
  TO authenticated
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS "Owners update own dashboard layout" ON public.owner_dashboard_layout;
CREATE POLICY "Owners update own dashboard layout"
  ON public.owner_dashboard_layout
  FOR UPDATE
  TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

GRANT SELECT, INSERT, UPDATE ON public.owner_dashboard_layout TO authenticated;
