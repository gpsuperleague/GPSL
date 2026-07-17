-- =============================================================================
-- Test: Jubilo (JUB) — grant one medical token (−2 matches)
-- Run in Supabase SQL Editor. Safe re-run (adds another available token).
-- =============================================================================

DO $$
DECLARE
  v_season bigint;
  v_club text := 'JUB';
  v_id bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RAISE EXCEPTION 'Club % not found', v_club;
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF to_regprocedure('public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'prize_grant_inventory_item missing — run competition_challenge_prize_packs SQL';
  END IF;

  v_id := public.prize_grant_inventory_item(
    v_club,
    'medical_token',
    2,
    'admin_test',
    v_season,
    NULL,
    jsonb_build_object('note', 'Test medical token −2 for Jubilo', 'matches_removed', 2)
  );

  RAISE NOTICE 'Granted medical_token id=% (−2) to %', v_id, v_club;
END $$;

SELECT
  i.id,
  i.club_short_name,
  i.prize_type,
  i.param_int AS matches_removed,
  i.status,
  i.source,
  i.created_at
FROM public.club_prize_inventory i
WHERE i.club_short_name = 'JUB'
  AND i.prize_type = 'medical_token'
  AND i.status = 'available'
ORDER BY i.id DESC;
