-- Match video payout: ₿200,000 per successfully registered upload.
-- Top up every still-registered video that was credited exactly ₿100,000.
-- Idempotent. Pending (not yet credited) videos pick up ₿200,000 when they register.
-- Safe re-run.

CREATE TEMP TABLE IF NOT EXISTS _video_topup_rows (
  club text,
  video_id bigint,
  fixture_id bigint,
  amount numeric
);

TRUNCATE _video_topup_rows;

DO $topup$
DECLARE
  v_vid public.fixture_match_videos%ROWTYPE;
  v_net numeric;
  v_skipped int := 0;
BEGIN
  UPDATE public.gpsl_discord_match_videos_settings
  SET payout_amount = 200000,
      updated_at = now()
  WHERE id = 1;

  FOR v_vid IN
    SELECT v.*
    FROM public.fixture_match_videos v
    WHERE v.credited_amount = 100000
    ORDER BY v.id
    FOR UPDATE
  LOOP
    SELECT coalesce(sum(l.amount), 0)
    INTO v_net
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_vid.fixture_id
      AND upper(l.club_short_name) = upper(v_vid.club_short_name)
      AND l.entry_type = 'gate_match_video'
      AND coalesce(l.metadata->>'backpay', '') <> 'video_payout_200k';

    IF v_net IS DISTINCT FROM 100000 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    PERFORM public.competition_credit_club_balance(v_vid.club_short_name, 100000);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    ) VALUES (
      v_vid.season_id,
      v_vid.fixture_id,
      v_vid.club_short_name,
      'gate_match_video',
      100000,
      'Match video upload top-up — ₿100,000 to ₿200,000',
      jsonb_build_object(
        'backpay', 'video_payout_200k',
        'fixture_match_video_id', v_vid.id,
        'previous_amount', 100000,
        'side', v_vid.side
      )
    );

    UPDATE public.fixture_match_videos
    SET credited_amount = 200000,
        updated_at = now()
    WHERE id = v_vid.id;

    INSERT INTO _video_topup_rows (club, video_id, fixture_id, amount)
    VALUES (v_vid.club_short_name, v_vid.id, v_vid.fixture_id, 100000);
  END LOOP;
END;
$topup$;

SELECT jsonb_build_object(
  'payout_amount', (
    SELECT s.payout_amount
    FROM public.gpsl_discord_match_videos_settings s
    WHERE s.id = 1
  ),
  'videos_topped_up', (SELECT count(*) FROM _video_topup_rows),
  'clubs', (SELECT count(DISTINCT club) FROM _video_topup_rows),
  'total', (SELECT coalesce(sum(amount), 0) FROM _video_topup_rows),
  'still_on_100k', (
    SELECT count(*) FROM public.fixture_match_videos WHERE credited_amount = 100000
  ),
  'now_on_200k', (
    SELECT count(*) FROM public.fixture_match_videos WHERE credited_amount = 200000
  ),
  'pending_unpaid', (
    SELECT count(*) FROM public.fixture_match_video_pending
  ),
  'by_club', (
    SELECT coalesce(jsonb_agg(
      jsonb_build_object('club', club, 'videos', n, 'topup', topup)
      ORDER BY club
    ), '[]'::jsonb)
    FROM (
      SELECT club, count(*) AS n, sum(amount) AS topup
      FROM _video_topup_rows
      GROUP BY club
    ) c
  )
) AS report;
