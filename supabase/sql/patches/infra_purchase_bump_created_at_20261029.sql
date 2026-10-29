-- =============================================================================
-- Make assignment stadium buys visible again (works with old Season accounts JS)
--
-- JUB (and peers): club_assignment_finance_display says ledger_posted=true,
-- total_debit=23m, continuing=false, show_in_accounts=false. Old UI loads only
-- the newest ledger rows then refuses to synthesize when ledger_posted — so
-- Infrastructure purchases shows ₿0 while cash is correct.
--
-- 1) Diagnose raw vs public for JUB
-- 2) Fix any current-club infra_purchase stuck on a non-current season_id
-- 3) Bump created_at so rows re-enter the recent-ledger window
-- Idempotent. No Club_Finances changes.
-- =============================================================================

-- 1) JUB raw vs public
SELECT 'raw' AS src, l.id, l.season_id, s.is_current, l.amount, l.created_at,
       l.metadata->>'source' AS source, left(l.description, 120) AS description
FROM public.competition_finance_ledger l
LEFT JOIN public.competition_seasons s ON s.id = l.season_id
WHERE l.club_short_name = 'JUB' AND l.entry_type = 'infra_purchase'
UNION ALL
SELECT 'public', p.id, p.season_id, true, p.amount, p.created_at,
       p.metadata->>'source', left(p.description, 120)
FROM public.competition_finance_ledger_public p
WHERE p.club_short_name = 'JUB' AND p.entry_type = 'infra_purchase';

-- 2) Remap infra_purchase onto current season when the club has no current-season row
DO $fix_season$
DECLARE
  v_sid bigint;
  v_n int := 0;
BEGIN
  SELECT id INTO v_sid
  FROM public.competition_seasons
  WHERE is_current
  ORDER BY id DESC
  LIMIT 1;

  IF v_sid IS NULL THEN
    RAISE NOTICE 'No current season';
    RETURN;
  END IF;

  WITH ranked AS (
    SELECT
      l.id,
      l.club_short_name,
      row_number() OVER (
        PARTITION BY l.club_short_name
        ORDER BY l.created_at ASC, l.id ASC
      ) AS rn
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'infra_purchase'
      AND l.season_id IS DISTINCT FROM v_sid
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger x
        WHERE x.club_short_name = l.club_short_name
          AND x.entry_type = 'infra_purchase'
          AND x.season_id = v_sid
      )
  )
  UPDATE public.competition_finance_ledger l
  SET season_id = v_sid
  FROM ranked r
  WHERE l.id = r.id
    AND r.rn = 1;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'Remapped % infra_purchase row(s) onto season %', v_n, v_sid;
END;
$fix_season$;

-- 3) Bump created_at for current-season assignment stadium buys (newest first in UI load)
DO $bump$
DECLARE
  v_sid bigint;
  v_n int := 0;
BEGIN
  SELECT id INTO v_sid
  FROM public.competition_seasons
  WHERE is_current
  ORDER BY id DESC
  LIMIT 1;

  IF v_sid IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.competition_finance_ledger l
  SET created_at = now()
  WHERE l.season_id = v_sid
    AND l.entry_type = 'infra_purchase'
    AND coalesce(l.metadata->>'source', 'club_assignment') IN (
      'club_assignment',
      'club_auction',
      'assignment',
      'admin_assign',
      'display_restore',
      ''
    )
    AND l.created_at < now() - interval '1 minute';

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'Bumped created_at on % current-season infra_purchase row(s)', v_n;
END;
$bump$;

-- 4) Recheck JUB
SELECT 'raw' AS src, l.id, l.season_id, s.is_current, l.amount, l.created_at,
       l.metadata->>'source' AS source
FROM public.competition_finance_ledger l
LEFT JOIN public.competition_seasons s ON s.id = l.season_id
WHERE l.club_short_name = 'JUB' AND l.entry_type = 'infra_purchase'
UNION ALL
SELECT 'public', p.id, p.season_id, true, p.amount, p.created_at,
       p.metadata->>'source'
FROM public.competition_finance_ledger_public p
WHERE p.club_short_name = 'JUB' AND p.entry_type = 'infra_purchase';
