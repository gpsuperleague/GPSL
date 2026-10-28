-- =============================================================================
-- Diagnose: Gabriel Sara — injury history, absences, still applicable?
-- Run without RLS. Read-only.
-- =============================================================================

-- 1) Player identity
SELECT
  p."Konami_ID"::text AS player_id,
  p."Name",
  p."Contracted_Team" AS club,
  p."Position"
FROM public."Players" p
WHERE p."Name" ILIKE '%Gabriel%Sara%'
   OR p."Name" ILIKE '%Sara%Gabriel%'
ORDER BY p."Name";

-- 2) All injury rows for him (any status)
WITH player AS (
  SELECT p."Konami_ID"::text AS player_id, p."Name", p."Contracted_Team" AS club
  FROM public."Players" p
  WHERE p."Name" ILIKE '%Gabriel%Sara%'
     OR p."Name" ILIKE '%Sara%Gabriel%'
)
SELECT
  i.id AS injury_id,
  pl."Name",
  i.club_short_name,
  i.status,
  i.label,
  i.severity,
  i.matches_out,
  i.matches_out_remaining,
  i.recovery_matches,
  i.recovery_remaining,
  i.source_fixture_id,
  sf.matchday AS source_md,
  sf.home_club_short_name || ' vs ' || sf.away_club_short_name AS source_fixture,
  sf.status AS source_fixture_status,
  i.created_at,
  i.recovered_at,
  CASE
    WHEN i.status = 'active'
         AND (coalesce(i.matches_out_remaining, 0) > 0
              OR coalesce(i.recovery_remaining, 0) > 0)
      THEN 'STILL_APPLICABLE'
    WHEN i.status = 'active'
         AND coalesce(i.matches_out_remaining, 0) = 0
         AND coalesce(i.recovery_remaining, 0) = 0
      THEN 'ACTIVE_BUT_ZERO_REMAINING'
    WHEN i.status = 'recovered' THEN 'RECOVERED'
    WHEN i.status = 'cancelled' THEN 'CANCELLED'
    ELSE i.status
  END AS applicability
FROM public.competition_player_injuries i
JOIN player pl ON pl.player_id = i.player_id
LEFT JOIN public.competition_fixtures sf ON sf.id = i.source_fixture_id
ORDER BY i.created_at DESC NULLS LAST, i.id DESC;

-- 3) Every fixture absence linked to those injuries (served + unserved)
WITH player AS (
  SELECT p."Konami_ID"::text AS player_id
  FROM public."Players" p
  WHERE p."Name" ILIKE '%Gabriel%Sara%'
     OR p."Name" ILIKE '%Sara%Gabriel%'
),
inj AS (
  SELECT i.*
  FROM public.competition_player_injuries i
  JOIN player pl ON pl.player_id = i.player_id
)
SELECT
  iff.injury_id,
  i.status AS injury_status,
  i.label,
  iff.phase,
  iff.served,
  iff.fixture_id,
  f.matchday,
  f.gpsl_month,
  f.status AS fixture_status,
  f.home_club_short_name || ' vs ' || f.away_club_short_name AS fixture,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  CASE
    WHEN iff.served THEN 'ABSENCE_ALREADY_SERVED'
    WHEN f.status = 'scheduled' AND iff.served = false THEN 'SHOULD_BE_UNAVAILABLE_NOW'
    WHEN f.status IN ('played', 'completed', 'forfeit') AND iff.served = false
      THEN 'LINK_UNSERVED_BUT_FIXTURE_PLAYED'
    ELSE 'OTHER'
  END AS absence_verdict
FROM public.competition_player_injury_fixtures iff
JOIN inj i ON i.id = iff.injury_id
JOIN public.competition_fixtures f ON f.id = iff.fixture_id
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
ORDER BY f.matchday NULLS LAST, f.id, iff.phase;

-- 4) If still active: which upcoming fixtures SHOULD be covered (next N by assign rules)
WITH player AS (
  SELECT p."Konami_ID"::text AS player_id, p."Contracted_Team" AS club
  FROM public."Players" p
  WHERE p."Name" ILIKE '%Gabriel%Sara%'
     OR p."Name" ILIKE '%Sara%Gabriel%'
  LIMIT 1
),
active AS (
  SELECT i.*
  FROM public.competition_player_injuries i
  JOIN player pl ON pl.player_id = i.player_id
  WHERE i.status = 'active'
    AND (coalesce(i.matches_out_remaining, 0) > 0
         OR coalesce(i.recovery_remaining, 0) > 0)
  ORDER BY i.id DESC
  LIMIT 1
),
season AS (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
),
upcoming AS (
  SELECT
    f.id,
    f.matchday,
    f.home_club_short_name || ' vs ' || f.away_club_short_name AS fixture,
    f.status,
    row_number() OVER (ORDER BY coalesce(f.matchday, 9999), f.id) AS seq
  FROM public.competition_fixtures f
  CROSS JOIN active a
  CROSS JOIN season s
  CROSS JOIN player pl
  WHERE f.season_id = s.id
    AND f.status = 'scheduled'
    AND (f.home_club_short_name = coalesce(a.club_short_name, pl.club)
         OR f.away_club_short_name = coalesce(a.club_short_name, pl.club))
    AND (a.source_fixture_id IS NULL OR f.id IS DISTINCT FROM a.source_fixture_id)
)
SELECT
  a.id AS injury_id,
  a.label,
  a.matches_out_remaining AS out_rem,
  a.recovery_remaining AS rec_rem,
  u.seq,
  u.id AS fixture_id,
  u.matchday,
  u.fixture,
  CASE
    WHEN u.seq <= coalesce(a.matches_out_remaining, 0) THEN 'out'
    WHEN u.seq <= coalesce(a.matches_out_remaining, 0) + coalesce(a.recovery_remaining, 0)
      THEN 'recovery'
    ELSE NULL
  END AS expected_phase,
  EXISTS (
    SELECT 1 FROM public.competition_player_injury_fixtures iff
    WHERE iff.injury_id = a.id AND iff.fixture_id = u.id AND iff.served = false
  ) AS has_unserved_link
FROM active a
CROSS JOIN upcoming u
WHERE u.seq <= coalesce(a.matches_out_remaining, 0) + coalesce(a.recovery_remaining, 0)
ORDER BY u.seq;

-- 5) Summary
WITH player AS (
  SELECT p."Konami_ID"::text AS player_id, p."Name"
  FROM public."Players" p
  WHERE p."Name" ILIKE '%Gabriel%Sara%'
     OR p."Name" ILIKE '%Sara%Gabriel%'
),
inj AS (
  SELECT i.*
  FROM public.competition_player_injuries i
  JOIN player pl ON pl.player_id = i.player_id
)
SELECT
  (SELECT count(*) FROM inj) AS injury_rows_total,
  (SELECT count(*) FROM inj WHERE status = 'active') AS active_rows,
  (SELECT count(*) FROM inj WHERE status = 'recovered') AS recovered_rows,
  (SELECT count(*) FROM inj WHERE status = 'cancelled') AS cancelled_rows,
  (
    SELECT count(*)
    FROM public.competition_player_injury_fixtures iff
    JOIN inj i ON i.id = iff.injury_id
    WHERE iff.served = false
      AND i.status = 'active'
  ) AS unserved_absence_links,
  (
    SELECT bool_or(
      status = 'active'
      AND (coalesce(matches_out_remaining, 0) > 0 OR coalesce(recovery_remaining, 0) > 0)
    )
    FROM inj
  ) AS still_should_be_unavailable;
