-- =============================================================================
-- club_foreign_interest_state: pure read (no sync) — stop squad.html 500
--
-- Previous harden still called sync_club_foreign_tracking (FOR UPDATE + UPDATE).
-- That path (or a Clubs column miss) can still 500 PostgREST.
--
-- This version:
--   • Only SELECTs Clubs (no sync / no write)
--   • Entire body wrapped so it NEVER raises to the client
--   • Sync stays available for sell / overflow paths only
--
-- Safe re-run. Then hard-refresh squad.html.
-- =============================================================================

-- Drop any accidental overloads so PostgREST binds the one we define
DROP FUNCTION IF EXISTS public.club_foreign_interest_state();

CREATE OR REPLACE FUNCTION public.club_foreign_interest_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := NULL;
  v_remaining int := 0;
  v_teams text[] := '{}'::text[];
  v_uid uuid;
BEGIN
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_uid := NULL;
  END;

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_authenticated',
      'foreign_interest_remaining', 0,
      'tracking_teams', '[]'::jsonb
    );
  END IF;

  BEGIN
    -- Prefer direct Clubs lookup (avoids my_club_shortname / sim-guard side paths)
    SELECT c."ShortName"
    INTO v_club
    FROM public."Clubs" c
    WHERE c.owner_id = v_uid
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_club := NULL;
  END;

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    BEGIN
      v_club := public.my_club_shortname();
    EXCEPTION WHEN OTHERS THEN
      v_club := NULL;
    END;
  END IF;

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_club',
      'foreign_interest_remaining', 0,
      'tracking_teams', '[]'::jsonb
    );
  END IF;

  BEGIN
    SELECT
      greatest(coalesce(c.foreign_interest_remaining, 0), 0),
      coalesce(c.foreign_tracking_teams, '{}'::text[])
    INTO v_remaining, v_teams
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;
  EXCEPTION WHEN OTHERS THEN
    -- Missing column / type issues — still return a usable payload
    v_remaining := 0;
    v_teams := '{}'::text[];
    BEGIN
      SELECT greatest(coalesce(c.foreign_interest_remaining, 0), 0)
      INTO v_remaining
      FROM public."Clubs" c
      WHERE c."ShortName" = v_club;
    EXCEPTION WHEN OTHERS THEN
      v_remaining := 0;
    END;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'club_shortname', v_club,
    'foreign_interest_remaining', coalesce(v_remaining, 0),
    'tracking_teams', to_jsonb(coalesce(v_teams, '{}'::text[])),
    'synced', false
  );
EXCEPTION WHEN OTHERS THEN
  -- Absolute last resort — never 500 the squad page
  RETURN jsonb_build_object(
    'ok', false,
    'reason', 'internal',
    'detail', left(SQLERRM, 200),
    'foreign_interest_remaining', 0,
    'tracking_teams', '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_foreign_interest_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_foreign_interest_state() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Quick health check (should return one jsonb row, never error)
SELECT public.club_foreign_interest_state() AS sample_as_definer_null_uid;

SELECT
  p.oid::regprocedure AS proc,
  p.prosecdef AS security_definer,
  pg_get_function_result(p.oid) AS result_type
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'club_foreign_interest_state';
