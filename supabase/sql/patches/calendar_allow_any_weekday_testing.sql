-- =============================================================================
-- Calendar: allow any weekday for testing (still 19:00 UK)
--
-- Production default: Friday 19:00 UK.
-- Testing: pass p_allow_any_weekday := true to start e.g. tonight 19:00.
-- Safe re-run.
-- =============================================================================

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

DROP FUNCTION IF EXISTS public.competition_admin_set_season_calendar(bigint, timestamp);
DROP FUNCTION IF EXISTS public.competition_admin_set_season_calendar(bigint, timestamp without time zone);
DROP FUNCTION IF EXISTS public.competition_admin_set_season_calendar(bigint, text);
DROP FUNCTION IF EXISTS public.competition_admin_set_season_calendar(bigint, text, boolean);

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
    RAISE EXCEPTION 'Season start date/time required (19:00 UK)';
  END IF;

  v_raw := replace(v_raw, 'T', ' ');
  IF length(v_raw) = 16 THEN
    v_raw := v_raw || ':00';
  END IF;

  BEGIN
    v_local := v_raw::timestamp without time zone;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION
      'Could not parse season start "%" — use YYYY-MM-DD HH:MM (19:00 UK)',
      p_anchor_local;
  END;

  v_anchor := v_local AT TIME ZONE 'Europe/London';
  v_uk := v_anchor AT TIME ZONE 'Europe/London';

  IF NOT v_allow AND extract(dow FROM v_uk)::int <> 5 THEN
    RAISE EXCEPTION
      'Season start must be a Friday in UK time (got %). Tick “Allow any weekday (testing)” to override.',
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
        'Testing override: start is not Friday. Weeks still run 7 days each (June→Playoffs).'
      ELSE
        'Week 1=June, 2=July (pre-season), 3=August league start, … 13=Playoffs.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_season_calendar(bigint, text, boolean)
  TO authenticated;
