-- =============================================================================
-- No manager → cannot arrange fixtures (propose / accept kick-off times)
--
-- Extends manager_required_for_matches.sql. Vacant clubs may still hire from
-- the Manager Transfer Market, but cannot schedule until a manager is signed.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_assert_has_manager_for_matches(p_club_short text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.club_has_signed_manager(p_club_short) THEN
    RAISE EXCEPTION
      'Club % has no manager — sign one from the Manager Transfer Market before arranging or playing fixtures.',
      coalesce(nullif(btrim(p_club_short), ''), '?');
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_assert_has_manager_for_matches(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Inject assert into propose / accept (live function bodies)
-- ---------------------------------------------------------------------------

DO $inject_propose$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text := $n$v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;$n$;
  v_insert text := $n$v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.club_assert_has_manager_for_matches(v_club);$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'fixture_schedule_propose'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE WARNING 'fixture_schedule_propose missing';
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF v_src LIKE '%club_assert_has_manager_for_matches%' THEN
    RAISE NOTICE 'fixture_schedule_propose already guarded';
    RETURN;
  END IF;

  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'fixture_schedule_propose: needle not found';
    RETURN;
  END IF;

  EXECUTE replace(v_src, v_needle, v_insert);
END;
$inject_propose$;

DO $inject_accept$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text := $n$v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;$n$;
  v_insert text := $n$v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.club_assert_has_manager_for_matches(v_club);$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'fixture_schedule_accept'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE WARNING 'fixture_schedule_accept missing';
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF v_src LIKE '%club_assert_has_manager_for_matches%' THEN
    RAISE NOTICE 'fixture_schedule_accept already guarded';
    RETURN;
  END IF;

  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'fixture_schedule_accept: needle not found';
    RETURN;
  END IF;

  EXECUTE replace(v_src, v_needle, v_insert);
END;
$inject_accept$;

-- Mutual override request (play now / change kick-off)
DO $inject_mutual$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text := $n$v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;$n$;
  v_insert text := $n$v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  PERFORM public.club_assert_has_manager_for_matches(v_club);$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'fixture_mutual_override_request'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF v_src LIKE '%club_assert_has_manager_for_matches%' THEN
    RETURN;
  END IF;

  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'fixture_mutual_override_request: needle not found';
    RETURN;
  END IF;

  EXECUTE replace(v_src, v_needle, v_insert);
END;
$inject_mutual$;

-- ---------------------------------------------------------------------------
-- Hide propose / respond UI flags when caller has no manager
-- ---------------------------------------------------------------------------

DO $inject_ctx_arrange$
DECLARE
  v_oid oid;
  v_src text;
  v_old text := $o$'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled'),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating'),$o$;
  v_new text := $n$'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND public.club_has_signed_manager(v_club)),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating' AND public.club_has_signed_manager(v_club)),
    'my_has_manager', coalesce((SELECT public.club_has_signed_manager(v_club)), false),$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'match_schedule_fixture_context'
    AND pg_get_function_identity_arguments(p.oid) = 'bigint'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);

  -- If an earlier patch already added my_has_manager inside checkin, only gate propose/respond
  IF position(v_old IN v_src) > 0 THEN
    IF v_src LIKE '%can_propose_first%, (v_role = ''home'' AND v_status = ''unscheduled'' AND v_fixture.status = ''scheduled'' AND public.club_has_signed_manager(v_club))%'
       OR v_src LIKE '%club_has_signed_manager(v_club)),%can_respond%'
       OR position('can_propose_first'', (v_role = ''home'' AND v_status = ''unscheduled'' AND v_fixture.status = ''scheduled'' AND public.club_has_signed_manager(v_club))' IN v_src) > 0
    THEN
      RAISE NOTICE 'can_propose_first already manager-gated';
    ELSE
      -- Prefer gated flags without duplicating my_has_manager if already present
      IF v_src LIKE '%my_has_manager%' THEN
        v_new := $n$'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND public.club_has_signed_manager(v_club)),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating' AND public.club_has_signed_manager(v_club)),$n$;
      END IF;
      v_src := replace(v_src, v_old, v_new);
      EXECUTE v_src;
      RETURN;
    END IF;
  ELSE
    RAISE WARNING 'match_schedule_fixture_context: can_propose_first needle not found';
  END IF;
END;
$inject_ctx_arrange$;

NOTIFY pgrst, 'reload schema';
