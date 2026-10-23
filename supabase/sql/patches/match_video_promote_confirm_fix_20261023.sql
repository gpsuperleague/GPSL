-- =============================================================================
-- Fix: result confirm fails with "Not allowed" when pending match video exists
-- =============================================================================
-- Confirm → fixture played → promote pending Discord video → ingest_attachment
-- which required service_role / is_gpsl_admin(). Confirming owner (e.g. BAR)
-- was blocked and the whole confirm rolled back.
--
-- 1) Promote sets transaction-local GUC gpsl.match_video_internal=1
-- 2) Ingest allows that GUC (internal promote path)
-- 3) Trigger swallows promote errors so confirm never fails on video settle
-- Safe re-run.
-- =============================================================================

-- 1) Soft-patch ingest auth gate (keep full live body)
DO $patch$
DECLARE
  v_oid regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT p.oid::regprocedure INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'match_video_ingest_attachment'
  ORDER BY p.oid DESC
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE NOTICE 'match_video_ingest_attachment missing — skip gate patch';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);

  IF position('gpsl.match_video_internal' IN v_def) > 0 THEN
    RAISE NOTICE 'ingest already allows internal promote GUC';
    RETURN;
  END IF;

  v_old := $n$IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;$n$;

  v_new := $n$IF coalesce(nullif(current_setting('gpsl.match_video_internal', true), ''), '') NOT IN ('1', 'true', 'on')
     AND coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_gpsl_admin()
  THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;$n$;

  IF position(v_old IN v_def) = 0 THEN
    -- Whitespace / CRLF variants
    v_old := replace(v_old, E'\n', E'\r\n');
    v_new := replace(v_new, E'\n', E'\r\n');
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'ingest auth gate needle not found — patch trigger + promote only';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'match_video_ingest_attachment: internal promote GUC allowed';
END;
$patch$;

-- 2) Promote: set internal GUC for the transaction
CREATE OR REPLACE FUNCTION public.match_video_promote_pending_for_fixture(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%ROWTYPE;
  v_pend public.fixture_match_video_pending%ROWTYPE;
  v_check jsonb;
  v_n int := 0;
  v_fail int := 0;
  v_ingest jsonb;
BEGIN
  -- Allow match_video_ingest_attachment when called from result-confirm path
  PERFORM set_config('gpsl.match_video_internal', '1', true);

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  IF v_fixture.status IS DISTINCT FROM 'played'
     OR v_fixture.home_goals IS NULL
     OR v_fixture.away_goals IS NULL
  THEN
    RETURN jsonb_build_object('ok', true, 'promoted', 0, 'reason', 'not_played_yet');
  END IF;

  FOR v_pend IN
    SELECT * FROM public.fixture_match_video_pending p
    WHERE p.fixture_id = p_fixture_id
    ORDER BY p.id
  LOOP
    v_check := public.match_video_scores_match_fixture(v_fixture, v_pend.parsed);
    IF coalesce((v_check->>'ok')::boolean, false) IS NOT TRUE THEN
      v_fail := v_fail + 1;
      CONTINUE;
    END IF;

    v_ingest := public.match_video_ingest_attachment(
      v_pend.discord_message_id,
      v_pend.discord_channel_id,
      v_pend.discord_attachment_id,
      v_pend.discord_user_id,
      v_pend.club_short_name,
      coalesce(v_pend.filename, ''),
      v_pend.video_url,
      v_pend.gpsl_month,
      v_pend.source
    );

    IF coalesce((v_ingest->>'ok')::boolean, false)
       AND coalesce(v_ingest->>'status', '') IN ('matched', 'duplicate') THEN
      DELETE FROM public.fixture_match_video_pending WHERE id = v_pend.id;
      v_n := v_n + 1;
    ELSE
      v_fail := v_fail + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'promoted', v_n,
    'failed', v_fail
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_promote_pending_for_fixture(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_promote_pending_for_fixture(bigint)
  TO authenticated, service_role;

-- 3) Never abort result confirm if video promote fails
CREATE OR REPLACE FUNCTION public.trg_match_video_promote_on_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status = 'played'
     AND OLD.status IS DISTINCT FROM 'played'
     AND NEW.home_goals IS NOT NULL
     AND NEW.away_goals IS NOT NULL
  THEN
    BEGIN
      PERFORM public.match_video_promote_pending_for_fixture(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'match_video_promote_pending_for_fixture(%) failed: %',
        NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS match_video_promote_on_played ON public.competition_fixtures;
CREATE TRIGGER match_video_promote_on_played
  AFTER UPDATE OF status, home_goals, away_goals ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_match_video_promote_on_played();

NOTIFY pgrst, 'reload schema';
