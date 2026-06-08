-- =============================================================================
-- Squad overflow (MV forced release): £10m fine + paid-up season lock
-- Foreign overflow: same foreign lock as normal abroad sale — no £10m fine
-- Run after: foreign_sale_season_lock.sql, transfer_ledger_polish.sql,
--            competition_fines.sql, squad_overflow_enforcement.sql
-- =============================================================================

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS foreign_contract_lock_kind text;

COMMENT ON COLUMN public."Players".foreign_contract_lock_kind IS
  'foreign = sold abroad; paid_up = squad MV overflow — unavailable until next season.';

ALTER TABLE public."Players"
  DROP CONSTRAINT IF EXISTS players_foreign_contract_lock_kind_check;

ALTER TABLE public."Players"
  ADD CONSTRAINT players_foreign_contract_lock_kind_check
  CHECK (
    foreign_contract_lock_kind IS NULL
    OR foreign_contract_lock_kind IN ('foreign', 'paid_up')
  );

-- Tariff: £10m per MV overflow forced release (not foreign overflow)
INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES (
  'squad_overflow_mv_release',
  'Squad overflow — forced MV release',
  'squad',
  'fine',
  10000000,
  'fixed',
  83,
  true
)
ON CONFLICT (code) DO UPDATE SET
  label = EXCLUDED.label,
  category = EXCLUDED.category,
  direction = EXCLUDED.direction,
  amount = EXCLUDED.amount,
  amount_mode = EXCLUDED.amount_mode,
  sort_order = EXCLUDED.sort_order,
  is_active = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Lock helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.player_apply_foreign_contract_lock(
  p_player_id text,
  p_foreign_club_name text
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

  v_sold_season_id := public.current_gpsl_season_id();

  IF v_sold_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season — cannot record foreign contract lock';
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

CREATE OR REPLACE FUNCTION public.player_apply_overflow_paid_up_lock(
  p_player_id text,
  p_previous_club_short_name text
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

  v_sold_season_id := public.current_gpsl_season_id();

  IF v_sold_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season — cannot record paid-up overflow lock';
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

CREATE OR REPLACE FUNCTION public.player_clear_foreign_contract_lock(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public."Players"
  SET
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = btrim(p_player_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_foreign_contract_status(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_locked boolean;
BEGIN
  SELECT *
  INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN jsonb_build_object('locked', false);
  END IF;

  v_locked := public.player_foreign_contract_locked(p_player_id);

  RETURN jsonb_build_object(
    'locked', v_locked,
    'lock_kind', coalesce(nullif(btrim(v_player.foreign_contract_lock_kind), ''), 'foreign'),
    'foreign_contract_club', v_player.foreign_contract_club,
    'sold_season_id', v_player.foreign_contract_sold_season_id,
    'unlock_season_label', coalesce(
      nullif(btrim(v_player.foreign_contract_unlock_season_label), ''),
      public.next_gpsl_season_label(v_player.foreign_contract_sold_season_id)
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.assert_player_available_for_signing(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status jsonb;
  v_club text;
  v_unlock text;
  v_kind text;
BEGIN
  IF NOT public.player_foreign_contract_locked(p_player_id) THEN
    RETURN;
  END IF;

  v_status := public.player_foreign_contract_status(p_player_id);
  v_club := coalesce(v_status ->> 'foreign_contract_club', 'their previous club');
  v_unlock := coalesce(v_status ->> 'unlock_season_label', 'next season');
  v_kind := coalesce(v_status ->> 'lock_kind', 'foreign');

  IF v_kind = 'paid_up' THEN
    RAISE EXCEPTION
      'Player is unavailable until % — contract paid up by % (squad overflow release)',
      v_unlock,
      v_club;
  END IF;

  RAISE EXCEPTION
    'Player is unavailable until % — contracted to %',
    v_unlock,
    v_club;
END;
$function$;

-- Signing clears abroad / paid-up lock (3-arg hook used by transfers)
CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text,
  p_wage numeric DEFAULT NULL
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
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  PERFORM public.assert_player_available_for_signing(v_pid);

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

  v_overflow := public.enforce_squad_overflow_after_signing(v_club, v_pid);

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'club_short_name', v_club,
    'contract_seasons_remaining', 3,
    'overflow_release', v_overflow
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- MV overflow: MV credit + ledger + paid-up lock + £10m fine
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_release_player_mv_overflow(
  p_club_short_name text,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club       text := btrim(p_club_short_name);
  v_pid        text := btrim(p_player_id);
  v_player     public."Players"%rowtype;
  v_fee        numeric;
  v_bal        numeric;
  v_history_id bigint;
  v_fine       jsonb;
  v_unlock     text;
BEGIN
  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.ensure_foreign_buyer_club();
  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_apply_overflow_paid_up_lock(v_pid, v_club);

  v_unlock := public.next_gpsl_season_label(public.current_gpsl_season_id());

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    'FOREIGN',
    v_fee,
    0,
    now(),
    NULL,
    'Market value (squad over 28)',
    'squad_overflow'
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id, false);

  v_fine := public.competition_apply_club_fine_tariff(
    v_club,
    'squad_overflow_mv_release',
    NULL,
    format('Forced release: %s (%s)', v_player."Name", v_pid)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'method', 'market_value',
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'fee', v_fee,
    'overflow_fine', v_fine,
    'unavailable_until_season', v_unlock,
    'lock_kind', 'paid_up'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Foreign overflow: foreign lock + MV credit + ledger — no £10m fine
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_release_player_foreign_overflow(
  p_club_short_name text,
  p_player_id text,
  p_foreign_team_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text := btrim(p_club_short_name);
  v_pid            text := btrim(p_player_id);
  v_team           text := btrim(p_foreign_team_name);
  v_player         public."Players"%rowtype;
  v_fee            numeric;
  v_bal            numeric;
  v_interest       int;
  v_interest_after int;
  v_teams          text[];
  v_history_id     bigint;
  v_unlock_label   text;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  IF v_team = '' THEN
    RAISE EXCEPTION 'Foreign buyer name required for overflow foreign sale';
  END IF;

  SELECT c.foreign_interest_remaining, coalesce(c.foreign_tracking_teams, '{}')
  INTO v_interest, v_teams
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_interest, 0) <= 0 THEN
    RAISE EXCEPTION 'No foreign club interest remaining for %', v_club;
  END IF;

  v_teams := public.sync_club_foreign_tracking(v_club);

  IF NOT (v_team = ANY (v_teams)) THEN
    RAISE EXCEPTION 'Club % is not tracking your players', v_team;
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_apply_foreign_contract_lock(v_pid, v_team);

  v_unlock_label := public.next_gpsl_season_label(public.current_gpsl_season_id());

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

  v_teams := array_remove(v_teams, v_team);

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = foreign_interest_remaining - 1,
      foreign_tracking_teams = v_teams
  WHERE c."ShortName" = v_club
  RETURNING c.foreign_interest_remaining INTO v_interest_after;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    'FOREIGN',
    v_fee,
    0,
    now(),
    NULL,
    v_team,
    'squad_overflow'
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id, false);

  RETURN jsonb_build_object(
    'ok', true,
    'method', 'foreign',
    'player_id', v_pid,
    'player_name', v_player."Name",
    'foreign_buyer_name', v_team,
    'fee', v_fee,
    'foreign_interest_remaining', v_interest_after,
    'unavailable_until_season', v_unlock_label,
    'lock_kind', 'foreign'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_apply_overflow_paid_up_lock(text, text) TO authenticated;
