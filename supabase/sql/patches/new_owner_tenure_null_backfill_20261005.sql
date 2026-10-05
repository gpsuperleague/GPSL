-- =============================================================================
-- New Owner first-season slots — NULL tenure backfill + auto-stamp on season
-- =============================================================================
-- Symptom: no "New Owner release / transfer list" options for any owner.
-- Cause: owners were linked while no competition season was current, so the
-- tenure trigger stamped owner_assigned_season_id = NULL. Eligibility requires
-- owner_assigned_season_id = current season id.
-- Fix:
--   1) Stamp every owned club with NULL tenure to the current season (slots kept).
--   2) Whenever a season becomes current, stamp owned clubs that still have
--      NULL tenure (owners linked before any season existed).
-- =============================================================================

UPDATE public."Clubs" c
SET owner_assigned_season_id = s.id,
    new_owner_releases_remaining = CASE
      WHEN c.new_owner_releases_remaining IS NULL THEN 3
      ELSE c.new_owner_releases_remaining
    END
FROM (
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
) s
WHERE c.owner_id IS NOT NULL
  AND c."ShortName" <> 'FOREIGN'
  AND c.owner_assigned_season_id IS NULL;

CREATE OR REPLACE FUNCTION public.trg_competition_seasons_stamp_null_owner_tenure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(NEW.is_current, false) IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  UPDATE public."Clubs" c
  SET owner_assigned_season_id = NEW.id,
      new_owner_releases_remaining = coalesce(c.new_owner_releases_remaining, 3)
  WHERE c.owner_id IS NOT NULL
    AND c."ShortName" <> 'FOREIGN'
    AND c.owner_assigned_season_id IS NULL;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS competition_seasons_stamp_null_owner_tenure ON public.competition_seasons;
CREATE TRIGGER competition_seasons_stamp_null_owner_tenure
  AFTER INSERT OR UPDATE OF is_current ON public.competition_seasons
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_competition_seasons_stamp_null_owner_tenure();

NOTIFY pgrst, 'reload schema';

SELECT c."ShortName", c.owner, c.owner_assigned_season_id, c.new_owner_releases_remaining,
       public.club_is_new_owner_release_eligible(c."ShortName") AS eligible
FROM public."Clubs" c
WHERE c.owner_id IS NOT NULL
ORDER BY c."ShortName";
