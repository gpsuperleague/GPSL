-- Reveal draft_random_finish_time in global_settings_public only AFTER bidding has closed.
-- Safe re-run after repair_global_settings_public.sql

DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  manager_draft_auction_enabled,
  draft_auction_start_time,
  updated_at,
  (
    COALESCE(draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS draft_bidding_open,
  (
    COALESCE(manager_draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS manager_draft_bidding_open,
  CASE
    WHEN draft_random_finish_time IS NOT NULL
     AND now() >= draft_random_finish_time
    THEN draft_random_finish_time
    ELSE NULL
  END AS draft_random_finish_revealed
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

NOTIFY pgrst, 'reload schema';
