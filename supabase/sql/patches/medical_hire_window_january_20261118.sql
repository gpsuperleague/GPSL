-- Medical staff hiring also opens in GPSL January (with June–August and pre-season).
-- Doctor and physio hires. Treatment of current injuries is unchanged.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.medical_staff_hire_window_status(
  p_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_season bigint;
  v_month text;
  v_open boolean := false;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NOT NULL
     AND to_regprocedure('public.competition_active_gpsl_month(bigint,timestamptz)') IS NOT NULL THEN
    v_month := public.competition_active_gpsl_month(v_season, coalesce(p_at, now()));
  END IF;

  v_month := lower(nullif(btrim(coalesce(v_month, '')), ''));

  IF v_month IS NULL
     OR v_month IN ('pre_season', 'preseason', 'june', 'july', 'august', 'january')
     OR (
       to_regprocedure('public.competition_gpsl_month_is_preseason(text)') IS NOT NULL
       AND public.competition_gpsl_month_is_preseason(v_month)
     ) THEN
    v_open := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'open', v_open,
    'active_gpsl_month', v_month,
    'open_months', jsonb_build_array('june', 'july', 'august', 'january'),
    'message', CASE
      WHEN v_open THEN
        'Medical staff hiring is open (June–August and January).'
      ELSE
        'Medical staff hiring is closed. Hire doctors and physios in June–August and January. Treatment of current injuries stays available.'
    END
  );
END;
$fn$;

NOTIFY pgrst, 'reload schema';

SELECT public.medical_staff_hire_window_status() AS live;
