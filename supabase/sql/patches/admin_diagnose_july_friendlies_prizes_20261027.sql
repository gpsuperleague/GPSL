-- =============================================================================
-- Diagnose + catch-up: July friendlies table prizes
--
-- June shows 🏆 winners above the table because rows exist in
-- gpsl_friendlies_prize_payouts. If July has no banner, prizes were never paid.
--
-- Run as admin / SQL editor. Safe re-run (pay is idempotent per place).
-- =============================================================================

-- 1) Who already got paid (June vs July)
SELECT
  p.gpsl_month,
  p.place,
  p.club_short_name,
  p.amount,
  p.points,
  p.created_at
FROM public.gpsl_friendlies_prize_payouts p
WHERE p.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND p.gpsl_month IN ('june', 'july')
ORDER BY p.gpsl_month, p.place;

-- 2) Calendar: is July locked?
SELECT
  lower(btrim(cal.gpsl_month)) AS gpsl_month,
  cal.unlock_at,
  cal.lock_at,
  cal.lock_at <= now() AS is_locked
FROM public.competition_season_calendar cal
WHERE cal.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND lower(btrim(cal.gpsl_month)) IN ('june', 'july', 'august')
ORDER BY cal.unlock_at;

-- 3) Live July table top (who would win if paid now)
SELECT
  t.place,
  t.club,
  t.points,
  t.qualified,
  t.owner_id IS NOT NULL AS has_owner,
  t.counted,
  t.won,
  t.drawn,
  t.lost
FROM public.gpsl_friendlies_month_table_rows(
  (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
  'july'
) t
ORDER BY t.place
LIMIT 10;

-- 4) Month-lock wire still present?
SELECT
  (position('gpsl_friendlies_on_gpsl_month_lock' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0) AS friendlies_prizes_wired;

-- 5) PAY July now (admin catch-up — skip if July already has payout rows)
-- Uncomment after checking 1–3:
-- SELECT public.admin_gpsl_friendlies_pay_month_prizes('july');

-- 6) Confirm winners after pay
-- SELECT place, club_short_name, amount, points
-- FROM public.gpsl_friendlies_prize_payouts
-- WHERE season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
--   AND gpsl_month = 'july'
-- ORDER BY place;
