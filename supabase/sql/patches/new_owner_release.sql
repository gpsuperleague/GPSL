-- =============================================================================
-- New Owner Release — up to 3 players in first season at a club
-- Credit/refund = fee the club paid (looked up from Transfer_History; history not rewritten)
-- Paid by GPSL Central Bank. Player → free agent, paid-up lock until next season.
-- Windows: pre-season OR January transfer window
-- Run after: voluntary_contract_release.sql, squad_overflow_paid_up_fine.sql,
--            central_bank_model_a_flows.sql
-- =============================================================================

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS owner_assigned_season_id bigint
    REFERENCES public.competition_seasons (id) ON DELETE SET NULL;

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS new_owner_releases_remaining smallint NOT NULL DEFAULT 0;

ALTER TABLE public."Clubs"
  DROP CONSTRAINT IF EXISTS clubs_new_owner_releases_remaining_check;

ALTER TABLE public."Clubs"
  ADD CONSTRAINT clubs_new_owner_releases_remaining_check
  CHECK (
    new_owner_releases_remaining >= 0
    AND new_owner_releases_remaining <= 3
  );

COMMENT ON COLUMN public."Clubs".owner_assigned_season_id IS
  'GPSL season when the current owner took charge. New Owner releases only while this equals the current season.';
COMMENT ON COLUMN public."Clubs".new_owner_releases_remaining IS
  'Remaining New Owner release slots for the first season at this club (max 3). Not reset each season.';

-- Ledger entry type
ALTER TABLE public.competition_finance_ledger
  DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

ALTER TABLE public.competition_finance_ledger
  ADD CONSTRAINT competition_finance_ledger_entry_type_check
  CHECK (
    entry_type IN (
      'gate_league_home',
      'gate_cup_share',
      'prize',
      'prize_league',
      'prize_cup',
      'prize_challenge',
      'tv_revenue',
      'gov_hg_subsidy',
      'gov_youth_subsidy',
      'gov_bnb_subsidy',
      'gov_fine_compensation',
      'gov_emergency_tax',
      'gov_income_tax',
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'adjustment',
      'admin_one_off_injection',
      'admin_purchase_payment',
      'transfer_sale',
      'transfer_purchase',
      'transfer_agent_fee',
      'transfer_foreign_sale',
      'transfer_overflow_release',
      'loan_drawdown',
      'loan_repayment_principal',
      'loan_interest_payment',
      'infra_maintenance',
      'infra_purchase',
      'infra_expansion',
      'infra_expansion_refund',
      'infra_expansion_penalty',
      'contract_release_comp',
      'contract_release_comp_received',
      'contract_termination',
      'contract_signing_offer',
      'staff_manager_salary',
      'eos_debt_interest',
      'eos_ffp_charge',
      'eos_injection',
      'special_auction_fee',
      'special_auction_prize',
      'new_owner_release'
    )
  );

CREATE OR REPLACE FUNCTION public.finance_entry_via_central_bank(p_entry_type text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_entry_type, '') = ANY(ARRAY[
    'gov_hg_subsidy',
    'gov_youth_subsidy',
    'gov_bnb_subsidy',
    'gov_emergency_tax',
    'gov_income_tax',
    'gov_fine_compensation',
    'wage_star_tax',
    'eos_debt_interest',
    'eos_ffp_charge',
    'eos_balance_interest',
    'eos_injection',
    'prize',
    'prize_league',
    'prize_cup',
    'prize_challenge',
    'tv_revenue',
    'infra_purchase',
    'infra_expansion',
    'infra_expansion_refund',
    'infra_expansion_penalty',
    'loan_drawdown',
    'loan_repayment_principal',
    'loan_interest_payment',
    'admin_one_off_injection',
    'contract_release_comp_received',
    'special_auction_prize',
    'new_owner_release'
  ]);
$$;

