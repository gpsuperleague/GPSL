-- =============================================================================
-- Owner holiday booking: start date must be today or later (Europe/London).
--
-- Today is allowed. A past start date is not. Admin book/amend is unchanged.
-- Safe re-run. Replaces owner functions from supporter_holiday_days_21_20261019.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_holiday_book(
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
  v_starts timestamptz;
  v_ends timestamptz;
  v_days integer;
  v_used integer;
  v_max integer := public.club_holiday_max_days_per_season(auth.uid());
  v_id bigint;
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

  IF p_start_date < (timezone('Europe/London', now()))::date THEN
    RAISE EXCEPTION 'Holiday cannot start on a past day';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  v_starts := (p_start_date::timestamp AT TIME ZONE 'Europe/London');
  v_ends := ((p_end_date + 1)::timestamp AT TIME ZONE 'Europe/London');
  v_days := public.club_holiday_inclusive_days(v_starts, v_ends);

  IF v_days > v_max THEN
    RAISE EXCEPTION 'A single booking cannot exceed % days', v_max;
  END IF;

  v_used := public.club_holiday_days_used(v_season_id, v_club);
  IF v_used + v_days > v_max THEN
    RAISE EXCEPTION 'Only % days of holiday per season (% used, % requested)',
      v_max, v_used, v_days;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season_id
      AND cal.unlock_at < v_ends
      AND cal.lock_at > v_starts
      AND now() >= cal.unlock_at
  ) THEN
    RAISE EXCEPTION 'Cannot book holiday for a GPSL month that has already started (Fri 19:00 UK)';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season_id
      AND h.club_short_name = v_club
      AND h.starts_at < v_ends
      AND h.ends_at > v_starts
  ) THEN
    RAISE EXCEPTION 'Holiday overlaps an existing booking for this season';
  END IF;

  IF v_ends <= now() THEN
    RAISE EXCEPTION 'Holiday must end in the future';
  END IF;

  INSERT INTO public.club_owner_holidays (
    season_id, club_short_name, owner_id, starts_at, ends_at, day_count
  )
  VALUES (
    v_season_id, v_club, auth.uid(), v_starts, v_ends, v_days::smallint
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

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
  v_max integer;
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

  IF p_start_date < (timezone('Europe/London', now()))::date THEN
    RAISE EXCEPTION 'Holiday cannot start on a past day';
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

  v_max := public.club_holiday_max_days_per_season(v_row.owner_id);
  v_starts := (p_start_date::timestamp AT TIME ZONE 'Europe/London');
  v_ends := ((p_end_date + 1)::timestamp AT TIME ZONE 'Europe/London');
  v_days := public.club_holiday_inclusive_days(v_starts, v_ends);

  IF v_days > v_max THEN
    RAISE EXCEPTION 'A single booking cannot exceed % days', v_max;
  END IF;

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
  SET starts_at = v_starts, ends_at = v_ends, day_count = v_days::smallint
  WHERE id = p_holiday_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_preclub_holiday_book(
  p_start_date date,
  p_end_date date
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_starts timestamptz;
  v_ends timestamptz;
  v_days int;
  v_used int;
  v_max int := public.club_holiday_max_days_per_season(auth.uid());
  v_id bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF public.my_club_shortname() IS NOT NULL THEN
    RAISE EXCEPTION 'You have a club — book holidays on Club details instead';
  END IF;
  IF p_start_date IS NULL OR p_end_date IS NULL THEN
    RAISE EXCEPTION 'Start and end dates are required';
  END IF;
  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'End date must be on or after start date';
  END IF;

  IF p_start_date < (timezone('Europe/London', now()))::date THEN
    RAISE EXCEPTION 'Holiday cannot start on a past day';
  END IF;

  v_starts := (p_start_date::timestamp AT TIME ZONE 'Europe/London');
  v_ends := ((p_end_date + 1)::timestamp AT TIME ZONE 'Europe/London');
  v_days := public.club_holiday_inclusive_days(v_starts, v_ends);

  IF v_ends <= now() THEN
    RAISE EXCEPTION 'Holiday must end in the future';
  END IF;
  IF v_days > v_max THEN
    RAISE EXCEPTION 'A single booking cannot exceed % days', v_max;
  END IF;

  SELECT coalesce(sum(day_count), 0)::int INTO v_used
  FROM public.gpsl_preclub_holidays
  WHERE owner_id = auth.uid() AND ends_at > now();

  IF v_used + v_days > v_max THEN
    RAISE EXCEPTION 'Only % days of holiday per season (% booked, % requested)',
      v_max, v_used, v_days;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpsl_preclub_holidays h
    WHERE h.owner_id = auth.uid()
      AND h.starts_at < v_ends
      AND h.ends_at > v_starts
  ) THEN
    RAISE EXCEPTION 'Holiday overlaps one you already booked';
  END IF;

  INSERT INTO public.gpsl_preclub_holidays (owner_id, starts_at, ends_at, day_count)
  VALUES (auth.uid(), v_starts, v_ends, v_days::smallint)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_holiday_book(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_holiday_amend(bigint, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_preclub_holiday_book(date, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
