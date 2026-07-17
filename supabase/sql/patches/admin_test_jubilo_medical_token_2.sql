-- =============================================================================
-- Test: Jubilo (JUB) — specialist consult chips + prize medical (−2)
--
-- After medical_consultancy_identity.sql, each consult gets a random label like:
--   "Harley Medical Group - Specialist Consultant Helen Roberts"
--
-- Run in Supabase SQL Editor (after medical_consultancy_identity.sql).
-- =============================================================================

DO $$
DECLARE
  v_season bigint;
  v_club text := 'JUB';
  v_prize_id bigint;
  v_spec jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RAISE EXCEPTION 'Club % not found', v_club;
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  -- 1) Specialist consult chips in Medical Room vault (the 0/20 display)
  IF to_regprocedure('public.medical_grant_specialist_tokens(text,int)') IS NULL THEN
    RAISE EXCEPTION 'medical_grant_specialist_tokens missing — run club_medical_room.sql';
  END IF;

  v_spec := public.medical_grant_specialist_tokens(v_club, 2);
  RAISE NOTICE 'Specialist tokens for %: %', v_club, v_spec;

  -- 2) Prize medical token (−2) for Rewards / Medical / Squad apply
  IF to_regprocedure('public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)') IS NOT NULL THEN
    v_prize_id := public.prize_grant_inventory_item(
      v_club,
      'medical_token',
      2,
      'admin_test',
      v_season,
      NULL,
      jsonb_build_object('note', 'Test medical token −2 for Jubilo', 'matches_removed', 2)
    );
    RAISE NOTICE 'Prize medical_token id=% (−2) to %', v_prize_id, v_club;
  END IF;
END $$;

SELECT c.id AS consult_id,
       c.club_short_name,
       c.matches_removed,
       c.status,
       c.group_name,
       c.consultant_name,
       c.label,
       c.inventory_id,
       c.source
FROM public.club_medical_consults c
WHERE c.club_short_name = 'JUB'
  AND c.status = 'available'
ORDER BY c.matches_removed DESC, c.id;
