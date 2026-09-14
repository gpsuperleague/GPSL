-- =============================================================================
-- Match video missing-upload grace: 48h → 72h (2026-09-14)
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_discord_match_videos_settings
  ALTER COLUMN missing_fine_grace_hours SET DEFAULT 72;

UPDATE public.gpsl_discord_match_videos_settings
SET
  missing_fine_grace_hours = 72,
  updated_at = now()
WHERE id = 1
  AND missing_fine_grace_hours = 48;

CREATE OR REPLACE FUNCTION public.match_video_missing_fine_grace_hours()
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v int;
BEGIN
  SELECT s.missing_fine_grace_hours INTO v
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;
  RETURN greatest(1, coalesce(v, 72));
END;
$function$;

COMMENT ON COLUMN public.gpsl_discord_match_videos_settings.missing_fine_grace_hours IS
  'Hours after GPSL month lock_at before a missing video is fined / points suspended. Default 72.';

NOTIFY pgrst, 'reload schema';
