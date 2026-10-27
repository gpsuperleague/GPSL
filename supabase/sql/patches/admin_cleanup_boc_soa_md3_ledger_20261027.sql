-- =============================================================================
-- Cleanup: fixture 8987 (BOC vs SOA MD3) leftover gate_match_video ledger rows
-- After reset, video clear left credit + reverse pairs (ledger_rows = 4).
-- Balances already net to zero — just delete the rows. Safe re-run.
-- =============================================================================

DO $$
DECLARE
  v_fid bigint := 8987;
  v_n int := 0;
  v_home text;
  v_away text;
  r record;
BEGIN
  SELECT home_club_short_name, away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures
  WHERE id = v_fid;

  IF v_home IS NULL THEN
    RAISE EXCEPTION 'Fixture % not found', v_fid;
  END IF;

  IF NOT (
    (upper(v_home) = 'BOC' AND upper(v_away) = 'SOA')
    OR (upper(v_home) = 'SOA' AND upper(v_away) = 'BOC')
  ) THEN
    RAISE EXCEPTION 'Fixture % is % vs % — expected BOC vs SOA', v_fid, v_home, v_away;
  END IF;

  -- Show what we are about to remove
  RAISE NOTICE 'Ledger before cleanup:';
  FOR r IN
    SELECT id, club_short_name, entry_type, amount, description
    FROM public.competition_finance_ledger
    WHERE fixture_id = v_fid
    ORDER BY id
  LOOP
    RAISE NOTICE '  #% % % % %',
      r.id, r.club_short_name, r.entry_type, r.amount, left(coalesce(r.description, ''), 60);
  END LOOP;

  -- Video rows: already balance-reversed by admin clear — delete only
  DELETE FROM public.competition_finance_ledger
  WHERE fixture_id = v_fid
    AND entry_type = 'gate_match_video';
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- Any other leftover types: reverse balance then delete
  FOR r IN
    SELECT id, club_short_name, amount
    FROM public.competition_finance_ledger
    WHERE fixture_id = v_fid
  LOOP
    IF to_regprocedure('public.competition_credit_club_balance(text, numeric)') IS NOT NULL THEN
      PERFORM public.competition_credit_club_balance(
        r.club_short_name,
        -coalesce(r.amount, 0)
      );
    END IF;
    DELETE FROM public.competition_finance_ledger WHERE id = r.id;
    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'Removed % ledger row(s) for fixture %', v_n, v_fid;
END;
$$;

SELECT
  f.id,
  f.status AS fixture_status,
  f.home_club_short_name,
  f.away_club_short_name,
  sch.status AS schedule_status,
  (SELECT count(*) FROM public.competition_finance_ledger l WHERE l.fixture_id = f.id) AS ledger_rows
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
WHERE f.id = 8987;
