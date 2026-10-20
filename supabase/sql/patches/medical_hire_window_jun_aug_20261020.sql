-- =============================================================================
-- Medical staff hiring window: open June–August only (closed September–May)
-- Applies to doctor + physio hires. Treating injuries / tokens stay available.
-- Safe re-run.
-- =============================================================================

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

  -- Open in pre-season / June / July / August (and null month before campaign)
  IF v_month IS NULL
     OR v_month IN ('pre_season', 'preseason', 'june', 'july', 'august')
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
    'open_months', jsonb_build_array('june', 'july', 'august'),
    'message', CASE
      WHEN v_open THEN
        'Medical staff hiring is open (June–August).'
      ELSE
        'Medical staff hiring is closed from September through May. Hire doctors and physios in June–August only. Treatment of current injuries stays available.'
    END
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.medical_staff_hire_window_is_open(
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((public.medical_staff_hire_window_status(p_at)->>'open')::boolean, false);
$$;

CREATE OR REPLACE FUNCTION public.medical_assert_staff_hire_open()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_st jsonb;
BEGIN
  v_st := public.medical_staff_hire_window_status(now());
  IF coalesce((v_st->>'open')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION '%',
      coalesce(v_st->>'message',
        'Medical staff hiring is closed from September through May');
  END IF;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.medical_staff_hire_window_status(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_staff_hire_window_is_open(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_assert_staff_hire_open() TO authenticated;

-- ---------------------------------------------------------------------------
-- Guard hire RPCs
-- ---------------------------------------------------------------------------
DO $inject_physio$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text;
  v_insert text;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'medical_hire_physio'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE WARNING 'medical_hire_physio missing';
    RETURN;
  END IF;

  v_src := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  IF position('medical_assert_staff_hire_open' IN v_src) > 0 THEN
    RAISE NOTICE 'medical_hire_physio already hire-window guarded';
    RETURN;
  END IF;

  v_needle := replace($n$  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;$n$, E'\r\n', E'\n');

  v_insert := replace($n$  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.medical_assert_staff_hire_open();$n$, E'\r\n', E'\n');

  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'medical_hire_physio: club needle not found';
    RETURN;
  END IF;

  EXECUTE replace(v_src, v_needle, v_insert);
  RAISE NOTICE 'medical_hire_physio: hire window guarded';
END;
$inject_physio$;

DO $inject_doctor$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text;
  v_insert text;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'medical_hire_doctor'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE WARNING 'medical_hire_doctor missing';
    RETURN;
  END IF;

  v_src := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  IF position('medical_assert_staff_hire_open' IN v_src) > 0 THEN
    RAISE NOTICE 'medical_hire_doctor already hire-window guarded';
    RETURN;
  END IF;

  v_needle := replace($n$  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;$n$, E'\r\n', E'\n');

  v_insert := replace($n$  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.medical_assert_staff_hire_open();$n$, E'\r\n', E'\n');

  IF position(v_needle IN v_src) = 0 THEN
    -- older variants may use slightly different wording
    v_needle := replace($n$  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;$n$, E'\r\n', E'\n');
    v_insert := replace($n$  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.medical_assert_staff_hire_open();$n$, E'\r\n', E'\n');
  END IF;

  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'medical_hire_doctor: club needle not found';
    RETURN;
  END IF;

  EXECUTE replace(v_src, v_needle, v_insert);
  RAISE NOTICE 'medical_hire_doctor: hire window guarded';
END;
$inject_doctor$;

-- ---------------------------------------------------------------------------
-- Expose window on medical_room_state + disable hireable when closed
-- ---------------------------------------------------------------------------
DO $inject_state$
DECLARE
  v_def text;
  v_old_hireable text;
  v_new_hireable text;
  v_old_ret text;
  v_new_ret text;
BEGIN
  IF to_regprocedure('public.medical_room_state(text)') IS NULL THEN
    RAISE NOTICE 'medical_room_state missing';
    RETURN;
  END IF;

  SELECT replace(pg_get_functiondef('public.medical_room_state(text)'::regprocedure), E'\r\n', E'\n')
    INTO v_def;

  IF position('hire_window_open' IN v_def) > 0 THEN
    RAISE NOTICE 'medical_room_state already has hire window';
    RETURN;
  END IF;

  v_old_hireable := replace(
    $n$'hireable', (v_next_slot IS NOT NULL AND g.slot = v_next_slot)$n$,
    E'\r\n', E'\n'
  );
  v_new_hireable := replace(
    $n$'hireable', (
        v_next_slot IS NOT NULL
        AND g.slot = v_next_slot
        AND public.medical_staff_hire_window_is_open()
      )$n$,
    E'\r\n', E'\n'
  );

  IF position(v_old_hireable IN v_def) > 0 THEN
    v_def := replace(v_def, v_old_hireable, v_new_hireable);
  ELSE
    RAISE WARNING 'medical_room_state: hireable needle not found';
  END IF;

  v_old_ret := replace($n$    'contract_seasons', 3,
    'physio_ladder', true
  );$n$, E'\r\n', E'\n');
  v_new_ret := replace($n$    'contract_seasons', 3,
    'physio_ladder', true,
    'hire_window_open', public.medical_staff_hire_window_is_open(),
    'hire_window', public.medical_staff_hire_window_status()
  );$n$, E'\r\n', E'\n');

  IF position(v_old_ret IN v_def) = 0 THEN
    RAISE WARNING 'medical_room_state: return needle not found — hire guards still apply in hire RPCs';
    -- still apply hireable change if we already mutated v_def
    IF position('medical_staff_hire_window_is_open()' IN v_def) > 0
       AND position('''hireable''' IN v_def) > 0 THEN
      EXECUTE v_def;
    END IF;
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old_ret, v_new_ret);
  RAISE NOTICE 'medical_room_state: hire window fields added';
END;
$inject_state$;

NOTIFY pgrst, 'reload schema';
