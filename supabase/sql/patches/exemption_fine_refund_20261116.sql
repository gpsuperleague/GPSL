-- Refund league fines that belong to the exemption period.
-- Fines switched on at the October lock (2026-11-12 19:00 UTC).
-- Removed: that lock's strikes, plus video/result fines for August–October matches.
-- Kept: replies and check-ins whose deadline fell after the switch, including catch-up.

DO $refund$
DECLARE
  v_live timestamptz;
  v_n int;
  v_total numeric;
  v_bad int;
  v_row record;
  v_voided int := 0;
  v_pts int := 0;
BEGIN
  SELECT auto_fines_live_from INTO v_live
  FROM public.global_settings
  WHERE id = 1;

  IF v_live IS DISTINCT FROM '2026-11-12 19:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'auto_fines_live_from is %, expected 2026-11-12 19:00 UTC', v_live;
  END IF;

  CREATE TEMP TABLE exemption_fines ON COMMIT DROP AS
  SELECT
    a.id,
    a.season_id,
    a.club_short_name,
    a.amount,
    a.ledger_id,
    a.fixture_id,
    a.tariff_code,
    a.note,
    a.applied_at
  FROM public.competition_fine_applied a
  LEFT JOIN public.competition_fixtures f ON f.id = a.fixture_id
  WHERE coalesce(a.waived, false) = false
    AND a.direction = 'fine'
    AND (
      a.applied_at <= v_live + interval '2 seconds'
      OR (
        a.tariff_code IN ('match_video_missing', 'match_result_late')
        AND coalesce(f.gpsl_month, '') IN ('august', 'september', 'october', 'preseason', 'july')
      )
    );

  SELECT count(*), coalesce(sum(amount), 0) INTO v_n, v_total
  FROM exemption_fines;

  IF v_n <> 42 OR v_total <> 21500000 THEN
    RAISE EXCEPTION 'Expected 42 fines totalling 21500000, found % totalling %', v_n, v_total;
  END IF;

  SELECT count(*) INTO v_bad
  FROM exemption_fines e
  JOIN public.competition_finance_ledger l ON l.id = e.ledger_id
  WHERE l.amount <> -e.amount
     OR l.club_short_name IS DISTINCT FROM e.club_short_name
     OR l.entry_type IS DISTINCT FROM 'gov_fine_compensation';

  IF v_bad <> 0 THEN
    RAISE EXCEPTION '% ledger rows do not match the fine', v_bad;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.bank_ledger b
    JOIN exemption_fines e ON b.club_ledger_id = e.ledger_id
    JOIN public.competition_finance_ledger l ON l.id = e.ledger_id
    WHERE b.amount IS DISTINCT FROM -l.amount
  ) THEN
    RAISE EXCEPTION 'A bank leg does not match the club fine';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.match_video_strike_escalations esc
    JOIN public.fixture_match_video_failures v ON v.id = esc.third_failure_id
    JOIN exemption_fines e ON e.id = v.fine_applied_id
  ) THEN
    RAISE EXCEPTION 'An exemption video failure is a 3-strike points escalation';
  END IF;

  FOR v_row IN
    SELECT club_short_name, sum(amount) AS refund
    FROM exemption_fines
    GROUP BY club_short_name
  LOOP
    PERFORM public.competition_credit_club_balance(v_row.club_short_name, v_row.refund);
  END LOOP;

  FOR v_row IN
    SELECT v.club_short_name, v.season_id, v.pts_adjustment_id
    FROM public.fixture_match_video_failures v
    JOIN exemption_fines e ON e.id = v.fine_applied_id
    WHERE v.pts_adjustment_id IS NOT NULL
  LOOP
    PERFORM public.match_video_apply_league_points(
      v_row.club_short_name,
      1::smallint,
      'Match video — exemption period, point restored',
      v_row.season_id
    );
    v_pts := v_pts + 1;
  END LOOP;

  UPDATE public.fixture_match_video_failures v
  SET pts_status = 'cleared',
      pts_cleared_at = coalesce(v.pts_cleared_at, now()),
      ledger_id = NULL
  FROM exemption_fines e
  WHERE v.fine_applied_id = e.id
    AND v.pts_status IS DISTINCT FROM 'cleared';

  UPDATE public.fixture_match_video_failures v
  SET ledger_id = NULL
  FROM exemption_fines e
  WHERE v.fine_applied_id = e.id
    AND v.ledger_id IS NOT NULL;

  UPDATE public.competition_fixture_reply_strikes r
  SET ease_in_void = true
  FROM exemption_fines e
  WHERE e.note = 'Missed reply'
    AND r.fixture_id = e.fixture_id
    AND r.club_short_name = e.club_short_name
    AND r.created_at BETWEEN e.applied_at - interval '5 seconds' AND e.applied_at + interval '5 seconds'
    AND NOT coalesce(r.ease_in_void, false);
  GET DIAGNOSTICS v_voided = ROW_COUNT;

  UPDATE public.competition_fixture_proposal_strikes s
  SET ease_in_void = true
  FROM exemption_fines e
  WHERE e.note = 'No home proposal'
    AND s.fixture_id = e.fixture_id
    AND s.club_short_name = e.club_short_name
    AND s.created_at BETWEEN e.applied_at - interval '5 seconds' AND e.applied_at + interval '5 seconds'
    AND NOT coalesce(s.ease_in_void, false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_voided := v_voided + v_n;

  UPDATE public.competition_owner_season_strikes os
  SET strike_count = greatest(0, os.strike_count - x.n),
      updated_at = now()
  FROM (
    SELECT c.owner_id, struck.season_id, count(*)::int AS n
    FROM (
      SELECT r.club_short_name, e.season_id
      FROM public.competition_fixture_reply_strikes r
      JOIN exemption_fines e
        ON e.note = 'Missed reply'
       AND r.fixture_id = e.fixture_id
       AND r.club_short_name = e.club_short_name
       AND r.created_at BETWEEN e.applied_at - interval '5 seconds' AND e.applied_at + interval '5 seconds'
      WHERE r.ease_in_void
      UNION ALL
      SELECT s.club_short_name, e.season_id
      FROM public.competition_fixture_proposal_strikes s
      JOIN exemption_fines e
        ON e.note = 'No home proposal'
       AND s.fixture_id = e.fixture_id
       AND s.club_short_name = e.club_short_name
       AND s.created_at BETWEEN e.applied_at - interval '5 seconds' AND e.applied_at + interval '5 seconds'
      WHERE s.ease_in_void
    ) struck
    JOIN public."Clubs" c ON c."ShortName" = struck.club_short_name
    WHERE c.owner_id IS NOT NULL
    GROUP BY c.owner_id, struck.season_id
  ) x
  WHERE os.owner_id = x.owner_id
    AND os.season_id = x.season_id;

  UPDATE public.competition_fine_applied a
  SET waived = true,
      ledger_id = NULL,
      note = concat_ws(
        E'\n',
        nullif(btrim(coalesce(a.note, '')), ''),
        'Exemption period — refunded 2026-11-16'
      )
  FROM exemption_fines e
  WHERE a.id = e.id;

  UPDATE public.gpsl_bank_account
  SET reserves = reserves - coalesce((
        SELECT sum(b.amount)
        FROM public.bank_ledger b
        JOIN exemption_fines e ON b.club_ledger_id = e.ledger_id
      ), 0),
      updated_at = now()
  WHERE id = 1;

  DELETE FROM public.bank_ledger b
  USING exemption_fines e
  WHERE b.club_ledger_id = e.ledger_id;

  DELETE FROM public.competition_finance_ledger l
  USING exemption_fines e
  WHERE l.id = e.ledger_id;

  IF v_pts <> 1 THEN
    RAISE EXCEPTION 'Expected to restore 1 league point, restored %', v_pts;
  END IF;

  IF v_voided < 1 THEN
    RAISE EXCEPTION 'No strikes were voided';
  END IF;
END;
$refund$;

SELECT
  a.club_short_name AS club,
  count(*) AS fines_refunded,
  sum(a.amount) AS refunded
FROM public.competition_fine_applied a
WHERE a.waived
  AND a.note LIKE '%Exemption period — refunded 2026-11-16%'
GROUP BY a.club_short_name
ORDER BY a.club_short_name;
