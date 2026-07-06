-- Per-owner custom dashboard tile labels (private to each login).
-- Run after owner_dashboard_sections.sql. Safe to re-run.

ALTER TABLE public.owner_dashboard_layout
  ADD COLUMN IF NOT EXISTS panel_labels jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.owner_dashboard_layout.panel_labels IS
  'Owner-only display names for dashboard tiles: { "panel_id": "My label" }. Not shared globally.';
