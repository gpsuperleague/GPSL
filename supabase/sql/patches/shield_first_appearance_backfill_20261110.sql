-- Shield ₿10m for every league club that took part in the preliminary
-- round or the Last 32. Owned and unowned. Knocked out or still in.
--
-- One payment per club, on their earliest played match in those two rounds.
-- A club that already has a Shield appearance payment, or any other Shield
-- prize of ₿10m, is left alone.
-- A club with no finance row gets an empty balance first, then the ₿10m.
-- Safe to re-run.

DO $pay$
DECLARE
  v_season bigint;
  v_amt numeric := 10000000;
  r record;
  v_ok boolean;
  v_n integer := 0;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  IF to_regprocedure('public.competition_cup_credit_round_prize(bigint,text,text,numeric,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'competition_cup_credit_round_prize is missing';
  END IF;

  FOR r IN
    SELECT DISTINCT ON (c."ShortName")
      c."ShortName" AS club,
      f.id AS fixture_id,
      sch.round_label
    FROM public."Clubs" c
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = c."ShortName"
     AND ccs.season_id = v_season
     AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    JOIN public.competition_fixtures f
      ON f.season_id = v_season
     AND f.competition_type = 'cup'
     AND lower(btrim(f.cup_code)) = 'shield'
     AND f.status = 'played'
     AND coalesce(f.is_void, false) = false
     AND c."ShortName" IN (f.home_club_short_name, f.away_club_short_name)
    JOIN public.competition_cup_season_schedule sch
      ON sch.season_id = v_season
     AND sch.cup_code = 'shield'
     AND sch.round_no = f.cup_round
     AND sch.round_label IN ('Preliminary round', 'Last 32')
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.competition_cup_prize_paid p
        JOIN public.competition_fixtures pf ON pf.id = p.fixture_id
        WHERE pf.season_id = v_season
          AND lower(btrim(pf.cup_code)) = 'shield'
          AND p.club_short_name = c."ShortName"
          AND (
            p.stage = 'appearance'
            OR p.amount = 10000000
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger l
        JOIN public.competition_fixtures lf ON lf.id = l.fixture_id
        WHERE lf.season_id = v_season
          AND lower(btrim(lf.cup_code)) = 'shield'
          AND l.club_short_name = c."ShortName"
          AND l.entry_type IN ('prize_cup', 'prize')
          AND (
            coalesce(l.metadata->>'stage', '') = 'appearance'
            OR l.amount = 10000000
          )
      )
    ORDER BY
      c."ShortName",
      public.competition_gpsl_month_sort(f.gpsl_month),
      f.cup_round,
      f.id
  LOOP
    INSERT INTO public."Club_Finances" (club_name, balance)
    SELECT r.club, 0
    WHERE NOT EXISTS (
      SELECT 1 FROM public."Club_Finances" cf WHERE cf.club_name = r.club
    );

    v_ok := public.competition_cup_credit_round_prize(
      r.fixture_id,
      r.club,
      'appearance',
      v_amt,
      'SHIELD appearance — ' || r.round_label,
      jsonb_build_object(
        'cup_code', 'shield',
        'stage', 'appearance',
        'round', r.round_label,
        'reason', 'shield_entry_backfill'
      )
    );
    IF v_ok THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'Shield ₿10m paid to % league club(s) for the preliminary round or Last 32.', v_n;
END;
$pay$;

SELECT
  p.club_short_name,
  c.owner_id IS NULL AS unowned,
  f.id AS fixture_id,
  f.gpsl_month,
  sch.round_label,
  f.home_club_short_name,
  f.away_club_short_name,
  p.amount
FROM public.competition_cup_prize_paid p
JOIN public.competition_fixtures f ON f.id = p.fixture_id
JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current = true
JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
LEFT JOIN public.competition_cup_season_schedule sch
  ON sch.season_id = f.season_id
 AND sch.cup_code = 'shield'
 AND sch.round_no = f.cup_round
WHERE lower(btrim(f.cup_code)) = 'shield'
  AND p.stage = 'appearance'
  AND coalesce(p.amount, 0) = 10000000
ORDER BY p.club_short_name;
