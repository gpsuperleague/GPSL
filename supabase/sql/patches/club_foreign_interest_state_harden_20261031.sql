-- =============================================================================
-- Harden club_foreign_interest_state (squad.html 500)
--
-- Symptom: POST /rpc/club_foreign_interest_state → 500, squad badge blip on load.
-- Cause: sync_club_foreign_tracking / pick path can raise (missing pool table,
-- lock, etc.) and the state RPC re-raised to the client.
--
-- Fix: never 500 the dashboard badge — return stored Clubs columns on failure;
-- sync best-effort. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.sync_club_foreign_tracking(p_club_short text)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_need int;
  v_current text[];
BEGIN
  SELECT
    greatest(coalesce(c.foreign_interest_remaining, 0), 0),
    coalesce(c.foreign_tracking_teams, '{}')
  INTO v_need, v_current
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN '{}';
  END IF;

  IF v_need <= 0 THEN
    UPDATE public."Clubs" c
    SET foreign_tracking_teams = '{}'
    WHERE c."ShortName" = p_club_short;
    RETURN '{}';
  END IF;

  IF coalesce(array_length(v_current, 1), 0) = v_need THEN
    RETURN v_current;
  END IF;

  BEGIN
    IF to_regclass('public."Foreign_Interest_Teams"') IS NULL THEN
      RETURN coalesce(v_current, '{}');
    END IF;
    v_current := public.pick_foreign_tracking_teams(p_club_short, v_need);
  EXCEPTION WHEN OTHERS THEN
    RETURN coalesce(v_current, '{}');
  END;

  UPDATE public."Clubs" c
  SET foreign_tracking_teams = coalesce(v_current, '{}')
  WHERE c."ShortName" = p_club_short;

  RETURN coalesce(v_current, '{}');
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_foreign_interest_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_remaining int := 0;
  v_teams text[] := '{}';
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_authenticated',
      'foreign_interest_remaining', 0,
      'tracking_teams', '[]'::jsonb
    );
  END IF;

  BEGIN
    v_club := public.my_club_shortname();
  EXCEPTION WHEN OTHERS THEN
    v_club := NULL;
  END;

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_club',
      'foreign_interest_remaining', 0,
      'tracking_teams', '[]'::jsonb
    );
  END IF;

  SELECT
    greatest(coalesce(c.foreign_interest_remaining, 0), 0),
    coalesce(c.foreign_tracking_teams, '{}')
  INTO v_remaining, v_teams
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'club_not_found',
      'club_shortname', v_club,
      'foreign_interest_remaining', 0,
      'tracking_teams', '[]'::jsonb
    );
  END IF;

  BEGIN
    v_teams := public.sync_club_foreign_tracking(v_club);
    SELECT greatest(coalesce(c.foreign_interest_remaining, 0), 0)
    INTO v_remaining
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;
  EXCEPTION WHEN OTHERS THEN
    -- Keep stored Clubs values — badge still renders.
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'club_shortname', v_club,
    'foreign_interest_remaining', coalesce(v_remaining, 0),
    'tracking_teams', to_jsonb(coalesce(v_teams, '{}'::text[]))
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_foreign_interest_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_foreign_interest_state() TO authenticated;
REVOKE ALL ON FUNCTION public.sync_club_foreign_tracking(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_club_foreign_tracking(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.club_foreign_interest_state()') IS NOT NULL AS state_rpc,
  to_regprocedure('public.sync_club_foreign_tracking(text)') IS NOT NULL AS sync_rpc;
