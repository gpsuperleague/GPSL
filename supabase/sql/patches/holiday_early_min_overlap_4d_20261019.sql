-- =============================================================================
-- Holiday early unlock: need ≥4 inclusive UK days overlapping the GPSL month
--
-- Shorter holidays stay bookable (UH/OH badges, fine suppression unchanged).
-- Early arrange/play only when overlap with that fixture’s month window ≥ 4 days.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_holiday_early_min_overlap_days()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 4;
$$;

COMMENT ON FUNCTION public.club_holiday_early_min_overlap_days() IS
  'Minimum inclusive UK days a holiday must overlap a GPSL month to unlock early fixture management.';

-- Inclusive UK overlap between holiday [starts, ends) and month [unlock, lock]
CREATE OR REPLACE FUNCTION public.club_holiday_overlap_inclusive_days(
  p_holiday_starts timestamptz,
  p_holiday_ends timestamptz,
  p_window_unlock timestamptz,
  p_window_lock timestamptz
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_start timestamptz;
  v_end timestamptz;
BEGIN
  IF p_holiday_starts IS NULL OR p_holiday_ends IS NULL
     OR p_window_unlock IS NULL OR p_window_lock IS NULL THEN
    RETURN 0;
  END IF;

  IF p_holiday_ends <= p_holiday_starts OR p_window_lock <= p_window_unlock THEN
    RETURN 0;
  END IF;

  -- No overlap
  IF p_holiday_starts >= p_window_lock OR p_holiday_ends <= p_window_unlock THEN
    RETURN 0;
  END IF;

  v_start := greatest(p_holiday_starts, p_window_unlock);
  v_end := least(p_holiday_ends, p_window_lock);

  IF v_end <= v_start THEN
    RETURN 0;
  END IF;

  RETURN public.club_holiday_inclusive_days(v_start, v_end);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_holiday_early_min_overlap_days() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_holiday_overlap_inclusive_days(timestamptz, timestamptz, timestamptz, timestamptz)
  TO authenticated;

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
      AND public.club_holiday_overlap_inclusive_days(
            h.starts_at, h.ends_at, v_unlock, v_lock
          ) >= v_min
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_holiday_allows_fixture_early(bigint, text) TO authenticated;

-- Inbox copy: only promise early play when booking itself is ≥ min days
-- (month overlap still gated in allows_fixture_early)
CREATE OR REPLACE FUNCTION public.club_holiday_inbox_announce(
  p_action text,
  p_holiday_id bigint,
  p_club text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_day_count int,
  p_season_id bigint
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id jsonb;
  v_club_name text;
  v_tag text;
  v_start_label text;
  v_end_label text;
  v_title text;
  v_body text;
  v_action text := lower(btrim(coalesce(p_action, 'booked')));
  v_dedupe text;
  v_count int := 0;
  v_min int := public.club_holiday_early_min_overlap_days();
  v_early_note text;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_notify_all_clubs(text,text,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN 0;
  END IF;

  v_id := public.club_holiday_public_identity(p_club);
  v_club_name := coalesce(v_id->>'club_name', p_club);
  v_tag := nullif(btrim(coalesce(v_id->>'owner_tag', '')), '');

  v_start_label := to_char(
    (p_starts_at AT TIME ZONE 'Europe/London')::date, 'DD Mon YYYY'
  );
  v_end_label := to_char(
    ((p_ends_at - interval '1 microsecond') AT TIME ZONE 'Europe/London')::date,
    'DD Mon YYYY'
  );

  IF coalesce(p_day_count, 0) >= v_min THEN
    v_early_note := format(
      E'\n\nIf this holiday covers %s+ days of a future GPSL month, those fixtures unlock for early arrange/play (both clubs need a full squad, min 24).',
      v_min
    );
  ELSE
    v_early_note := format(
      E'\n\nBookings under %s days do not unlock early fixture management (UH/OH status still applies).',
      v_min
    );
  END IF;

  IF v_action IN ('cancel', 'cancelled') THEN
    v_title := format('Holiday cancelled — %s', v_club_name);
    v_body := format(
      E'%s%s has cancelled their holiday (%s – %s, %s day%s).\n\nSee Owner Holidays for the current list.',
      v_club_name,
      CASE WHEN v_tag IS NULL THEN '' ELSE ' (' || v_tag || ')' END,
      v_start_label,
      v_end_label,
      coalesce(p_day_count, 0),
      CASE WHEN coalesce(p_day_count, 0) = 1 THEN '' ELSE 's' END
    );
    v_dedupe := format('holiday_cancel_%s_%s', p_holiday_id, extract(epoch FROM now())::bigint);
  ELSIF v_action IN ('amend', 'amended') THEN
    v_title := format('Holiday updated — %s', v_club_name);
    v_body := format(
      E'%s%s has updated their holiday to %s – %s (%s day%s).%s\n\nOpen Owner Holidays for fixtures and status.',
      v_club_name,
      CASE WHEN v_tag IS NULL THEN '' ELSE ' (' || v_tag || ')' END,
      v_start_label,
      v_end_label,
      coalesce(p_day_count, 0),
      CASE WHEN coalesce(p_day_count, 0) = 1 THEN '' ELSE 's' END,
      v_early_note
    );
    v_dedupe := format('holiday_amend_%s_%s', p_holiday_id, extract(epoch FROM now())::bigint);
  ELSE
    v_title := format('Holiday booked — %s', v_club_name);
    v_body := format(
      E'%s%s has booked holiday %s – %s (%s day%s).%s\n\nOpen Owner Holidays for fixtures and UH/OH status.',
      v_club_name,
      CASE WHEN v_tag IS NULL THEN '' ELSE ' (' || v_tag || ')' END,
      v_start_label,
      v_end_label,
      coalesce(p_day_count, 0),
      CASE WHEN coalesce(p_day_count, 0) = 1 THEN '' ELSE 's' END,
      v_early_note
    );
    v_dedupe := format('holiday_book_%s', p_holiday_id);
  END IF;

  v_count := public.owner_inbox_notify_all_clubs(
    'owner_holiday',
    v_title,
    v_body,
    'owner_holidays_board.html',
    v_dedupe,
    p_season_id
  );

  RETURN coalesce(v_count, 0);
END;
$function$;

-- Directory: only list fixtures that meet the early-unlock overlap
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
    IF now() >= v_h.starts_at AND now() < v_h.ends_at THEN
      v_status := 'active';
      v_code := 'OH';
    ELSE
      v_status := 'upcoming';
      v_code := 'UH';
    END IF;

    v_id := public.club_holiday_public_identity(v_h.club_short_name);

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
        'early_unlock', coalesce(v_h.day_count, 0) >= v_min,
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
