-- =============================================================================
-- Fixture-level breakdown for Season owner board F lock
-- (same rules as admin_owner_board_fine_forecast / auto arrangement+reply fines)
--
-- Run in Supabase SQL Editor while signed in as a role that can read fixtures
-- (service role / postgres). Admin RPC stays on the board; this is for audit.
-- Safe re-run (read-only SELECT).
-- =============================================================================

WITH season AS (
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
lock_m AS (
  SELECT c.gpsl_month, c.lock_at,
         public.competition_gpsl_month_sort(c.gpsl_month) AS lock_sort,
         public.competition_gpsl_month_label(c.gpsl_month) AS lock_label
  FROM public.competition_season_calendar c
  JOIN season s ON s.id = c.season_id
  WHERE c.lock_at IS NOT NULL
    AND c.lock_at > now() - interval '1 hour'
  ORDER BY c.lock_at
  LIMIT 1
),
tariffs AS (
  SELECT
    coalesce((SELECT amount FROM public.competition_fine_tariff WHERE code = 'match_mgmt_no_proposal'), 2500000) AS no_prop,
    coalesce((SELECT amount FROM public.competition_fine_tariff WHERE code = 'match_late_arrangement'), 1000000) AS late,
    coalesce((SELECT amount FROM public.competition_fine_tariff WHERE code = 'match_response_deadline'), 2500000) AS reply
),
arrangement AS (
  SELECT
    f.id AS fixture_id,
    upper(btrim(f.home_club_short_name)) AS club,
    upper(btrim(f.away_club_short_name)) AS opponent,
    f.gpsl_month AS play_month,
    f.matchday,
    f.competition_type,
    CASE
      WHEN EXISTS (
        SELECT 1 FROM public.competition_fixture_schedule s
        WHERE s.fixture_id = f.id AND s.status = 'agreed'
      ) THEN NULL
      WHEN to_regprocedure('public.club_scheduling_fines_in_new_owner_grace(bigint,text,text)') IS NOT NULL
        AND public.club_scheduling_fines_in_new_owner_grace(
              (SELECT id FROM season), f.home_club_short_name, (SELECT gpsl_month FROM lock_m)
            )
        THEN 'skipped_new_owner_grace'
      WHEN to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
        AND public.match_schedule_fixture_deadlines_suppressed_for_club(
              f.id, f.home_club_short_name
            )
        THEN 'skipped_opp_vacant_or_new_owner'
      WHEN to_regprocedure('public.match_schedule_club_on_holiday_for_month(bigint,text,text)') IS NOT NULL
        AND public.match_schedule_club_on_holiday_for_month(
              (SELECT id FROM season), f.home_club_short_name, (SELECT gpsl_month FROM lock_m)
            )
        THEN 'skipped_holiday'
      WHEN public.competition_gpsl_month_sort(f.gpsl_month) = (SELECT lock_sort FROM lock_m) + 1 THEN
        CASE
          WHEN public.match_schedule_home_first_proposal_at(f.id, now()) IS NULL
            THEN 'match_mgmt_no_proposal'
          WHEN cal_play.unlock_at IS NOT NULL
            AND public.match_schedule_home_first_proposal_at(f.id, now())
                >= cal_play.unlock_at - interval '48 hours'
            AND public.match_schedule_home_first_proposal_at(f.id, now())
                < cal_play.unlock_at
            THEN 'match_late_arrangement'
          ELSE NULL
        END
      WHEN public.competition_gpsl_month_sort(f.gpsl_month) <= (SELECT lock_sort FROM lock_m)
        AND public.match_schedule_home_first_proposal_at(f.id, now()) IS NULL
        THEN 'match_mgmt_no_proposal'
      ELSE NULL
    END AS tariff_or_skip,
    public.match_schedule_home_first_proposal_at(f.id, now()) AS first_home_proposal_at,
    cal_play.unlock_at AS play_unlock_at
  FROM public.competition_fixtures f
  JOIN season s ON s.id = f.season_id
  JOIN public."Clubs" c ON c."ShortName" = f.home_club_short_name
  JOIN public.competition_season_calendar cal_play
    ON cal_play.season_id = f.season_id
   AND cal_play.gpsl_month = f.gpsl_month
  CROSS JOIN lock_m
  WHERE f.status = 'scheduled'
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND public.competition_gpsl_month_sort(f.gpsl_month) <= lock_m.lock_sort + 1
    AND c.owner_id IS NOT NULL
),
replies AS (
  SELECT
    f.id AS fixture_id,
    upper(btrim(s.response_required_club_short_name)) AS club,
    CASE
      WHEN upper(btrim(s.response_required_club_short_name)) = upper(btrim(f.home_club_short_name))
        THEN upper(btrim(f.away_club_short_name))
      ELSE upper(btrim(f.home_club_short_name))
    END AS opponent,
    f.gpsl_month AS play_month,
    f.matchday,
    f.competition_type,
    CASE
      WHEN to_regprocedure('public.club_scheduling_fines_in_new_owner_grace(bigint,text,text)') IS NOT NULL
        AND public.club_scheduling_fines_in_new_owner_grace(
              (SELECT id FROM season), s.response_required_club_short_name, (SELECT gpsl_month FROM lock_m)
            )
        THEN 'skipped_new_owner_grace'
      WHEN to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
        AND public.match_schedule_fixture_deadlines_suppressed_for_club(
              f.id, s.response_required_club_short_name
            )
        THEN 'skipped_opp_vacant_or_new_owner'
      WHEN to_regprocedure('public.match_schedule_club_on_holiday_for_month(bigint,text,text)') IS NOT NULL
        AND public.match_schedule_club_on_holiday_for_month(
              (SELECT id FROM season), s.response_required_club_short_name, (SELECT gpsl_month FROM lock_m)
            )
        THEN 'skipped_holiday'
      WHEN s.response_deadline_warned_at IS NULL
        THEN 'reply_warn'
      WHEN s.response_deadline_warned_at < coalesce((SELECT lock_at FROM lock_m), now())
        THEN 'match_response_deadline'
      ELSE NULL
    END AS tariff_or_skip,
    s.response_due_at,
    s.response_deadline_warned_at
  FROM public.competition_fixture_schedule s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  JOIN season se ON se.id = f.season_id
  JOIN public."Clubs" c ON c."ShortName" = s.response_required_club_short_name
  CROSS JOIN lock_m
  WHERE f.status = 'scheduled'
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND s.status = 'negotiating'
    AND s.pending_proposal_id IS NOT NULL
    AND s.response_required_club_short_name IS NOT NULL
    AND s.response_due_at IS NOT NULL
    AND s.response_due_at < coalesce(lock_m.lock_at, now())
    AND (
      lower(btrim(f.gpsl_month)) = lower(btrim(lock_m.gpsl_month))
      OR (
        to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
        AND public.match_schedule_fixture_is_catch_up(f.id)
      )
    )
    AND c.owner_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.competition_fixture_schedule_proposal p
      WHERE p.id = s.pending_proposal_id AND p.status = 'pending'
    )
)
SELECT
  (SELECT lock_label FROM lock_m) AS next_lock_month,
  (SELECT lock_at FROM lock_m) AS next_lock_at,
  x.kind,
  x.club,
  x.opponent,
  x.fixture_id,
  x.play_month,
  x.matchday,
  x.competition_type,
  x.tariff_or_skip,
  CASE x.tariff_or_skip
    WHEN 'match_mgmt_no_proposal' THEN (SELECT no_prop FROM tariffs)
    WHEN 'match_late_arrangement' THEN (SELECT late FROM tariffs)
    WHEN 'match_response_deadline' THEN (SELECT reply FROM tariffs)
    ELSE 0
  END AS amount,
  CASE x.tariff_or_skip
    WHEN 'match_mgmt_no_proposal' THEN
      'Home never proposed a kick-off (₿2.5m Match Management) — next-month home or leftover unproposed'
    WHEN 'match_late_arrangement' THEN
      'Home first proposed only in the last 48h before play-month unlock (₿1m late arrangement)'
    WHEN 'match_response_deadline' THEN
      'Reply still overdue after a prior lock warning (₿2.5m)'
    WHEN 'reply_warn' THEN
      'Reply overdue at this lock — warning only this time (shows as “warn” on F lock, £0)'
    WHEN 'skipped_new_owner_grace' THEN
      'Skipped — club owner appointed after this lock month unlocked'
    WHEN 'skipped_opp_vacant_or_new_owner' THEN
      'Skipped — opponent vacant/absent or newly appointed in this fixture play month'
    WHEN 'skipped_holiday' THEN
      'Skipped — club on holiday for the closed month'
    ELSE x.tariff_or_skip
  END AS meaning,
  x.extra
FROM (
  SELECT
    'arrangement'::text AS kind,
    club, opponent, fixture_id, play_month, matchday, competition_type, tariff_or_skip,
    jsonb_build_object(
      'first_home_proposal_at', first_home_proposal_at,
      'play_unlock_at', play_unlock_at
    ) AS extra
  FROM arrangement
  WHERE tariff_or_skip IS NOT NULL
  UNION ALL
  SELECT
    'reply',
    club, opponent, fixture_id, play_month, matchday, competition_type, tariff_or_skip,
    jsonb_build_object(
      'response_due_at', response_due_at,
      'response_deadline_warned_at', response_deadline_warned_at
    )
  FROM replies
  WHERE tariff_or_skip IS NOT NULL
) x
ORDER BY
  CASE
    WHEN x.tariff_or_skip LIKE 'skipped_%' THEN 1
    WHEN x.tariff_or_skip = 'reply_warn' THEN 2
    ELSE 0
  END,
  x.club,
  x.kind,
  x.fixture_id;
