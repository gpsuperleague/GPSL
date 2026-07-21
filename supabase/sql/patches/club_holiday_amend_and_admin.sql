-- =============================================================================
-- Owner holiday amend (before start) + admin manage (any status)
-- Safe re-run.
-- Depends on: club_owner_holidays.sql, match_scheduling_phase2 club_holiday_book rules
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_holiday_amend(
  p_holiday_id bigint,
  p_start_date date,
  p_end_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_row public.club_owner_holidays;
  v_starts timestamptz;
  v_ends timestamptz;
  v_days integer;
  v_used integer;
  v_max integer := public.club_holiday_max_days_per_season();
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF p_start_date IS NULL OR p_end_date IS NULL THEN
    RAISE EXCEPTION 'Start and end dates are required';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'End date must be on or after start date';
  END IF;

  SELECT * INTO v_row
  FROM public.club_owner_holidays h
  WHERE h.id = p_holiday_id
    AND h.club_short_name = v_club
    AND h.owner_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Holiday booking not found';
  END IF;

  IF v_row.starts_at <= now() THEN
    RAISE EXCEPTION 'Cannot amend a holiday that has already started — ask an admin';
  END IF;

  v_starts := (p_start_date::timestamp AT TIME ZONE 'Europe/London');
  v_ends := ((p_end_date + 1)::timestamp AT TIME ZONE 'Europe/London');
  v_days := public.club_holiday_inclusive_days(v_starts, v_ends);

  IF v_days > v_max THEN
    RAISE EXCEPTION 'A single booking cannot exceed % days', v_max;
  END IF;

  -- Quota excluding this booking's current days
  v_used := public.club_holiday_days_used(v_row.season_id, v_club) - v_row.day_count;
  IF v_used + v_days > v_max THEN
    RAISE EXCEPTION 'Only % days of holiday per season (% used by other bookings, % requested)',
      v_max, greatest(v_used, 0), v_days;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_row.season_id
      AND cal.unlock_at < v_ends
      AND cal.lock_at > v_starts
      AND now() >= cal.unlock_at
  ) THEN
    RAISE EXCEPTION 'Cannot move holiday onto a GPSL month that has already started (Fri 19:00 UK)';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_row.season_id
      AND h.club_short_name = v_club
      AND h.id <> p_holiday_id
      AND h.starts_at < v_ends
      AND h.ends_at > v_starts
  ) THEN
    RAISE EXCEPTION 'Holiday overlaps another booking for this season';
  END IF;

  IF v_ends <= now() THEN
    RAISE EXCEPTION 'Holiday must end in the future';
  END IF;

  IF v_starts <= now() THEN
    RAISE EXCEPTION 'Amended holiday must still start in the future';
  END IF;

  UPDATE public.club_owner_holidays
  SET
    starts_at = v_starts,
    ends_at = v_ends,
    day_count = v_days::smallint
  WHERE id = p_holiday_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_list_club_holidays(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club_short_name, '')), '');
  v_season_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object(
      'season_id', null,
      'max_days', public.club_holiday_max_days_per_season(),
      'holidays', '[]'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'max_days', public.club_holiday_max_days_per_season(),
    'holidays', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id', h.id,
          'season_id', h.season_id,
          'club_short_name', h.club_short_name,
          'club_name', c."Club",
          'owner_id', h.owner_id,
          'owner_tag', r.owner_tag,
          'starts_at', h.starts_at,
          'ends_at', h.ends_at,
          'day_count', h.day_count,
          'created_at', h.created_at,
          'is_active', (now() >= h.starts_at AND now() < h.ends_at),
          'is_upcoming', (now() < h.starts_at),
          'is_ended', (now() >= h.ends_at),
          'days_used', public.club_holiday_days_used(h.season_id, h.club_short_name)
        )
        ORDER BY h.starts_at, h.club_short_name
      ), '[]'::jsonb)
      FROM public.club_owner_holidays h
      LEFT JOIN public."Clubs" c ON c."ShortName" = h.club_short_name
      LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = h.owner_id
      WHERE h.season_id = v_season_id
        AND (v_club IS NULL OR h.club_short_name = v_club)
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_holiday_cancel(p_holiday_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_deleted int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_holiday_id IS NULL THEN
    RAISE EXCEPTION 'Holiday id is required';
  END IF;

  DELETE FROM public.club_owner_holidays
  WHERE id = p_holiday_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted = 0 THEN
    RAISE EXCEPTION 'Holiday booking not found';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_holiday_amend(
  p_holiday_id bigint,
  p_start_date date,
  p_end_date date
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.club_owner_holidays;
  v_starts timestamptz;
  v_ends timestamptz;
  v_days integer;
  v_used integer;
  v_max integer := public.club_holiday_max_days_per_season();
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_holiday_id IS NULL THEN
    RAISE EXCEPTION 'Holiday id is required';
  END IF;

  IF p_start_date IS NULL OR p_end_date IS NULL THEN
    RAISE EXCEPTION 'Start and end dates are required';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'End date must be on or after start date';
  END IF;

  SELECT * INTO v_row
  FROM public.club_owner_holidays h
  WHERE h.id = p_holiday_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Holiday booking not found';
  END IF;

  v_starts := (p_start_date::timestamp AT TIME ZONE 'Europe/London');
  v_ends := ((p_end_date + 1)::timestamp AT TIME ZONE 'Europe/London');
  v_days := public.club_holiday_inclusive_days(v_starts, v_ends);

  IF v_days < 1 THEN
    RAISE EXCEPTION 'Holiday must be at least 1 day';
  END IF;

  IF v_days > v_max THEN
    RAISE EXCEPTION 'A single booking cannot exceed % days', v_max;
  END IF;

  v_used := public.club_holiday_days_used(v_row.season_id, v_row.club_short_name) - v_row.day_count;
  IF v_used + v_days > v_max THEN
    RAISE EXCEPTION 'Only % days of holiday per season (% used by other bookings, % requested)',
      v_max, greatest(v_used, 0), v_days;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_row.season_id
      AND h.club_short_name = v_row.club_short_name
      AND h.id <> p_holiday_id
      AND h.starts_at < v_ends
      AND h.ends_at > v_starts
  ) THEN
    RAISE EXCEPTION 'Holiday overlaps another booking for this club';
  END IF;

  -- Admin may amend active/ended/unlocked months (ops override)
  UPDATE public.club_owner_holidays
  SET
    starts_at = v_starts,
    ends_at = v_ends,
    day_count = v_days::smallint
  WHERE id = p_holiday_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_holiday_book(
  p_club_short_name text,
  p_start_date date,
  p_end_date date
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_owner_id uuid;
  v_starts timestamptz;
  v_ends timestamptz;
  v_days integer;
  v_used integer;
  v_max integer := public.club_holiday_max_days_per_season();
  v_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  SELECT c.owner_id INTO v_owner_id
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  IF p_start_date IS NULL OR p_end_date IS NULL THEN
    RAISE EXCEPTION 'Start and end dates are required';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'End date must be on or after start date';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  v_starts := (p_start_date::timestamp AT TIME ZONE 'Europe/London');
  v_ends := ((p_end_date + 1)::timestamp AT TIME ZONE 'Europe/London');
  v_days := public.club_holiday_inclusive_days(v_starts, v_ends);

  IF v_days < 1 OR v_days > v_max THEN
    RAISE EXCEPTION 'Booking must be 1–% days', v_max;
  END IF;

  v_used := public.club_holiday_days_used(v_season_id, v_club);
  IF v_used + v_days > v_max THEN
    RAISE EXCEPTION 'Only % days of holiday per season (% used, % requested)',
      v_max, v_used, v_days;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season_id
      AND h.club_short_name = v_club
      AND h.starts_at < v_ends
      AND h.ends_at > v_starts
  ) THEN
    RAISE EXCEPTION 'Holiday overlaps an existing booking for this club';
  END IF;

  INSERT INTO public.club_owner_holidays (
    season_id,
    club_short_name,
    owner_id,
    starts_at,
    ends_at,
    day_count
  )
  VALUES (
    v_season_id,
    v_club,
    v_owner_id,
    v_starts,
    v_ends,
    v_days::smallint
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_holiday_amend(bigint, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_club_holidays(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_holiday_cancel(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_holiday_amend(bigint, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_holiday_book(text, date, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
