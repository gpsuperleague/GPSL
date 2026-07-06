-- Grouped dashboard tiles (Android-style sections with headers).
-- Run after owner_dashboard_layout.sql. Safe to re-run.

ALTER TABLE public.owner_dashboard_layout
  ADD COLUMN IF NOT EXISTS sections jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.owner_dashboard_layout.sections IS
  'Grouped dashboard layout: [{ "id", "title", "panelIds": [] }]. panel_ids stays in sync as a flat list.';
