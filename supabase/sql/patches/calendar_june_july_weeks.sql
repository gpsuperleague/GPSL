-- Season calendar: season start Friday = GPSL June.
-- Every GPSL month is one real UK week (Fri 19:00 → Fri 19:00):
--   June → July → August → … → May → Playoffs (13 weeks).
--
-- Previously the anchor was August unlock and June/July were soft-only.

ALTER TABLE public.competition_season_calendar
  DROP CONSTRAINT IF EXISTS competition_season_calendar_gpsl_month_check;

ALTER TABLE public.competition_season_calendar
  ADD CONSTRAINT competition_season_calendar_gpsl_month_check
  CHECK (
    gpsl_month IN (
      'june', 'july',
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may', 'playoffs'
    )
  );

ALTER TABLE public.competition_season_calendar
  DROP CONSTRAINT IF EXISTS competition_season_calendar_sort_order_check;

ALTER TABLE public.competition_season_calendar
  ADD CONSTRAINT competition_season_calendar_sort_order_check
  CHECK (sort_order >= 1 AND sort_order <= 13);

DO $$
BEGIN
  ALTER TABLE public.competition_fixtures
    DROP CONSTRAINT IF EXISTS competition_fixtures_gpsl_month_check;
EXCEPTION WHEN undefined_object THEN
  NULL;
END $$;

ALTER TABLE public.competition_fixtures
  DROP CONSTRAINT IF EXISTS competition_fixtures_gpsl_month_check;

ALTER TABLE public.competition_fixtures
  ADD CONSTRAINT competition_fixtures_gpsl_month_check
  CHECK (
    gpsl_month IN (
      'june', 'july',
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may', 'playoffs'
    )
  );

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_sort(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'june' THEN 1
    WHEN 'july' THEN 2
    WHEN 'august' THEN 3
    WHEN 'september' THEN 4
    WHEN 'october' THEN 5
    WHEN 'november' THEN 6
    WHEN 'december' THEN 7
    WHEN 'january' THEN 8
    WHEN 'february' THEN 9
    WHEN 'march' THEN 10
    WHEN 'april' THEN 11
    WHEN 'may' THEN 12
    WHEN 'playoffs' THEN 13
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_label(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'playoffs' THEN 'Playoffs'
    ELSE initcap(lower(btrim(coalesce(p_month, ''))))
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_is_league_programme(p_month text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_month, ''))) IN (
    'august', 'september', 'october', 'november', 'december',
    'january', 'february', 'march', 'april', 'may'
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_is_preseason(p_month text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_month, ''))) IN ('june', 'july');
$$;

-- p_anchor_local = season start = GPSL June unlock (Fri 19:00 UK)
CREATE OR REPLACE FUNCTION public.competition_admin_set_season_calendar(
  p_season_id bigint,
  p_anchor_local timestamp without time zone
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_anchor timestamptz;
  v_months text[] := ARRAY[
    'june', 'july',
    'august', 'september', 'october', 'november', 'december',
    'january', 'february', 'march', 'april', 'may', 'playoffs'
  ];
  v_month text;
  v_i int;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_august timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE id = p_season_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  IF p_anchor_local IS NULL THEN
    RAISE EXCEPTION 'Season start date/time required';
  END IF;

  v_anchor := (p_anchor_local AT TIME ZONE 'Europe/London');

  IF extract(dow FROM (v_anchor AT TIME ZONE 'Europe/London'))::int <> 5 THEN
    RAISE EXCEPTION 'Season start must be a Friday in UK time (got %)',
      to_char(v_anchor AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY');
  END IF;

  IF extract(hour FROM (v_anchor AT TIME ZONE 'Europe/London'))::int <> 19 THEN
    RAISE EXCEPTION 'Season start must be 19:00 UK time (7pm)';
  END IF;

  DELETE FROM public.competition_season_calendar WHERE season_id = p_season_id;
  DELETE FROM public.competition_season_calendar_config WHERE season_id = p_season_id;

  -- Config anchor = June start (season start)
  INSERT INTO public.competition_season_calendar_config (season_id, anchor_unlock_at)
  VALUES (p_season_id, v_anchor);

  FOR v_i IN 1..array_length(v_months, 1) LOOP
    v_month := v_months[v_i];
    v_unlock := v_anchor + ((v_i - 1) * interval '7 days');
    v_lock := v_unlock + interval '7 days';

    INSERT INTO public.competition_season_calendar (
      season_id, gpsl_month, sort_order, unlock_at, lock_at
    )
    VALUES (p_season_id, v_month, v_i::smallint, v_unlock, v_lock);
  END LOOP;

  v_august := v_anchor + interval '14 days';

  RETURN jsonb_build_object(
    'season_id', p_season_id,
    'season_start_uk',
    to_char(v_anchor AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'anchor_uk',
    to_char(v_anchor AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'june_uk',
    to_char(v_anchor AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'july_uk',
    to_char((v_anchor + interval '7 days') AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'august_uk',
    to_char(v_august AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'months', 13,
    'season_ends_uk',
    to_char((v_anchor + interval '91 days') AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'note', 'Week 1=June, 2=July (pre-season), 3=August league start, … 13=Playoffs.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_season_calendar(bigint, timestamp)
  TO authenticated;

-- Sport preseason window: prefer real June/July calendar rows
CREATE OR REPLACE FUNCTION public.gpsl_sport_preseason_window(p_season_id bigint)
RETURNS TABLE (
  august_start timestamptz,
  may_end timestamptz,
  preseason_start timestamptz,
  preseason_weeks numeric,
  june_window_start timestamptz,
  june_window_end timestamptz,
  july_window_start timestamptz,
  july_window_end timestamptz,
  publish_june_at timestamptz,
  publish_july_at timestamptz,
  include_june boolean,
  include_july boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_june public.competition_season_calendar%ROWTYPE;
  v_july public.competition_season_calendar%ROWTYPE;
  v_august timestamptz;
BEGIN
  SELECT * INTO v_june
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND c.gpsl_month = 'june'
  LIMIT 1;

  SELECT * INTO v_july
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND c.gpsl_month = 'july'
  LIMIT 1;

  SELECT c.unlock_at INTO v_august
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND c.gpsl_month = 'august'
  LIMIT 1;

  IF v_august IS NULL THEN
    SELECT cfg.anchor_unlock_at INTO v_august
    FROM public.competition_season_calendar_config cfg
    WHERE cfg.season_id = p_season_id;
  END IF;

  IF v_august IS NULL THEN
    RETURN;
  END IF;

  -- New model: explicit June/July weeks on the calendar
  IF v_june.unlock_at IS NOT NULL AND v_july.unlock_at IS NOT NULL THEN
    august_start := v_august;
    may_end := NULL;
    preseason_start := v_june.unlock_at;
    preseason_weeks := 2;
    june_window_start := v_june.unlock_at;
    june_window_end := v_june.lock_at;
    july_window_start := v_july.unlock_at;
    july_window_end := v_july.lock_at;
    publish_june_at := v_june.unlock_at;
    publish_july_at := v_july.unlock_at;
    include_june := true;
    include_july := true;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Legacy fallback: soft 2-week preseason before August
  august_start := v_august;
  may_end := NULL;
  preseason_start := v_august - interval '14 days';
  preseason_weeks := 2;
  june_window_start := v_august - interval '14 days';
  june_window_end := v_august - interval '7 days';
  july_window_start := v_august - interval '7 days';
  july_window_end := v_august;
  publish_june_at := june_window_start;
  publish_july_at := july_window_start;
  include_june := true;
  include_july := true;
  RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_preseason_window(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
