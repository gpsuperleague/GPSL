-- =============================================================================
-- Kneiver / Arsenal — PAST arranged kick-offs where ARS did not check in
-- Future KOs excluded. Read-only.
-- =============================================================================

-- A) OFFICIAL recorded no-shows (durable ladder events) — past KOs only
--    This survives catch-up / replay resets. Best answer to "how many no-shows".
SELECT
  e.id AS event_id,
  e.fixture_id,
  f.matchday,
  f.gpsl_month,
  f.division,
  f.competition_type,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  f.status AS fixture_status,
  to_char(timezone('Europe/London', e.kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS missed_ko_uk,
  e.play_attempt_no,
  e.both_miss AS both_missed_checkin,
  e.action,
  e.created_at
FROM public.competition_fixture_no_show_events e
JOIN public.competition_fixtures f ON f.id = e.fixture_id
WHERE upper(e.club_short_name) = 'ARS'
  AND e.kickoff_at <= now()
ORDER BY e.kickoff_at;

SELECT
  count(*) FILTER (WHERE NOT coalesce(e.both_miss, false)) AS ars_one_sided_noshows_past,
  count(*) FILTER (WHERE coalesce(e.both_miss, false)) AS ars_both_miss_past,
  count(*) AS ars_noshow_events_past_total
FROM public.competition_fixture_no_show_events e
WHERE upper(e.club_short_name) = 'ARS'
  AND e.kickoff_at <= now();

-- B) CURRENT schedule: past agreed KO and ARS has no check-in row now
--    (Check-ins clear on reset — so this is the live / latest attempt only.)
SELECT
  f.id AS fixture_id,
  f.matchday,
  f.gpsl_month,
  f.division,
  f.competition_type,
  f.status AS fixture_status,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  s.status AS sch_status,
  s.play_attempt_count,
  s.no_show_club_short_name,
  to_char(timezone('Europe/London', s.agreed_kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS agreed_ko_uk,
  (
    SELECT string_agg(ci.club_short_name, ', ' ORDER BY ci.club_short_name)
    FROM public.competition_fixture_checkin ci
    WHERE ci.fixture_id = f.id
  ) AS who_checked_in_now,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin ci
    WHERE ci.fixture_id = f.id AND upper(ci.club_short_name) = 'ARS'
  ) AS ars_checked_in,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin ci
    WHERE ci.fixture_id = f.id
      AND upper(ci.club_short_name) <> 'ARS'
  ) AS opponent_checked_in,
  (SELECT count(*) FROM public.competition_fixture_no_show_events e
   WHERE e.fixture_id = f.id
     AND upper(e.club_short_name) = 'ARS'
     AND e.kickoff_at <= now()) AS recorded_ars_noshows_on_fixture,
  CASE
    WHEN EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin ci
      WHERE ci.fixture_id = f.id AND upper(ci.club_short_name) = 'ARS'
    ) THEN 'ARS checked in (current attempt)'
    WHEN EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin ci WHERE ci.fixture_id = f.id
    ) THEN 'OPPONENT checked in — ARS DID NOT (current attempt)'
    ELSE 'NOBODY checked in (current attempt)'
  END AS checkin_read
FROM public.competition_fixtures f
JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE (upper(f.home_club_short_name) = 'ARS' OR upper(f.away_club_short_name) = 'ARS')
  AND s.status = 'agreed'
  AND s.agreed_kickoff_at IS NOT NULL
  AND s.agreed_kickoff_at <= now()
  AND NOT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin ci
    WHERE ci.fixture_id = f.id AND upper(ci.club_short_name) = 'ARS'
  )
ORDER BY s.agreed_kickoff_at;

-- C) Accepted proposals whose kick-off is already past — did that KO get a no-show event?
--    Catches older agreed times that were later rearranged (check-ins wiped).
SELECT
  p.id AS proposal_id,
  p.fixture_id,
  f.matchday,
  f.gpsl_month,
  f.division,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  f.status AS fixture_status,
  p.proposed_by_club_short_name,
  p.status AS proposal_status,
  to_char(timezone('Europe/London', p.kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS arranged_ko_uk,
  to_char(timezone('Europe/London', s.agreed_kickoff_at), 'Dy DD Mon YYYY HH24:MI') AS current_agreed_ko_uk,
  s.play_attempt_count,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_no_show_events e
    WHERE e.fixture_id = p.fixture_id
      AND upper(e.club_short_name) = 'ARS'
      AND e.kickoff_at = p.kickoff_at
  ) AS ars_noshow_recorded_for_this_ko,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_no_show_events e
    WHERE e.fixture_id = p.fixture_id
      AND e.kickoff_at = p.kickoff_at
      AND coalesce(e.both_miss, false)
  ) AS both_miss_recorded_for_this_ko,
  CASE
    WHEN p.kickoff_at > now() THEN 'future — ignore'
    WHEN EXISTS (
      SELECT 1 FROM public.competition_fixture_no_show_events e
      WHERE e.fixture_id = p.fixture_id
        AND upper(e.club_short_name) = 'ARS'
        AND e.kickoff_at = p.kickoff_at
    ) THEN 'PAST arranged KO — ARS no-show recorded'
    WHEN s.agreed_kickoff_at IS DISTINCT FROM p.kickoff_at
         AND p.kickoff_at <= now()
      THEN 'PAST arranged KO — later re-arranged (no ARS no-show event for this KO)'
    WHEN s.status = 'agreed'
         AND s.agreed_kickoff_at = p.kickoff_at
         AND p.kickoff_at <= now()
         AND NOT EXISTS (
           SELECT 1 FROM public.competition_fixture_checkin ci
           WHERE ci.fixture_id = p.fixture_id AND upper(ci.club_short_name) = 'ARS'
         )
      THEN 'PAST arranged KO — still current, ARS not checked in'
    WHEN f.status = 'played' AND p.kickoff_at <= now() THEN 'PAST arranged KO — fixture played (check-ins may be gone)'
    ELSE 'PAST arranged KO — no ARS no-show event on file'
  END AS read
FROM public.competition_fixture_schedule_proposal p
JOIN public.competition_fixtures f ON f.id = p.fixture_id
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE (upper(f.home_club_short_name) = 'ARS' OR upper(f.away_club_short_name) = 'ARS')
  AND p.status = 'accepted'
  AND p.kickoff_at <= now()
ORDER BY p.kickoff_at;

-- D) Season strikes + no-show fines (context)
SELECT
  s.season_id,
  sea.label AS season_label,
  sea.is_current,
  s.strike_count,
  s.updated_at,
  c.owner
FROM public.competition_owner_season_strikes s
JOIN public."Clubs" c ON c.owner_id = s.owner_id AND upper(c."ShortName") = 'ARS'
LEFT JOIN public.competition_seasons sea ON sea.id = s.season_id
ORDER BY s.updated_at DESC;

SELECT
  fa.id,
  fa.tariff_code,
  fa.amount,
  fa.waived,
  fa.fixture_id,
  fa.description,
  fa.note,
  to_char(timezone('Europe/London', fa.applied_at), 'Dy DD Mon YYYY HH24:MI') AS applied_uk
FROM public.competition_fine_applied fa
WHERE upper(fa.club_short_name) = 'ARS'
  AND fa.tariff_code ILIKE '%no_show%'
ORDER BY fa.applied_at;
