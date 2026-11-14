-- Cups: either club may make the first kick-off proposal once the round
-- month has unlocked. League still waits for the lock of the month before
-- the play month. A pending home proposal is still a reply. Vacant clubs
-- and a manual black box stay closed. The no-proposal strike stays on home.

CREATE OR REPLACE FUNCTION public.match_schedule_away_may_open_proposal(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play int;
  v_lock timestamptz;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.competition_fixture_involves_vacant_club(bigint)') IS NOT NULL
     AND public.competition_fixture_involves_vacant_club(p_fixture_id) THEN
    RETURN false;
  END IF;
  -- A live proposal is home's. An old accepted or superseded one, after the
  -- kick-off was cleared, does not keep away from opening the match again.
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.proposed_by_club_short_name = v_f.home_club_short_name
      AND p.status = 'pending'
  ) THEN
    RETURN false;
  END IF;

  v_play := public.competition_gpsl_month_sort(v_f.gpsl_month);

  IF lower(coalesce(v_f.competition_type, 'league')) = 'cup' THEN
    SELECT c.unlock_at INTO v_lock
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_f.season_id
      AND public.competition_gpsl_month_sort(c.gpsl_month) = v_play
    ORDER BY c.unlock_at
    LIMIT 1;
    RETURN v_lock IS NOT NULL AND v_lock <= now();
  END IF;

  SELECT c.lock_at INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_f.season_id
    AND public.competition_gpsl_month_sort(c.gpsl_month) = v_play - 1
  ORDER BY c.lock_at
  LIMIT 1;

  RETURN v_lock IS NOT NULL AND v_lock <= now();
END;
$function$;

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.club_wire_cutoffs()'::regprocedure
  ), E'\r\n', E'\n');

  IF position('Either club can propose the kick-off' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$      WHEN v_side = 'home' AND NOT v_home_proposed THEN 'propose'$old$, E'\r\n', E'\n');
  v_new := replace($new$      WHEN NOT v_home_proposed AND (v_side = 'home' OR (lower(coalesce(r.competition_type, '')) = 'cup' AND r.unlock_at <= now())) THEN 'propose'$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'club wire: propose state not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$WHEN v_state = 'propose' THEN 'This GPSL month has opened and the match has not been played or awarded. Home still has to propose.'$old$, E'\r\n', E'\n');
  v_new := replace($new$WHEN v_state = 'propose' THEN 'This GPSL month has opened and the match has not been played or awarded. ' || CASE WHEN lower(coalesce(r.competition_type, '')) = 'cup' THEN 'Either club can propose the kick-off. If nobody does, the strike stays with the home club.' ELSE 'Home still has to propose.' END$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'club wire: propose detail not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$wire$;

WITH cup_open AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_season_calendar c
    ON c.season_id = f.season_id
   AND public.competition_gpsl_month_sort(c.gpsl_month) = public.competition_gpsl_month_sort(f.gpsl_month)
  WHERE lower(coalesce(f.competition_type, '')) = 'cup'
    AND f.status = 'scheduled'
    AND c.unlock_at <= now()
    AND c.lock_at > now()
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_fixture_schedule_proposal p
      WHERE p.fixture_id = f.id
        AND p.status = 'pending'
        AND p.proposed_by_club_short_name = f.home_club_short_name
    )
    AND (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NULL
      OR NOT public.fixture_is_manual_black_box(f.id)
    )
    AND (
      to_regprocedure('public.competition_fixture_involves_vacant_club(bigint)') IS NULL
      OR NOT public.competition_fixture_involves_vacant_club(f.id)
    )
  ORDER BY f.id
  LIMIT 1
),
league_wait AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_season_calendar c
    ON c.season_id = f.season_id
   AND public.competition_gpsl_month_sort(c.gpsl_month) = public.competition_gpsl_month_sort(f.gpsl_month) - 1
  WHERE lower(coalesce(f.competition_type, 'league')) = 'league'
    AND f.status = 'scheduled'
    AND c.lock_at > now()
  ORDER BY f.id
  LIMIT 1
),
league_open AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_season_calendar c
    ON c.season_id = f.season_id
   AND public.competition_gpsl_month_sort(c.gpsl_month) = public.competition_gpsl_month_sort(f.gpsl_month) - 1
  WHERE lower(coalesce(f.competition_type, 'league')) = 'league'
    AND f.status = 'scheduled'
    AND c.lock_at <= now()
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_fixture_schedule_proposal p
      WHERE p.fixture_id = f.id
        AND p.status = 'pending'
        AND p.proposed_by_club_short_name = f.home_club_short_name
    )
    AND (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NULL
      OR NOT public.fixture_is_manual_black_box(f.id)
    )
    AND (
      to_regprocedure('public.competition_fixture_involves_vacant_club(bigint)') IS NULL
      OR NOT public.competition_fixture_involves_vacant_club(f.id)
    )
  ORDER BY f.id
  LIMIT 1
)
SELECT
  (SELECT id FROM cup_open) AS cup_open_id,
  public.match_schedule_away_may_open_proposal((SELECT id FROM cup_open)) AS cup_open_away,
  (SELECT id FROM league_wait) AS league_wait_id,
  public.match_schedule_away_may_open_proposal((SELECT id FROM league_wait)) AS league_wait_away,
  (SELECT id FROM league_open) AS league_open_id,
  public.match_schedule_away_may_open_proposal((SELECT id FROM league_open)) AS league_open_away,
  position(
    'c.unlock_at' IN replace(pg_get_functiondef('public.match_schedule_away_may_open_proposal(bigint)'::regprocedure), E'\r\n', E'\n')
  ) > 0 AS cup_uses_unlock,
  position(
    'v_play - 1' IN replace(pg_get_functiondef('public.match_schedule_away_may_open_proposal(bigint)'::regprocedure), E'\r\n', E'\n')
  ) > 0 AS league_still_month_before,
  position(
    'Either club can propose the kick-off' IN replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n')
  ) > 0 AS wire_cup_copy;
