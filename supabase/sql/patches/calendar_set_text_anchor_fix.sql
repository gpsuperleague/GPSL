-- =============================================================================
-- Harden GPSL season calendar set (June start, Fri 19:00 UK)
--
-- Symptom: competition_admin_set_season_calendar → 400 Bad Request
-- Common causes:
--   • June/July CHECK constraint / sort_order<=11 not updated
--   • timestamp casting from the browser string fails Friday/19:00 checks
--
-- Fix: ensure constraints, accept text wall-clock anchor, clear errors.
-- Safe re-run. Also re-run seed_divisions_standings_any_season_fix.sql if seed
-- still fails (historical standings must ignore live-month deferral).
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

-- Prefer a single text signature (avoids PostgREST timestamp cast ambiguity)
DROP FUNCTION IF EXISTS public.competition_admin_set_season_calendar(bigint, timestamp);
DROP FUNCTION IF EXISTS public.competition_admin_set_season_calendar(bigint, timestamp without time zone);
DROP FUNCTION IF EXISTS public.competition_admin_set_season_calendar(bigint, text);

CREATE OR REPLACE FUNCTION public.competition_admin_set_season_calendar(
  p_season_id bigint,
  p_anchor_local text
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
    RAISE EXCEPTION 'Season start date/time required (Friday 19:00 UK)';
  END IF;

  -- Accept "YYYY-MM-DD HH:MM[:SS]" or "YYYY-MM-DDTHH:MM[:SS]"
  v_raw := replace(v_raw, 'T', ' ');
  IF length(v_raw) = 16 THEN
    v_raw := v_raw || ':00';
  END IF;

  BEGIN
    v_local := v_raw::timestamp without time zone;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION
      'Could not parse season start "%" — use YYYY-MM-DD HH:MM (Friday 19:00 UK)',
      p_anchor_local;
  END;

  -- Interpret wall clock as Europe/London
  v_anchor := v_local AT TIME ZONE 'Europe/London';
  v_uk := v_anchor AT TIME ZONE 'Europe/London';

  IF extract(dow FROM v_uk)::int <> 5 THEN
    RAISE EXCEPTION
      'Season start must be a Friday in UK time (got % %)',
      to_char(v_uk, 'Dy DD Mon YYYY HH24:MI'),
      'UK';
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
    'season_start_uk', to_char(v_uk, 'YYYY-MM-DD HH24:MI'),
    'anchor_uk', to_char(v_uk, 'YYYY-MM-DD HH24:MI'),
    'june_uk', to_char(v_uk, 'YYYY-MM-DD HH24:MI'),
    'july_uk', to_char((v_anchor + interval '7 days') AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'august_uk', to_char(v_august AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'months', 13,
    'season_ends_uk',
    to_char((v_anchor + interval '91 days') AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'note', 'Week 1=June, 2=July (pre-season), 3=August league start, … 13=Playoffs.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_season_calendar(bigint, text)
  TO authenticated;
