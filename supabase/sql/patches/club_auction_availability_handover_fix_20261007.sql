-- Club auction winners: copy onboarding availability onto the club.
--
-- Onboarding slots live in gpsl_owner_registry_availability_slot (per owner).
-- admin_club_season_checklist counts club_owner_availability_slot (per club +
-- season). The copy (owner_onboarding_apply_availability_to_club) was dropped
-- when transferengine_accept_club_auction_sale was rewritten (stadium charge /
-- SOA settle fix), and it also skipped any season not in status 'active'.
--
-- Fix:
--   1. Copy function picks the same current season as the checklist and never
--      wipes club slots when the registry is empty.
--   2. Trigger on Clubs.owner_id so every assignment path (auction, admin,
--      swap) hands availability over without touching the settle function.
--   3. Backfill owned clubs that have registry slots but no club slots.
--   4. Check result for the latest three auction winners.

CREATE OR REPLACE FUNCTION public.owner_onboarding_apply_availability_to_club(
  p_owner_id uuid,
  p_club_short_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_tz text;
  v_season_id bigint;
  v_registry_slots int;
BEGIN
  IF p_owner_id IS NULL OR v_club IS NULL OR v_club = '' THEN
    RETURN;
  END IF;

  SELECT nullif(btrim(coalesce(r.owner_timezone, '')), '')
  INTO v_tz
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  IF v_tz IS NOT NULL THEN
    UPDATE public."Clubs"
    SET owner_timezone = v_tz
    WHERE "ShortName" = v_club
      AND owner_id = p_owner_id
      AND owner_timezone IS DISTINCT FROM v_tz;
  END IF;

  SELECT count(*)::int INTO v_registry_slots
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = p_owner_id;

  IF coalesce(v_registry_slots, 0) = 0 THEN
    RETURN;
  END IF;

  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY
    CASE status
      WHEN 'active' THEN 0
      WHEN 'preseason' THEN 1
      WHEN 'summer_break' THEN 2
      WHEN 'setup' THEN 3
      ELSE 4
    END,
    id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.club_owner_availability_slot
  WHERE season_id = v_season_id
    AND club_short_name = v_club;

  INSERT INTO public.club_owner_availability_slot (
    season_id, club_short_name, owner_id, iso_dow, slot_minute
  )
  SELECT
    v_season_id,
    v_club,
    p_owner_id,
    s.iso_dow,
    s.slot_minute
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = p_owner_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.clubs_owner_assigned_apply_availability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.owner_id IS NOT NULL
     AND NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    BEGIN
      PERFORM public.owner_onboarding_apply_availability_to_club(
        NEW.owner_id,
        NEW."ShortName"
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Availability handover failed for % (%): %',
        NEW."ShortName", NEW.owner_id, SQLERRM;
    END;
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_owner_assigned_apply_availability ON public."Clubs";
CREATE TRIGGER clubs_owner_assigned_apply_availability
AFTER UPDATE OF owner_id ON public."Clubs"
FOR EACH ROW
EXECUTE FUNCTION public.clubs_owner_assigned_apply_availability();

-- Backfill: owned clubs with registry slots but none on the club this season
DO $$
DECLARE
  v_season_id bigint;
  v_row record;
BEGIN
  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY
    CASE status
      WHEN 'active' THEN 0
      WHEN 'preseason' THEN 1
      WHEN 'summer_break' THEN 2
      WHEN 'setup' THEN 3
      ELSE 4
    END,
    id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE NOTICE 'No current season — backfill skipped';
    RETURN;
  END IF;

  FOR v_row IN
    SELECT c."ShortName" AS club, c.owner_id
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND NOT EXISTS (
        SELECT 1 FROM public.club_owner_availability_slot cs
        WHERE cs.season_id = v_season_id
          AND cs.club_short_name = c."ShortName"
      )
      AND EXISTS (
        SELECT 1 FROM public.gpsl_owner_registry_availability_slot rs
        WHERE rs.owner_id = c.owner_id
      )
  LOOP
    PERFORM public.owner_onboarding_apply_availability_to_club(
      v_row.owner_id,
      v_row.club
    );
    RAISE NOTICE 'Backfilled availability for %', v_row.club;
  END LOOP;
END;
$$;

-- Check: latest three auction winners — registry vs club slot counts
WITH cur AS (
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY
    CASE status
      WHEN 'active' THEN 0
      WHEN 'preseason' THEN 1
      WHEN 'summer_break' THEN 2
      WHEN 'setup' THEN 3
      ELSE 4
    END,
    id DESC
  LIMIT 1
)
SELECT
  public.owner_registry_resolve_tag(c.owner_id) AS owner,
  c."ShortName" AS club,
  (SELECT count(*) FROM public.gpsl_owner_registry_availability_slot rs
    WHERE rs.owner_id = c.owner_id) AS onboarding_slots,
  (SELECT count(*) FROM public.club_owner_availability_slot cs, cur
    WHERE cs.season_id = cur.id AND cs.club_short_name = c."ShortName") AS club_slots,
  c.owner_timezone
FROM public."Clubs" c
WHERE c.owner_id IS NOT NULL
  AND (
    public.owner_registry_resolve_tag(c.owner_id) ILIKE ANY (ARRAY['%elmurat%', '%bokirca%', '%apocalips3%'])
    OR c.owner ILIKE ANY (ARRAY['%elmurat%', '%bokirca%', '%apocalips3%'])
  )
ORDER BY 1;
