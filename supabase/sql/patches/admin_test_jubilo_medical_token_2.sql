-- =============================================================================
-- Test: Jubilo (JUB) — specialist consult chips + prize medical (−2)
--
-- Medical Room "0 / 20" chips = club_medical_centre.specialist_tokens
-- Rewards "Medical −2"        = club_prize_inventory medical_token
-- These are separate inventories.
--
-- Run in Supabase SQL Editor.
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

SELECT 'specialist_vault' AS kind,
       c.club_short_name,
       c.specialist_tokens AS qty,
       NULL::bigint AS inventory_id,
       NULL::int AS param_int,
       NULL::text AS status
FROM public.club_medical_centre c
WHERE c.club_short_name = 'JUB'

UNION ALL

SELECT 'prize_medical',
       i.club_short_name,
       1,
       i.id,
       i.param_int,
       i.status
FROM public.club_prize_inventory i
WHERE i.club_short_name = 'JUB'
  AND i.prize_type = 'medical_token'
  AND i.status = 'available'
ORDER BY 1, 4 NULLS FIRST;
