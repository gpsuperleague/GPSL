-- =============================================================================
-- Emergency loans — Transfer_History on take + return (player career)
--
-- Fee is already posted via emergency_loan_fee ledger; history rows are for
-- career / season transfers display only (do not call post_transfer_ledger).
-- Discord transfer feed ignores listing_id IS NULL, so these will not spam news.
--
-- Run once in Supabase SQL Editor after emergency_loan_injury_suspension_20260828.sql.
-- Safe re-run.
-- =============================================================================

-- Take: Free agent → club
CREATE OR REPLACE FUNCTION public.club_emergency_loan_take(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_pid text := btrim(p_player_id);
  v_status jsonb;
  v_player public."Players"%rowtype;
  v_season_id bigint;
  v_month text;
  v_ends text;
  v_fee numeric := public.emergency_loan_fee_amount();
  v_max_rating numeric := public.emergency_loan_max_rating();
  v_rating numeric;
  v_wage numeric;
  v_ledger_id bigint;
  v_loan_id bigint;
  v_history_id bigint;
  v_registered int;
  v_overflow boolean := false;
  v_season_label text;
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'Player is required';
  END IF;

  PERFORM public.club_emergency_loans_expire_due(NULL);
  v_status := public.club_emergency_loan_status(v_club);

  IF NOT coalesce((v_status->>'eligible')::boolean, false) THEN
    RAISE EXCEPTION 'Emergency loan not available (need fit players below min 24 from August, with a free/overflow slot)';
  END IF;
  IF NOT coalesce((v_status->>'can_afford')::boolean, false) THEN
    RAISE EXCEPTION 'Insufficient balance for emergency loan fee (need %)', v_fee;
  END IF;

  v_season_id := (v_status->>'season_id')::bigint;
  v_month := v_status->>'active_gpsl_month';
  v_ends := v_status->>'ends_gpsl_month';
  IF v_ends IS NULL THEN
    RAISE EXCEPTION 'Emergency loans are not available in the current GPSL month';
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;
  IF v_player."Contracted_Team" IS NOT NULL AND btrim(v_player."Contracted_Team") <> '' THEN
    RAISE EXCEPTION 'Player is not a free agent';
  END IF;
  IF coalesce(v_player.pesdb_unavailable, false) THEN
    RAISE EXCEPTION 'Player is unavailable (legacy / PESDB)';
  END IF;

  v_rating := public.player_rating_as_numeric(v_player."Rating"::text);
  IF v_rating IS NULL OR v_rating > v_max_rating THEN
    RAISE EXCEPTION 'Emergency loan players must be rated % or lower', v_max_rating;
  END IF;

  v_registered := public.club_registered_squad_count(v_club);
  IF v_registered >= public.squad_max_size() THEN
    IF v_registered > public.squad_max_size() THEN
      RAISE EXCEPTION 'Squad already over maximum — cannot take another emergency loan';
    END IF;
    IF coalesce((v_status->>'overflow_slot_used')::boolean, false) THEN
      RAISE EXCEPTION 'Emergency overflow slot (28+1) already used';
    END IF;
    v_overflow := true;
  END IF;

  PERFORM 1 FROM public."Club_Finances" WHERE club_name = v_club FOR UPDATE;

  v_season_label := public.current_gpsl_season_label();
  v_wage := public.calculate_player_wage_for_club(v_pid, v_club);

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season_label,
    contract_seasons_remaining = 1,
    contract_wage = round(coalesce(v_wage, 0), 0),
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = v_pid;

  v_ledger_id := public.post_club_ledger(
    v_club,
    'emergency_loan_fee',
    -abs(v_fee),
    format('Emergency loan fee — %s (until end of %s)', coalesce(v_player."Name", v_pid), initcap(v_ends)),
    jsonb_build_object(
      'player_id', v_pid,
      'season_id', v_season_id,
      'kind', 'emergency_loan',
      'ends_gpsl_month', v_ends,
      'overflow_slot', v_overflow
    ),
    v_season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.club_emergency_loans (
    season_id,
    club_short_name,
    player_id,
    loan_fee,
    started_gpsl_month,
    ends_gpsl_month,
    status,
    loan_ledger_id,
    overflow_slot
  )
  VALUES (
    v_season_id,
    v_club,
    v_pid,
    v_fee,
    v_month,
    v_ends,
    'active',
    v_ledger_id,
    v_overflow
  )
  RETURNING id INTO v_loan_id;

  -- Career / season history (ledger already charged emergency_loan_fee — no post_transfer_ledger)
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
    NULL,
    v_club,
    v_fee,
    0,
    now(),
    NULL,
    NULL,
    'emergency_loan'
  )
  RETURNING id INTO v_history_id;

  RETURN jsonb_build_object(
    'ok', true,
    'loan_id', v_loan_id,
    'transfer_history_id', v_history_id,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'club_short_name', v_club,
    'loan_fee', v_fee,
    'ends_gpsl_month', v_ends,
    'overflow_slot', v_overflow,
    'status', public.club_emergency_loan_status(v_club)
  );
END;
$function$;

-- Return: club → free agent
CREATE OR REPLACE FUNCTION public.emergency_loan_complete_one(p_loan_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_loan public.club_emergency_loans%rowtype;
  v_player public."Players"%rowtype;
  v_history_id bigint;
BEGIN
  SELECT * INTO v_loan
  FROM public.club_emergency_loans
  WHERE id = p_loan_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_loan.status <> 'active' THEN
    RETURN jsonb_build_object('ok', true, 'already_done', true, 'loan_id', p_loan_id);
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_loan.player_id
  FOR UPDATE;

  IF FOUND
     AND public.player_contracted_club_key(v_player."Contracted_Team") = v_loan.club_short_name THEN
    UPDATE public."Players"
    SET
      "Contracted_Team" = NULL,
      contract_seasons_remaining = 0,
      contract_wage = 0,
      "Season_Signed" = NULL
    WHERE "Konami_ID"::text = v_loan.player_id;

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
      v_loan.club_short_name,
      'FOREIGN',
      0,
      0,
      now(),
      NULL,
      'Emergency loan ended (free agent)',
      'emergency_loan_return'
    )
    RETURNING id INTO v_history_id;
  END IF;

  UPDATE public.club_emergency_loans
  SET status = 'completed',
      completed_at = now()
  WHERE id = p_loan_id;

  RETURN jsonb_build_object(
    'ok', true,
    'loan_id', p_loan_id,
    'player_id', v_loan.player_id,
    'club_short_name', v_loan.club_short_name,
    'transfer_history_id', v_history_id
  );
END;
$function$;

-- Career bundle: label emergency loan moves
CREATE OR REPLACE FUNCTION public.competition_player_career_bundle(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_player jsonb;
  v_stints jsonb;
  v_awards jsonb;
  v_totals jsonb;
  v_transfers jsonb;
BEGIN
  SELECT to_jsonb(p)
  INTO v_player
  FROM (
    SELECT
      p."Konami_ID" AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Rating" AS rating,
      p."Nation" AS nation,
      p."Contracted_Team" AS current_club
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
    LIMIT 1
  ) p;

  SELECT coalesce(jsonb_agg(row_to_json(c) ORDER BY c.season_label DESC), '[]'::jsonb)
  INTO v_stints
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(a) ORDER BY a.season_label DESC), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  WHERE a.player_id = v_pid;

  SELECT jsonb_build_object(
    'appearances', coalesce(sum(appearances), 0),
    'goals', coalesce(sum(goals), 0),
    'assists', coalesce(sum(assists), 0),
    'potm_awards', coalesce(sum(potm_awards), 0),
    'clean_sheets', coalesce(sum(clean_sheets), 0),
    'avg_rating', round(avg(avg_rating) FILTER (WHERE avg_rating IS NOT NULL), 2)
  )
  INTO v_totals
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.transfer_time DESC), '[]'::jsonb)
  INTO v_transfers
  FROM (
    SELECT
      h.player_id::text AS player_id,
      public.transfer_history_season_label(h.transfer_time) AS season_label,
      h.transfer_time,
      h.seller_club_id AS seller_club_short_name,
      h.buyer_club_id AS buyer_club_short_name,
      h.foreign_buyer_name,
      h.transfer_sale_note,
      coalesce(h.fee, 0)::numeric AS fee,
      coalesce(h.agent_fee, 0)::numeric AS agent_fee,
      (coalesce(h.fee, 0) + coalesce(h.agent_fee, 0))::numeric AS total_cost,
      CASE
        WHEN h.transfer_sale_note = 'emergency_loan' THEN 'emergency_loan'
        WHEN h.transfer_sale_note = 'emergency_loan_return' THEN 'emergency_loan_return'
        WHEN h.transfer_sale_note = 'contract_expiry' THEN 'contract_expiry'
        WHEN h.transfer_sale_note = 'squad_overflow' THEN 'overflow_release'
        WHEN coalesce(h.fee, 0) <= 0 THEN 'free'
        WHEN h.foreign_buyer_name IS NOT NULL AND btrim(h.foreign_buyer_name) <> '' THEN 'foreign_sale'
        ELSE 'transfer'
      END AS move_kind
    FROM public."Transfer_History" h
    WHERE h.player_id::text = v_pid
  ) t;

  RETURN jsonb_build_object(
    'player', coalesce(v_player, '{}'::jsonb),
    'stints', coalesce(v_stints, '[]'::jsonb),
    'awards', coalesce(v_awards, '[]'::jsonb),
    'totals', coalesce(v_totals, '{}'::jsonb),
    'transfers', coalesce(v_transfers, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_emergency_loan_take(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.emergency_loan_complete_one(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_player_career_bundle(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.transfer_classify_method(
  p_seller_club text,
  p_buyer_club text,
  p_listing_id bigint,
  p_sale_note text,
  p_foreign_buyer_name text,
  p_method_override text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing_type text;
  v_note text := coalesce(btrim(p_sale_note), '');
  v_buyer text := btrim(coalesce(p_buyer_club, ''));
  v_seller text := btrim(coalesce(p_seller_club, ''));
BEGIN
  IF p_method_override IS NOT NULL AND btrim(p_method_override) <> '' THEN
    RETURN btrim(p_method_override);
  END IF;

  IF v_note = 'special_auction' OR v_note LIKE 'special_auction:%' THEN
    RETURN 'Special auction';
  END IF;

  IF v_note = 'emergency_loan' THEN
    RETURN 'Emergency loan (half-season)';
  END IF;

  IF v_note = 'emergency_loan_return' THEN
    RETURN 'Emergency loan ended';
  END IF;

  IF v_note = 'contract_expiry' THEN
    RETURN 'Contract Run Down - Central Bank Compensation';
  END IF;

  IF p_listing_id IS NOT NULL THEN
    SELECT l.listing_type INTO v_listing_type
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = p_listing_id;
  END IF;

  IF v_listing_type = 'draft' THEN
    RETURN 'Draft auction';
  END IF;

  IF v_note = 'squad_overflow' THEN
    IF v_buyer = 'FOREIGN' AND coalesce(btrim(p_foreign_buyer_name), '') <> '' THEN
      RETURN 'Foreign sale (squad over 28)';
    END IF;
    RETURN 'Squad release (market value, over 28)';
  END IF;

  IF v_buyer = 'FOREIGN' THEN
    IF coalesce(btrim(p_foreign_buyer_name), '') <> '' THEN
      RETURN 'Foreign sale — ' || btrim(p_foreign_buyer_name);
    END IF;
    RETURN 'Foreign sale';
  END IF;

  IF v_listing_type = 'direct' THEN
    RETURN 'Direct offer (transfer market)';
  END IF;

  IF v_seller <> '' AND v_buyer <> '' THEN
    RETURN 'Transfer list (auction)';
  END IF;

  IF v_seller = '' AND v_buyer <> '' THEN
    RETURN 'Draft auction signing';
  END IF;

  RETURN 'Transfer';
END;
$function$;

NOTIFY pgrst, 'reload schema';
