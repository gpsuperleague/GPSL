-- =============================================================================
-- Fix: No current competition season — cannot record foreign contract lock
--
-- Symptom (Create Pre-Season / competition_create_season_full):
--   No current competition season — cannot record foreign contract lock
--
-- Cause: After End Season, no row has is_current. Create Pre-Season inserts
--   status=preseason, is_current=false. Expiry bid assigns can trigger squad
--   overflow → player_apply_foreign_contract_lock / paid-up lock, which only
--   looked at current_gpsl_season_id() and RAISED.
--
-- Fix: resolve lock season as:
--   1) current season (live), else
--   2) newest preseason/setup (Create Pre-Season ledger), else
--   3) newest season by id
-- Unlock label still = next season after that id (or "Next season").
--
-- Run in Supabase SQL Editor, then retry Create Pre-Season
--   (or Tick player contracts catch-up if the season row already exists).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_season_id_for_locks()
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  v_id := public.current_gpsl_season_id();
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Summer break / Create Pre-Season: use newest preseason/setup
  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_season_id_for_locks() IS
  'Season id for foreign/paid-up locks: current, else newest preseason/setup, else newest.';

DROP FUNCTION IF EXISTS public.player_apply_foreign_contract_lock(text, text);
DROP FUNCTION IF EXISTS public.player_apply_foreign_contract_lock(text, text, bigint);

CREATE OR REPLACE FUNCTION public.player_apply_foreign_contract_lock(
  p_player_id text,
  p_foreign_club_name text,
  p_sold_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_foreign_club_name);
  v_sold_season_id bigint;
  v_unlock_label text;
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_apply_foreign_contract_lock: player_id required';
  END IF;

  IF v_club = '' THEN
    v_club := 'Foreign club';
  END IF;

  v_sold_season_id := coalesce(p_sold_season_id, public.gpsl_season_id_for_locks());

  IF v_sold_season_id IS NULL THEN
    RAISE EXCEPTION 'No competition season — cannot record foreign contract lock';
  END IF;

  v_unlock_label := public.next_gpsl_season_label(v_sold_season_id);

  UPDATE public."Players"
  SET
    foreign_contract_club = v_club,
    foreign_contract_sold_season_id = v_sold_season_id,
    foreign_contract_unlock_season_label = v_unlock_label,
    foreign_contract_lock_kind = 'foreign'
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

DROP FUNCTION IF EXISTS public.player_apply_overflow_paid_up_lock(text, text);
DROP FUNCTION IF EXISTS public.player_apply_overflow_paid_up_lock(text, text, bigint);

CREATE OR REPLACE FUNCTION public.player_apply_overflow_paid_up_lock(
  p_player_id text,
  p_previous_club_short_name text,
  p_sold_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_previous_club_short_name);
  v_sold_season_id bigint;
  v_unlock_label text;
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_apply_overflow_paid_up_lock: player_id required';
  END IF;

  IF v_club = '' THEN
    RAISE EXCEPTION 'player_apply_overflow_paid_up_lock: previous club required';
  END IF;

  v_sold_season_id := coalesce(p_sold_season_id, public.gpsl_season_id_for_locks());

  IF v_sold_season_id IS NULL THEN
    RAISE EXCEPTION 'No competition season — cannot record paid-up overflow lock';
  END IF;

  v_unlock_label := public.next_gpsl_season_label(v_sold_season_id);

  UPDATE public."Players"
  SET
    foreign_contract_club = v_club,
    foreign_contract_sold_season_id = v_sold_season_id,
    foreign_contract_unlock_season_label = v_unlock_label,
    foreign_contract_lock_kind = 'paid_up'
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_season_id_for_locks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_apply_foreign_contract_lock(text, text, bigint)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_apply_overflow_paid_up_lock(text, text, bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
