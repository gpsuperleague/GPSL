-- =============================================================================
-- GPSL weeks run Thursday 19:00 UK → Thursday 19:00 UK (was Friday)
--
--   1. competition_admin_set_season_calendar: season start must be a Thursday
--      (the "allow any weekday" override still works).
--   2. stadium_next_friday_7pm_uk_after: build weeks now tick on the next real
--      GPSL month boundary from the calendar (fallback: next Thursday 19:00).
--   3. Owner-facing error / info text in DB functions: "Fri 19:00" → "Thu 19:00".
--
-- Existing calendars are NOT moved. Re-set the season calendar in
-- Admin → Season with a Thursday start (pre-season only).
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Calendar setter (Thursday default)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_set_season_calendar(
  p_season_id bigint,
  p_anchor_local text,
  p_allow_any_weekday boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_raw text := btrim(coalesce(p_anchor_local, ''));
  v_local timestamp without time zone;
  v_anchor timestamptz;
  v_uk timestamp without time zone;
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
  v_allow boolean := coalesce(p_allow_any_weekday, false);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE id = p_season_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season not found (id %)', p_season_id;
  END IF;

  IF v_raw = '' THEN
    RAISE EXCEPTION 'Season start date/time required (Thursday 19:00 UK)';
  END IF;

  v_raw := replace(v_raw, 'T', ' ');
  IF length(v_raw) = 16 THEN
    v_raw := v_raw || ':00';
  END IF;

  BEGIN
    v_local := v_raw::timestamp without time zone;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION
      'Could not parse season start "%" — use YYYY-MM-DD HH:MM (Thursday 19:00 UK)',
      p_anchor_local;
  END;

  v_anchor := v_local AT TIME ZONE 'Europe/London';
  v_uk := v_anchor AT TIME ZONE 'Europe/London';

  IF NOT v_allow AND extract(dow FROM v_uk)::int <> 4 THEN
    RAISE EXCEPTION
      'Season start must be a Thursday in UK time (got %). Tick “Allow any weekday (testing)” to override.',
      to_char(v_uk, 'Dy DD Mon YYYY HH24:MI');
  END IF;

  IF extract(hour FROM v_uk)::int <> 19 OR extract(minute FROM v_uk)::int <> 0 THEN
    RAISE EXCEPTION
      'Season start must be exactly 19:00 UK time (got %)',
      to_char(v_uk, 'HH24:MI');
  END IF;

  DELETE FROM public.competition_season_calendar WHERE season_id = p_season_id;
  DELETE FROM public.competition_season_calendar_config WHERE season_id = p_season_id;

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
    'ok', true,
    'season_id', p_season_id,
    'season_label', v_season.label,
    'allow_any_weekday', v_allow,
    'season_start_uk', to_char(v_uk, 'YYYY-MM-DD HH24:MI'),
    'anchor_uk', to_char(v_uk, 'YYYY-MM-DD HH24:MI'),
    'june_uk', to_char(v_uk, 'YYYY-MM-DD HH24:MI'),
    'july_uk', to_char((v_anchor + interval '7 days') AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'august_uk', to_char(v_august AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'months', 13,
    'season_ends_uk',
    to_char((v_anchor + interval '91 days') AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'note', CASE
      WHEN v_allow THEN
        'Weekday override on. Weeks still run 7 days each (June→Playoffs).'
      ELSE
        'Week 1=June, 2=July (pre-season), 3=August league start, … 13=Playoffs. Thu 19:00 → Thu 19:00 UK.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_season_calendar(bigint, text, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Stadium build weeks follow the GPSL calendar boundary
--    (name kept so existing callers keep working)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stadium_next_friday_7pm_uk_after(p_ts timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_next timestamptz;
  v_local timestamp;
  v_days int;
  v_candidate timestamp;
BEGIN
  SELECT min(m.lock_at) INTO v_next
  FROM public.competition_season_calendar m
  JOIN public.competition_seasons s ON s.id = m.season_id
  WHERE s.is_current = true
    AND m.lock_at > p_ts;

  IF v_next IS NOT NULL THEN
    RETURN v_next;
  END IF;

  -- No calendar boundary ahead: next Thursday 19:00 UK
  v_local := p_ts AT TIME ZONE 'Europe/London';
  v_days := (4 - extract(dow FROM v_local)::int + 7) % 7;
  v_candidate := date_trunc('day', v_local) + make_interval(days => v_days) + interval '19 hours';
  IF v_candidate <= v_local THEN
    v_candidate := v_candidate + interval '7 days';
  END IF;
  RETURN v_candidate AT TIME ZONE 'Europe/London';
END;
$function$;

COMMENT ON FUNCTION public.stadium_next_friday_7pm_uk_after(timestamptz) IS
  'Next GPSL week boundary after p_ts (calendar lock_at; fallback Thursday 19:00 UK). Name kept for callers.';

-- ---------------------------------------------------------------------------
-- 3. Owner-facing wording in existing functions: Friday → Thursday
-- ---------------------------------------------------------------------------
DO $reword$
DECLARE
  r record;
  v_def text;
  v_new text;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname NOT IN ('competition_admin_set_season_calendar', 'stadium_next_friday_7pm_uk_after')
      AND p.proname NOT LIKE 'owner_inbox_test%'
      AND (
        p.prosrc LIKE '%Fri 19:00%'
        OR p.prosrc LIKE '%Friday 19:00%'
      )
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := replace(v_def, 'first Friday 19:00', 'first Thursday 19:00');
    v_new := replace(v_new, 'Friday 19:00', 'Thursday 19:00');
    v_new := replace(v_new, 'Fri 19:00', 'Thu 19:00');
    IF v_new <> v_def THEN
      EXECUTE v_new;
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'Reworded % function(s) to Thursday 19:00', v_count;
END;
$reword$;

NOTIFY pgrst, 'reload schema';