-- ---------------------------------------------------------------------------
-- Tenure helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_mark_new_owner_tenure(
  p_club_short text,
  p_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint := p_season_id;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(btrim(coalesce(p_club_short, '')))
  LIMIT 1;

  IF v_club IS NULL THEN
    RETURN;
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  UPDATE public."Clubs" c
  SET owner_assigned_season_id = v_season_id,
      new_owner_releases_remaining = 3
  WHERE c."ShortName" = v_club;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_new_owner_release_window_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_month text;
  v_tw boolean;
BEGIN
  SELECT s.id, s.status
  INTO v_season_id, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  -- Full pre-season (before August)
  IF lower(coalesce(v_status, '')) = 'preseason' THEN
    RETURN true;
  END IF;

  SELECT transfer_window_open INTO v_tw
  FROM public.global_settings
  WHERE id = 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  -- Between activate and first GPSL month (no live month yet) while TW open
  IF v_month = '' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  -- January transfer window
  IF v_month = 'january' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_player_purchase_fee(
  p_club_short text,
  p_player_id text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text := btrim(p_player_id);
  v_fee numeric;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(btrim(coalesce(p_club_short, '')))
  LIMIT 1;

  IF v_club IS NULL OR v_pid IS NULL OR v_pid = '' THEN
    RETURN NULL;
  END IF;

  SELECT h.fee
  INTO v_fee
  FROM public."Transfer_History" h
  WHERE h.buyer_club_id = v_club
    AND h.player_id::text = v_pid
    AND coalesce(h.fee, 0) > 0
  ORDER BY h.transfer_time DESC NULLS LAST, h.id DESC
  LIMIT 1;

  RETURN v_fee;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_is_new_owner_release_eligible(
  p_club_short text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_assigned bigint;
  v_remaining int;
BEGIN
  IF p_club_short IS NULL OR btrim(p_club_short) = '' THEN
    v_club := public.my_club_shortname();
  ELSE
    SELECT c."ShortName" INTO v_club
    FROM public."Clubs" c
    WHERE upper(c."ShortName") = upper(btrim(p_club_short))
    LIMIT 1;
  END IF;

  IF v_club IS NULL THEN
    RETURN false;
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT c.owner_assigned_season_id, c.new_owner_releases_remaining
  INTO v_assigned, v_remaining
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  RETURN v_season_id IS NOT NULL
    AND v_assigned IS NOT NULL
    AND v_assigned = v_season_id
    AND coalesce(v_remaining, 0) > 0;
END;
$function$;

-- ---------------------------------------------------------------------------
-- State / preview / execute
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_new_owner_release_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_assigned bigint;
  v_remaining int;
  v_eligible boolean;
  v_window boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT c.owner_assigned_season_id, c.new_owner_releases_remaining
  INTO v_assigned, v_remaining
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_eligible := public.club_is_new_owner_release_eligible(v_club);
  v_window := public.club_new_owner_release_window_open();

  RETURN jsonb_build_object(
    'club_shortname', v_club,
    'new_owner_releases_remaining', coalesce(v_remaining, 0),
    'max_total', 3,
    'owner_assigned_season_id', v_assigned,
    'current_season_id', v_season_id,
    'first_season_at_club', (v_assigned IS NOT NULL AND v_season_id IS NOT NULL AND v_assigned = v_season_id),
    'eligible', v_eligible,
    'window_open', v_window,
    'available_now', (v_eligible AND v_window)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_new_owner_release_preview(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  v_fee numeric;
  v_state jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  v_state := public.club_new_owner_release_state();

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_at_club');
  END IF;

  v_fee := public.club_player_purchase_fee(v_club, v_pid);

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'fee', v_fee,
    'eligible_player', (v_fee IS NOT NULL AND v_fee > 0),
    'club_state', v_state
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_new_owner_release(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  v_remaining int;
  v_assigned bigint;
  v_season_id bigint;
  v_fee numeric;
  v_balance numeric;
  v_unlock text;
  v_ledger_id bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF NOT public.club_new_owner_release_window_open() THEN
    RAISE EXCEPTION
      'New Owner releases are only available in the pre-season window or the January transfer window';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT c.new_owner_releases_remaining, c.owner_assigned_season_id
  INTO v_remaining, v_assigned
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF v_assigned IS NULL OR v_season_id IS NULL OR v_assigned <> v_season_id THEN
    RAISE EXCEPTION
      'New Owner releases are only available in your first season in charge of this club';
  END IF;

  IF coalesce(v_remaining, 0) <= 0 THEN
    RAISE EXCEPTION 'No New Owner releases remaining (maximum 3 in your first season at this club)';
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  v_fee := public.club_player_purchase_fee(v_club, v_pid);
  IF v_fee IS NULL OR v_fee <= 0 THEN
    RAISE EXCEPTION
      'No purchase fee found for this player at your club — New Owner release only applies to players the club paid a transfer fee for';
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_balance IS NULL THEN
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
  PERFORM public.player_apply_overflow_paid_up_lock(v_pid, v_club);

  v_unlock := public.next_gpsl_season_label(v_season_id);

  UPDATE public."Clubs" c
  SET new_owner_releases_remaining = new_owner_releases_remaining - 1
  WHERE c."ShortName" = v_club
  RETURNING c.new_owner_releases_remaining INTO v_remaining;

  -- Positive amount = club credit (refund of historical purchase fee from Central Bank).
  -- Does NOT change Transfer_History purchase rows.
  v_ledger_id := public.post_club_ledger(
    v_club,
    'new_owner_release',
    abs(v_fee),
    format('New Owner release refund: %s (purchase fee)', v_player."Name"),
    jsonb_build_object(
      'player_id', v_pid,
      'player_name', v_player."Name",
      'purchase_fee', v_fee,
      'new_owner_release', true,
      'refund', true
    ),
    v_season_id,
    NULL,
    true,
    true
  );

  PERFORM public.ensure_foreign_buyer_club();

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
    0,
    0,
    now(),
    NULL,
    format('New Owner release (₿ %s Central Bank refund)', to_char(v_fee, 'FM999999999999')),
    'new_owner_release'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'fee', v_fee,
    'refund', v_fee,
    'new_balance', v_balance + abs(v_fee),
    'new_owner_releases_remaining', v_remaining,
    'unavailable_until_season', v_unlock,
    'ledger_id', v_ledger_id
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Hook tenure on admin assign (and auction settle if that function exists later)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_assign_club_owner(
  p_owner_email text,
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_short text := upper(trim(p_club_short_name));
  v_user_id uuid;
  v_club_name text;
  v_replaced_previous boolean := false;
  v_registry_status text;
  v_displaced uuid;
  v_old_club text;
  v_tag text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  IF v_short IS NULL OR v_short = '' THEN
    RAISE EXCEPTION 'Club ShortName is required';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT r.status INTO v_registry_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF v_registry_status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived — unarchive before linking to a club';
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short;

  IF v_club_name IS NULL THEN
    RAISE EXCEPTION 'Club ShortName % not found', v_short;
  END IF;

  SELECT c.owner_id INTO v_displaced
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
    AND c.owner_id IS NOT NULL
    AND c.owner_id <> v_user_id
  LIMIT 1;

  IF v_displaced IS NOT NULL THEN
    v_replaced_previous := true;
    PERFORM public.admin_owner_detach_core(v_displaced, 'on_break', 'Displaced by admin club link');
  END IF;

  SELECT c."ShortName", nullif(btrim(c.owner), '')
  INTO v_old_club, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
    AND c."ShortName" <> v_short
  LIMIT 1;

  IF v_old_club IS NOT NULL THEN
    PERFORM public.admin_club_vacate(v_old_club);
  END IF;

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_short;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Failed to update club %', v_short;
  END IF;

  PERFORM public.club_mark_new_owner_tenure(v_short);

  INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name, status_changed_at)
  VALUES (v_user_id, 'active', v_tag, v_short, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_short,
      status_note = NULL,
      status_changed_at = now();

  RETURN jsonb_build_object(
    'user_id', v_user_id,
    'email', p_owner_email,
    'club_short_name', v_short,
    'club_name', v_club_name,
    'replaced_previous_owner', v_replaced_previous,
    'new_owner_releases_remaining', 3
  );
END;
$function$;

-- Any owner_id change (admin link, club auction settle, etc.) marks first-season tenure
CREATE OR REPLACE FUNCTION public.trg_clubs_owner_change_new_owner_tenure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF NEW.owner_id IS NULL AND OLD.owner_id IS NOT NULL THEN
    NEW.owner_assigned_season_id := NULL;
    NEW.new_owner_releases_remaining := 0;
    RETURN NEW;
  END IF;

  IF NEW.owner_id IS NOT NULL
    AND NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;

    NEW.owner_assigned_season_id := v_season_id;
    NEW.new_owner_releases_remaining := 3;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_owner_change_new_owner_tenure ON public."Clubs";
CREATE TRIGGER clubs_owner_change_new_owner_tenure
  BEFORE UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clubs_owner_change_new_owner_tenure();

-- Season 1 launch backfill: every owned club is in "first season" now
UPDATE public."Clubs" c
SET owner_assigned_season_id = coalesce(
      owner_assigned_season_id,
      (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
    ),
    new_owner_releases_remaining = CASE
      WHEN owner_id IS NOT NULL
        AND (
          owner_assigned_season_id IS NULL
          OR owner_assigned_season_id = (
            SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
          )
        )
      THEN GREATEST(coalesce(new_owner_releases_remaining, 0), 3)
      ELSE new_owner_releases_remaining
    END
WHERE c.owner_id IS NOT NULL
  AND c."ShortName" <> 'FOREIGN';

GRANT EXECUTE ON FUNCTION public.club_new_owner_release_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_player_purchase_fee(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_is_new_owner_release_eligible(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_new_owner_release_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_new_owner_release_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_new_owner_release(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
