-- =============================================================================
-- Supporter holiday allowance: 21 days / season while supporter is active
-- Non-supporters (and lapsed): remain 14 days
--
-- Safe re-run. Uses owner_is_supporter_active (Ko-fi / grace).
-- =============================================================================

-- Single booking / row may be up to 21 days for supporters
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname, c.conrelid::regclass AS tbl
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
    WHERE c.contype = 'c'
      AND c.conrelid IN (
        'public.club_owner_holidays'::regclass,
        'public.gpsl_preclub_holidays'::regclass
      )
      AND a.attname = 'day_count'
      AND pg_get_constraintdef(c.oid) ILIKE '%14%'
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
  END LOOP;

  ALTER TABLE public.club_owner_holidays
    DROP CONSTRAINT IF EXISTS club_owner_holidays_day_count_check;
  ALTER TABLE public.club_owner_holidays
    ADD CONSTRAINT club_owner_holidays_day_count_check
    CHECK (day_count >= 1 AND day_count <= 21);

  IF to_regclass('public.gpsl_preclub_holidays') IS NOT NULL THEN
    ALTER TABLE public.gpsl_preclub_holidays
      DROP CONSTRAINT IF EXISTS gpsl_preclub_holidays_day_count_check;
    ALTER TABLE public.gpsl_preclub_holidays
      ADD CONSTRAINT gpsl_preclub_holidays_day_count_check
      CHECK (day_count >= 1 AND day_count <= 21);
  END IF;
END;
$$;

-- Recreate view after replacing the max-days helper
DROP VIEW IF EXISTS public.club_owner_holidays_public;
DROP FUNCTION IF EXISTS public.club_holiday_max_days_per_season();
DROP FUNCTION IF EXISTS public.club_holiday_max_days_per_season(uuid);

CREATE OR REPLACE FUNCTION public.club_holiday_max_days_per_season(
  p_owner_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := coalesce(p_owner_id, auth.uid());
BEGIN
  IF v_owner IS NOT NULL
     AND to_regprocedure('public.owner_is_supporter_active(uuid)') IS NOT NULL
     AND public.owner_is_supporter_active(v_owner) THEN
    RETURN 21;
  END IF;
  RETURN 14;
END;
$function$;

COMMENT ON FUNCTION public.club_holiday_max_days_per_season(uuid) IS
  'Season holiday day cap: 21 while owner_is_supporter_active, else 14. Defaults to auth.uid().';

GRANT EXECUTE ON FUNCTION public.club_holiday_max_days_per_season(uuid) TO authenticated;

-- Quota helper for UI (works even with zero bookings)
CREATE OR REPLACE FUNCTION public.club_holiday_my_quota()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(public.my_club_shortname(), '')), '');
  v_season bigint;
  v_max int := public.club_holiday_max_days_per_season(auth.uid());
  v_used int := 0;
  v_supporter boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF to_regprocedure('public.owner_is_supporter_active(uuid)') IS NOT NULL THEN
    v_supporter := public.owner_is_supporter_active(auth.uid());
  END IF;

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_club IS NOT NULL AND v_season IS NOT NULL THEN
    v_used := public.club_holiday_days_used(v_season, v_club);
  ELSIF v_season IS NULL AND to_regclass('public.gpsl_preclub_holidays') IS NOT NULL THEN
    SELECT coalesce(sum(h.day_count), 0)::int INTO v_used
    FROM public.gpsl_preclub_holidays h
    WHERE h.owner_id = auth.uid()
      AND h.ends_at > now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'max_days', v_max,
    'days_used', v_used,
    'days_remaining', greatest(0, v_max - v_used),
    'supporter_active', v_supporter,
    'season_id', v_season,
    'club_short_name', v_club
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_holiday_my_quota() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_holiday_my_quota() TO authenticated;

-- Public view: allowance from booking owner (supporters see 21)
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
  (now() >= h.ends_at) AS is_ended
FROM public.club_owner_holidays h
JOIN public.competition_seasons s ON s.id = h.season_id
WHERE s.is_current = true
  AND s.status IN ('active', 'preseason')
  AND h.club_short_name = public.my_club_shortname();

GRANT SELECT ON public.club_owner_holidays_public TO authenticated;

-- Owner book: use auth.uid() cap (via default)
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

-- Admin amend/book use the club owner's supporter status
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
  v_max integer;
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

  v_max := public.club_holiday_max_days_per_season(v_row.owner_id);
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

  UPDATE public.club_owner_holidays
  SET starts_at = v_starts, ends_at = v_ends, day_count = v_days::smallint
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
  v_max integer;
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

  v_max := public.club_holiday_max_days_per_season(v_owner_id);

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
    season_id, club_short_name, owner_id, starts_at, ends_at, day_count
  )
  VALUES (
    v_season_id, v_club, v_owner_id, v_starts, v_ends, v_days::smallint
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

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
  v_owner uuid;
  v_max int := 14;
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

  IF v_club IS NOT NULL THEN
    SELECT c.owner_id INTO v_owner
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;
    v_max := public.club_holiday_max_days_per_season(v_owner);
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object(
      'season_id', null,
      'max_days', v_max,
      'holidays', '[]'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'max_days', v_max,
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
          'max_days', public.club_holiday_max_days_per_season(h.owner_id),
          'supporter_active', CASE
            WHEN to_regprocedure('public.owner_is_supporter_active(uuid)') IS NOT NULL
              THEN public.owner_is_supporter_active(h.owner_id)
            ELSE false
          END,
          'created_at', h.created_at,
          'is_active', (now() >= h.starts_at AND now() < h.ends_at),
          'is_upcoming', (now() < h.starts_at),
          'is_ended', (now() >= h.ends_at)
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

-- Pre-club list/book
CREATE OR REPLACE FUNCTION public.owner_preclub_holiday_list()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'max_days', public.club_holiday_max_days_per_season(auth.uid()),
    'supporter_active', CASE
      WHEN to_regprocedure('public.owner_is_supporter_active(uuid)') IS NOT NULL
        THEN public.owner_is_supporter_active(auth.uid())
      ELSE false
    END,
    'holidays', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', h.id,
        'starts_at', h.starts_at,
        'ends_at', h.ends_at,
        'day_count', h.day_count
      ) ORDER BY h.starts_at)
      FROM public.gpsl_preclub_holidays h
      WHERE h.owner_id = auth.uid()
        AND h.ends_at > now()
    ), '[]'::jsonb)
  );
$$;

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

NOTIFY pgrst, 'reload schema';
