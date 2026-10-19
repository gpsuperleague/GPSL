-- =============================================================================
-- Extra holiday days (>14 / season) only count while owner is an active supporter
--
-- Booking still allows up to 21 while subscribed. If support lapses:
--   • effective max drops to 14
--   • earliest bookings fill the 14-day budget first (by starts_at, id)
--   • later / oversized bookings stop counting for UH/OH, early unlock, fines
-- Re-subscribe → they count again (no auto-delete).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_holiday_is_effective(p_holiday_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_h public.club_owner_holidays;
  v_max int;
  v_before int;
BEGIN
  SELECT * INTO v_h
  FROM public.club_owner_holidays h
  WHERE h.id = p_holiday_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_max := public.club_holiday_max_days_per_season(v_h.owner_id);

  -- Days already "spent" by earlier bookings in the same season/club
  SELECT coalesce(sum(h2.day_count), 0)::int
  INTO v_before
  FROM public.club_owner_holidays h2
  WHERE h2.season_id = v_h.season_id
    AND h2.club_short_name = v_h.club_short_name
    AND (
      h2.starts_at < v_h.starts_at
      OR (h2.starts_at = v_h.starts_at AND h2.id < v_h.id)
    );

  RETURN (v_before + v_h.day_count) <= v_max;
END;
$function$;

COMMENT ON FUNCTION public.club_holiday_is_effective(bigint) IS
  'True when this holiday fits under the owner''s current season cap (14, or 21 while supporter).';

GRANT EXECUTE ON FUNCTION public.club_holiday_is_effective(bigint) TO authenticated;

-- Early unlock: only effective holidays
CREATE OR REPLACE FUNCTION public.club_holiday_allows_fixture_early(
  p_fixture_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_min int := public.club_holiday_early_min_overlap_days();
BEGIN
  IF p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN false;
  END IF;

  SELECT f.* INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF p_club_short_name NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RETURN false;
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  SELECT m.unlock_at, m.lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_fixture.season_id
    AND m.gpsl_month = v_fixture.gpsl_month;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF now() >= v_lock THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_fixture.season_id
      AND h.club_short_name = p_club_short_name
      AND now() >= h.created_at
      AND now() < h.ends_at
      AND public.club_holiday_is_effective(h.id)
      AND public.club_holiday_overlap_inclusive_days(
            h.starts_at, h.ends_at, v_unlock, v_lock
          ) >= v_min
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_holiday_allows_fixture_early(bigint, text) TO authenticated;

-- Fine suppression / month holiday check
CREATE OR REPLACE FUNCTION public.match_schedule_club_on_holiday_for_month(
  p_season_id bigint,
  p_club_short_name text,
  p_gpsl_month text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    JOIN public.competition_season_calendar c
      ON c.season_id = h.season_id
     AND lower(btrim(c.gpsl_month)) = lower(btrim(p_gpsl_month))
    WHERE h.season_id = p_season_id
      AND h.club_short_name = p_club_short_name
      AND public.club_holiday_is_effective(h.id)
      AND h.starts_at < c.lock_at
      AND h.ends_at > c.unlock_at
  );
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_club_on_holiday_for_month(bigint, text, text)
  TO authenticated;

-- UH / OH badges: only effective holidays
CREATE OR REPLACE FUNCTION public.owner_holiday_status_map()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_map jsonb := '{}'::jsonb;
  v_row record;
  v_code text;
  v_status text;
  v_existing text;
BEGIN
  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  FOR v_row IN
    SELECT
      h.club_short_name,
      h.starts_at,
      h.ends_at,
      CASE
        WHEN now() >= h.starts_at AND now() < h.ends_at THEN 'active'
        WHEN now() < h.starts_at THEN 'upcoming'
        ELSE 'ended'
      END AS status
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season
      AND h.ends_at > now()
      AND public.club_holiday_is_effective(h.id)
    ORDER BY h.starts_at
  LOOP
    IF v_row.status = 'active' THEN
      v_code := 'OH';
      v_status := 'active';
    ELSIF v_row.status = 'upcoming' THEN
      v_code := 'UH';
      v_status := 'upcoming';
    ELSE
      CONTINUE;
    END IF;

    v_existing := v_map #>> ARRAY[v_row.club_short_name, 'code'];
    IF v_existing = 'OH' AND v_code = 'UH' THEN
      CONTINUE;
    END IF;

    v_map := v_map || jsonb_build_object(
      v_row.club_short_name,
      jsonb_build_object(
        'code', v_code,
        'status', v_status,
        'starts_at', v_row.starts_at,
        'ends_at', v_row.ends_at
      )
    );
  END LOOP;

  RETURN v_map;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_holiday_status_map() TO authenticated;

-- Public view: expose effectiveness for Owner Details UI
DROP VIEW IF EXISTS public.club_owner_holidays_public;
CREATE OR REPLACE VIEW public.club_owner_holidays_public
WITH (security_invoker = false)
AS
SELECT
  h.id,
  h.season_id,
  h.club_short_name,
  h.starts_at,
  h.ends_at,
  h.day_count,
  h.created_at,
  public.club_holiday_days_used(h.season_id, h.club_short_name) AS season_days_used,
  public.club_holiday_max_days_per_season(h.owner_id) AS season_days_allowance,
  (
    public.club_holiday_max_days_per_season(h.owner_id)
    - public.club_holiday_days_used(h.season_id, h.club_short_name)
  ) AS season_days_remaining,
  (now() >= h.starts_at AND now() < h.ends_at) AS is_active,
  (now() < h.starts_at) AS is_upcoming,
  (now() >= h.ends_at) AS is_ended,
  public.club_holiday_is_effective(h.id) AS is_effective,
  (NOT public.club_holiday_is_effective(h.id) AND now() < h.ends_at) AS needs_supporter
FROM public.club_owner_holidays h
JOIN public.competition_seasons s ON s.id = h.season_id
WHERE s.is_current = true
  AND s.status IN ('active', 'preseason')
  AND h.club_short_name = public.my_club_shortname();

GRANT SELECT ON public.club_owner_holidays_public TO authenticated;

-- Directory: skip ineffective holidays for badges/fixtures list
CREATE OR REPLACE FUNCTION public.owner_holidays_directory()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_holidays jsonb := '[]'::jsonb;
  v_h record;
  v_id jsonb;
  v_fixtures jsonb;
  v_status text;
  v_code text;
  v_min int := public.club_holiday_early_min_overlap_days();
  v_effective boolean;
BEGIN
  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object(
      'season_id', null,
      'early_min_overlap_days', v_min,
      'holidays', '[]'::jsonb,
      'generated_at', now()
    );
  END IF;

  FOR v_h IN
    SELECT h.*
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season
      AND h.ends_at > now()
    ORDER BY
      CASE WHEN now() >= h.starts_at AND now() < h.ends_at THEN 0 ELSE 1 END,
      h.starts_at
  LOOP
    v_effective := public.club_holiday_is_effective(v_h.id);

    IF now() >= v_h.starts_at AND now() < v_h.ends_at THEN
      v_status := 'active';
      v_code := 'OH';
    ELSE
      v_status := 'upcoming';
      v_code := 'UH';
    END IF;

    -- Ineffective (lapsed supporter over 14d budget): still list, no UH/OH code
    IF NOT v_effective THEN
      v_code := 'PAUSED';
      v_status := 'paused_supporter';
    END IF;

    v_id := public.club_holiday_public_identity(v_h.club_short_name);

    IF v_effective THEN
      SELECT coalesce(jsonb_agg(x ORDER BY x.gpsl_month, x.home_club, x.away_club), '[]'::jsonb)
      INTO v_fixtures
      FROM (
        SELECT
          f.id AS fixture_id,
          f.competition_type AS competition,
          f.cup_code,
          f.gpsl_month,
          f.home_club_short_name AS home_club,
          f.away_club_short_name AS away_club,
          f.status,
          cal.unlock_at,
          cal.lock_at,
          public.club_holiday_overlap_inclusive_days(
            v_h.starts_at, v_h.ends_at, cal.unlock_at, cal.lock_at
          ) AS overlap_days
        FROM public.competition_fixtures f
        JOIN public.competition_season_calendar cal
          ON cal.season_id = f.season_id
         AND cal.gpsl_month = f.gpsl_month
        WHERE f.season_id = v_season
          AND f.status = 'scheduled'
          AND v_h.club_short_name IN (f.home_club_short_name, f.away_club_short_name)
          AND now() < cal.lock_at
          AND public.club_holiday_overlap_inclusive_days(
                v_h.starts_at, v_h.ends_at, cal.unlock_at, cal.lock_at
              ) >= v_min
      ) x;
    ELSE
      v_fixtures := '[]'::jsonb;
    END IF;

    v_holidays := v_holidays || jsonb_build_array(
      jsonb_build_object(
        'holiday_id', v_h.id,
        'club_short_name', v_h.club_short_name,
        'club_name', v_id->>'club_name',
        'owner_tag', v_id->>'owner_tag',
        'owner_id', nullif(v_id->>'owner_id', ''),
        'starts_at', v_h.starts_at,
        'ends_at', v_h.ends_at,
        'day_count', v_h.day_count,
        'is_effective', v_effective,
        'early_unlock', v_effective AND coalesce(v_h.day_count, 0) >= v_min,
        'status', v_status,
        'status_code', v_code,
        'fixtures', coalesce(v_fixtures, '[]'::jsonb)
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season,
    'early_min_overlap_days', v_min,
    'holidays', v_holidays,
    'generated_at', now()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_holidays_directory() TO authenticated;

NOTIFY pgrst, 'reload schema';
