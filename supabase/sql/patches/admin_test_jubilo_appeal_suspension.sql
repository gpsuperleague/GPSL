-- =============================================================================
-- Test: Jubilo (JUB) — 1 red-card appeal token + 1 active red suspension
-- Run once in Supabase SQL Editor. Safe to re-run (skips if already present).
-- =============================================================================

DO $$
DECLARE
  v_season bigint;
  v_club text := 'JUB';
  v_player_id text;
  v_player_name text;
  v_appeal_id bigint;
  v_susp_id bigint;
  v_seq int := 0;
  v_fx record;
  v_existing_appeal bigint;
  v_existing_susp bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RAISE EXCEPTION 'Club % not found', v_club;
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  -- 1) Appeal card (available) if none already available
  SELECT i.id INTO v_existing_appeal
  FROM public.club_prize_inventory i
  WHERE i.club_short_name = v_club
    AND i.prize_type = 'appeal_card'
    AND i.status = 'available'
  ORDER BY i.id
  LIMIT 1;

  IF v_existing_appeal IS NULL THEN
    v_appeal_id := public.prize_grant_inventory_item(
      v_club,
      'appeal_card',
      NULL,
      'admin_test',
      v_season,
      NULL,
      jsonb_build_object('note', 'Test appeal card for Jubilo')
    );
    RAISE NOTICE 'Granted appeal_card id=% to %', v_appeal_id, v_club;
  ELSE
    v_appeal_id := v_existing_appeal;
    RAISE NOTICE 'JUB already has available appeal_card id=%', v_appeal_id;
  END IF;

  -- Prefer a player who is not already on an active suspension
  SELECT p."Konami_ID"::text, p."Name"
  INTO v_player_id, v_player_name
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_player_suspensions s
      WHERE s.player_id = p."Konami_ID"::text
        AND s.season_id = v_season
        AND s.status = 'active'
    )
  ORDER BY p."Name"
  LIMIT 1;

  IF v_player_id IS NULL THEN
    -- Fallback: any contracted player
    SELECT p."Konami_ID"::text, p."Name"
    INTO v_player_id, v_player_name
    FROM public."Players" p
    WHERE p."Contracted_Team" = v_club
    ORDER BY p."Name"
    LIMIT 1;
  END IF;

  IF v_player_id IS NULL THEN
    RAISE EXCEPTION 'No players contracted to %', v_club;
  END IF;

  SELECT s.id INTO v_existing_susp
  FROM public.competition_player_suspensions s
  WHERE s.club_short_name = v_club
    AND s.player_id = v_player_id
    AND s.season_id = v_season
    AND s.status = 'active'
    AND s.reason = 'red_card'
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_existing_susp IS NOT NULL THEN
    v_susp_id := v_existing_susp;
    RAISE NOTICE 'Active red suspension already exists id=% for % (%)',
      v_susp_id, v_player_name, v_player_id;
  ELSE
    INSERT INTO public.competition_player_suspensions (
      season_id, player_id, club_short_name, reason,
      source_fixture_id, ban_matches, status
    )
    VALUES (
      v_season, v_player_id, v_club, 'red_card',
      NULL, 2, 'active'
    )
    RETURNING id INTO v_susp_id;

    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season
        AND f.status = 'scheduled'
        AND (f.home_club_short_name = v_club OR f.away_club_short_name = v_club)
      ORDER BY coalesce(f.matchday, 9999), f.id
      LIMIT 2
    LOOP
      v_seq := v_seq + 1;
      INSERT INTO public.competition_player_suspension_matches (
        suspension_id, fixture_id, sequence_no, served
      ) VALUES (v_susp_id, v_fx.id, v_seq, false)
      ON CONFLICT DO NOTHING;
    END LOOP;

    RAISE NOTICE 'Created red suspension id=% for % (%) — % ban fixture(s) linked',
      v_susp_id, v_player_name, v_player_id, v_seq;
  END IF;

  RAISE NOTICE 'Done. JUB appeal_card=% suspension=% player=% (%)',
    v_appeal_id, v_susp_id, v_player_name, v_player_id;
END $$;

-- Confirm
SELECT
  'appeal' AS kind,
  i.id,
  i.club_short_name,
  i.prize_type,
  i.status,
  i.source,
  NULL::text AS player_name,
  NULL::bigint AS suspension_id
FROM public.club_prize_inventory i
WHERE i.club_short_name = 'JUB'
  AND i.prize_type = 'appeal_card'
  AND i.status = 'available'

UNION ALL

SELECT
  'suspension',
  s.id,
  s.club_short_name,
  s.reason,
  s.status,
  s.player_id,
  p."Name",
  s.id
FROM public.competition_player_suspensions s
LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.player_id
WHERE s.club_short_name = 'JUB'
  AND s.status = 'active'
ORDER BY 1, 2;
