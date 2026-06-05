-- =============================================================================
-- Repair duplicate Clubs.owner columns
-- Run once in Supabase SQL Editor if club_owner_tag.sql previously added "Owner".
-- Keeps existing lowercase owner; copies any data from "Owner" then drops "Owner".
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'Owner'
  ) THEN
    UPDATE public."Clubs"
    SET owner = COALESCE(owner, "Owner")
    WHERE "Owner" IS NOT NULL
      AND btrim("Owner") <> '';

    ALTER TABLE public."Clubs" DROP COLUMN "Owner";
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
