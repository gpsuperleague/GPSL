-- =============================================================================
-- FIX: non-mods simulating other clubs' fixtures (club impersonation)
--
-- Cause (match_sim_vacant_vs_vacant_staff_20260814.sql):
--   my_club_shortname() honoured GUC gpsl.sim_acting_club.
--   Any authenticated client can poison that setting and impersonate another
--   club for competition_simulate_fixture_result (and any other RPC using
--   my_club_shortname).
--
-- Fix:
--   • my_club_shortname() no longer reads client GUCs
--   • Staff vacant-vs-vacant uses a private tx-scoped guard table that only
--     SECURITY DEFINER code (not granted to authenticated) can write
--   • Simulate wrapper authorises on Clubs.owner_id = auth.uid() and requires
--     the caller to be home or away (unless staff vacant vs vacant)
--
-- Safe re-run. Apply in Supabase SQL Editor.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_sim_acting_guard (
  txid bigint PRIMARY KEY,
  acting_club text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gpsl_sim_acting_guard ENABLE ROW LEVEL SECURITY;

-- No policies for authenticated — table is only touched by SECURITY DEFINER helpers
REVOKE ALL ON TABLE public.gpsl_sim_acting_guard FROM PUBLIC;
REVOKE ALL ON TABLE public.gpsl_sim_acting_guard FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_sim_set_acting_club(p_club text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF nullif(btrim(coalesce(p_club, '')), '') IS NULL THEN
    DELETE FROM public.gpsl_sim_acting_guard WHERE txid = txid_current();
    RETURN;
  END IF;

  INSERT INTO public.gpsl_sim_acting_guard (txid, acting_club)
  VALUES (txid_current(), btrim(p_club))
  ON CONFLICT (txid) DO UPDATE
    SET acting_club = excluded.acting_club,
        created_at = now();
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_sim_set_acting_club(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.gpsl_sim_set_acting_club(text) FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.my_club_shortname()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_guard text;
BEGIN
  -- Staff vacant-sim override (set only via gpsl_sim_set_acting_club, not clients)
  SELECT g.acting_club
  INTO v_guard
  FROM public.gpsl_sim_acting_guard g
  WHERE g.txid = txid_current()
  LIMIT 1;

  IF v_guard IS NOT NULL THEN
    RETURN v_guard;
  END IF;

  RETURN (
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE c.owner_id = auth.uid()
    LIMIT 1
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.my_club_shortname() TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_simulate_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
AS $function$
DECLARE
  v_real_club text;
  v_home text;
  v_away text;
  v_home_owned boolean;
  v_away_owned boolean;
  v_staff boolean := false;
  v_result jsonb;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled';
  END IF;

  -- Drop any leftover / poisoned acting club for this tx
  PERFORM public.gpsl_sim_set_acting_club(NULL);
  -- Also clear legacy GUC if present
  PERFORM set_config('gpsl.sim_acting_club', '', true);

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT c."ShortName"
  INTO v_real_club
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;

  BEGIN
    v_staff := public.is_gpsl_admin_or_mod();
  EXCEPTION
    WHEN OTHERS THEN
      v_staff := public.is_gpsl_admin();
  END;

  SELECT coalesce(
    (SELECT c.owner_id IS NOT NULL FROM public."Clubs" c WHERE c."ShortName" = v_home),
    false
  )
  INTO v_home_owned;

  SELECT coalesce(
    (SELECT c.owner_id IS NOT NULL FROM public."Clubs" c WHERE c."ShortName" = v_away),
    false
  )
  INTO v_away_owned;

  -- Staff only: vacant vs vacant
  IF v_staff AND NOT v_home_owned AND NOT v_away_owned THEN
    PERFORM public.gpsl_sim_set_acting_club(v_home);
    BEGIN
      PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_home);
      v_result := public.competition_simulate_fixture_result_core(p_fixture_id);
    EXCEPTION
      WHEN OTHERS THEN
        PERFORM public.gpsl_sim_set_acting_club(NULL);
        RAISE;
    END;
    PERFORM public.gpsl_sim_set_acting_club(NULL);
    RETURN v_result;
  END IF;

  IF v_real_club IS NULL OR btrim(v_real_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF v_real_club IS DISTINCT FROM v_home AND v_real_club IS DISTINCT FROM v_away THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  PERFORM public.competition_assert_fixture_month_unlocked(p_fixture_id, v_real_club);
  RETURN public.competition_simulate_fixture_result_core(p_fixture_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
