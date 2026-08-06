-- =============================================================================
-- Fix: player_assign_to_club(text, text, numeric) is not unique
--
-- Symptom (Create Pre-Season / competition_create_season_full):
--   function public.player_assign_to_club(text, text, numeric) is not unique
--
-- Cause: both a 3-arg and a 4-arg overload exist, each with DEFAULTs, so a
--   3-arg call from contract expiry resolve matches both.
--
-- Fix: drop the 2-arg / 3-arg overloads; keep one canonical 4-arg function.
--   Existing 2-arg and 3-arg calls then resolve uniquely via DEFAULT args.
--
-- Run in Supabase SQL Editor, then retry Create Pre-Season.
--   If the season row was already created, use Tick player contracts (catch-up)
--   or: SELECT public.admin_catchup_player_contract_tick(false);
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text);
DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text, numeric);

CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text,
  p_wage numeric DEFAULT NULL,
  p_defer_squad_overflow boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid      text := btrim(p_player_id);
  v_club     text := btrim(p_club_short_name);
  v_season   text;
  v_wage     numeric;
  v_overflow jsonb;
  v_defer    boolean;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  v_defer := p_defer_squad_overflow
    OR coalesce(
      nullif(current_setting('gpsl.defer_squad_overflow', true), ''),
      ''
    ) = 'on';

  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    PERFORM public.assert_player_available_for_signing(v_pid);
  END IF;

  v_season := public.current_gpsl_season_label();
  v_wage := coalesce(p_wage, public.calculate_player_wage_for_club(v_pid, v_club));

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season,
    contract_seasons_remaining = 3,
    contract_wage = round(coalesce(v_wage, 0), 0),
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = v_pid;

  IF v_defer THEN
    v_overflow := jsonb_build_object(
      'released', false,
      'deferred', true,
      'squad_total', public.club_squad_player_count(v_club)
    );
  ELSE
    v_overflow := public.enforce_squad_overflow_after_signing(v_club, v_pid);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'club_short_name', v_club,
    'contract_seasons_remaining', 3,
    'overflow_release', v_overflow
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_assign_to_club(text, text, numeric, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
