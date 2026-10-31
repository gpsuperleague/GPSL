-- Mid-season handpick / vacant-club claim finances:
--   • Keep ALL prior season ledger history (other clubs untouched)
--   • Replace cash position with auction starting balance (₿650m)
--   • Charge stadium again as infra_purchase "Club takeover Fee"
--     (same amount as club_stadium_infra_purchase_cost)
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.handpick_apply_takeover_finances(
  p_club_short_name text,
  p_via_claim boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_name text;
  v_bal numeric := 0;
  v_target numeric := public.handpick_target_balance();
  v_stadium numeric := 0;
  v_delta numeric := 0;
  v_start_ledger bigint;
  v_fee_ledger bigint;
  v_claim boolean := coalesce(p_via_claim, false);
  v_dup text;
BEGIN
  IF v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  SELECT c."Club" INTO v_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_dup := 'handpick_takeover_' || v_club || '_' || to_char(now() AT TIME ZONE 'utc', 'YYYYMMDD');

  -- Idempotent within the same UTC day if fee already posted for handpick takeover
  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE upper(l.club_short_name) = v_club
      AND l.entry_type = 'infra_purchase'
      AND coalesce(l.metadata->>'source', '') = 'handpick_mid_season_takeover'
      AND coalesce(l.metadata->>'kind', '') = 'club_takeover_fee'
      AND l.created_at >= (now() - interval '2 days')
  ) THEN
    SELECT coalesce(f.balance, 0) INTO v_bal
    FROM public."Club_Finances" f
    WHERE upper(f.club_name) = v_club;
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'takeover_fee_already_posted',
      'club', v_club,
      'balance', v_bal,
      'stadium_cost', v_stadium,
      'starting_balance', v_target
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE upper(f.club_name) = v_club
  ) THEN
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_club, 0);
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_bal
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club
  FOR UPDATE;

  -- 1) Replace current cash with starting balance (history rows stay)
  v_delta := v_target - coalesce(v_bal, 0);
  IF v_delta <> 0 THEN
    v_start_ledger := public.post_club_ledger(
      v_club,
      'adjustment',
      v_delta,
      format(
        'Mid-season club takeover — starting balance → %s (was %s)',
        to_char(v_target, 'FM999,999,999,990'),
        to_char(coalesce(v_bal, 0), 'FM999,999,999,990')
      ),
      jsonb_build_object(
        'source', 'handpick_mid_season_takeover',
        'kind', 'takeover_starting_balance',
        'club', v_club,
        'balance_before', v_bal,
        'target_balance', v_target,
        'delta', v_delta,
        'via_claim', v_claim
      ),
      NULL,
      NULL,
      true,  -- Central Bank leg
      true
    );
  END IF;

  -- 2) Club takeover Fee = same stadium purchase cost as new owners
  IF v_stadium > 0 THEN
    v_fee_ledger := public.post_club_ledger(
      v_club,
      'infra_purchase',
      -v_stadium,
      format(
        'Club takeover Fee — Stadium %s (%s) — ₿%s (capacity × stadium rate)',
        coalesce(v_name, v_club),
        v_club,
        to_char(v_stadium, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'source', 'handpick_mid_season_takeover',
        'kind', 'club_takeover_fee',
        'club', v_club,
        'stadium_cost', v_stadium,
        'starting_budget', v_target,
        'dup_key', v_dup,
        'via_claim', v_claim,
        'note', 'Same fee as starting-owner stadium purchase; labelled as buying the club'
      ),
      NULL,
      NULL,
      false,
      true   -- apply to Club_Finances
    );
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_bal
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'skipped', false,
    'club', v_club,
    'club_name', v_name,
    'starting_balance', v_target,
    'stadium_cost', v_stadium,
    'balance_after', v_bal,
    'starting_ledger_id', v_start_ledger,
    'takeover_fee_ledger_id', v_fee_ledger,
    'via_claim', v_claim
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_apply_takeover_finances(text, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_apply_takeover_finances(text, boolean)
  TO authenticated;

COMMENT ON FUNCTION public.handpick_apply_takeover_finances(text, boolean) IS
  'Mid-season vacant-club takeover: set cash to starting balance, charge Club takeover Fee (stadium cost). Does not rewrite prior ledger history or other clubs.';

-- ---------------------------------------------------------------------------
-- Wire into handpick enable (claim + admin)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_club_handpick_set(
  p_club_short_name text,
  p_enabled boolean,
  p_confirm_reset boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $function$
DECLARE
  v_club_in text := upper(btrim(coalesce(p_club_short_name, '')));
  v_club text;
  v_name text;
  v_was boolean := false;
  v_mgr_id bigint;
  v_pid text;
  v_released int := 0;
  v_listings_closed int := 0;
  v_mgr_result jsonb;
  v_claim boolean := current_setting('gpsl.handpick_claim', true) = 'on';
  v_fin jsonb;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT public.is_gpsl_admin()
     AND NOT v_claim THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club_in = '' OR v_club_in = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  SELECT c."ShortName", c."Club", coalesce(c.handpick_intake, false)
  INTO v_club, v_name, v_was
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club_in
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found', 'club', v_club_in);
  END IF;

  IF NOT coalesce(p_enabled, false) THEN
    IF v_claim THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'claim_cannot_disable');
    END IF;
    UPDATE public."Clubs"
    SET handpick_intake = false
    WHERE "ShortName" = v_club;

    UPDATE public.club_handpick_submissions
    SET status = 'rejected',
        reviewed_at = now(),
        reviewed_by = auth.uid(),
        review_note = coalesce(review_note, 'Handpick turned off')
    WHERE club_short_name = v_club
      AND status = 'pending';

    RETURN jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_name', v_name,
      'handpick_intake', false,
      'was_handpick', v_was,
      'action', 'disabled'
    );
  END IF;

  IF v_was THEN
    RETURN jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_name', v_name,
      'handpick_intake', true,
      'already_on', true,
      'action', 'noop'
    );
  END IF;

  IF NOT coalesce(p_confirm_reset, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'confirm_required',
      'club', v_club,
      'club_name', v_name,
      'detail',
        'Confirm: release squad to FA, clear manager, set cash to starting balance, charge Club takeover Fee (stadium). Prior season history kept; other clubs untouched.'
    );
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.status IN ('Active', 'Review')
    AND EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = l.player_id::text
        AND upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
    );
  GET DIAGNOSTICS v_listings_closed = ROW_COUNT;

  FOR v_pid IN
    SELECT p."Konami_ID"::text
    FROM public."Players" p
    WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
  LOOP
    IF to_regprocedure('public.player_release_from_club(text)') IS NOT NULL THEN
      PERFORM public.player_release_from_club(v_pid);
    ELSE
      UPDATE public."Players"
      SET "Contracted_Team" = NULL,
          "Season_Signed" = NULL,
          contract_seasons_remaining = NULL,
          contract_wage = NULL
      WHERE "Konami_ID"::text = v_pid;
    END IF;
    v_released := v_released + 1;
  END LOOP;

  SELECT m.id INTO v_mgr_id
  FROM public."Managers" m
  WHERE upper(nullif(btrim(m.contracted_club::text), '')) = v_club
  LIMIT 1;

  IF v_mgr_id IS NULL THEN
    SELECT c.manager_id INTO v_mgr_id
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;
  END IF;

  IF v_mgr_id IS NOT NULL THEN
    BEGIN
      v_mgr_result := public.manager_release_from_club(
        v_mgr_id,
        NULL,
        0,
        'adjustment',
        format('Handpick intake — manager cleared (%s)', v_club),
        jsonb_build_object(
          'source', 'handpick_intake_reset',
          'club', v_club,
          'no_payout', true
        )
      );
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Managers"
      SET contracted_club = NULL,
          contract_seasons_remaining = 0,
          weekly_wage = 0,
          updated_at = now()
      WHERE id = v_mgr_id;
      UPDATE public."Clubs"
      SET manager_id = NULL,
          manager_rating = NULL
      WHERE "ShortName" = v_club;
      v_mgr_result := jsonb_build_object(
        'ok', true, 'fallback', true, 'manager_id', v_mgr_id, 'error', SQLERRM
      );
    END;
  END IF;

  v_fin := public.handpick_apply_takeover_finances(v_club, v_claim);

  UPDATE public."Clubs"
  SET handpick_intake = true,
      handpick_started_at = now(),
      manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = v_club;

  UPDATE public.club_handpick_submissions
  SET status = 'withdrawn',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = 'Superseded by handpick reset'
  WHERE club_short_name = v_club
    AND status = 'pending';

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'club_name', v_name,
    'handpick_intake', true,
    'was_handpick', v_was,
    'action', 'enabled',
    'players_released', v_released,
    'listings_closed', v_listings_closed,
    'manager', v_mgr_result,
    'finances', v_fin,
    'starting_balance', v_fin->'starting_balance',
    'stadium_cost', v_fin->'stadium_cost',
    'balance_after', v_fin->'balance_after',
    'via_claim', v_claim
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_club_handpick_set(text, boolean, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_club_handpick_set(text, boolean, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- One-shot: apply takeover finances to Marseille (already in handpick)
-- ---------------------------------------------------------------------------
DO $mar$
DECLARE
  v_fin jsonb;
  v_on boolean;
BEGIN
  SELECT coalesce(c.handpick_intake, false) INTO v_on
  FROM public."Clubs" c
  WHERE c."ShortName" = 'MAR';

  IF NOT coalesce(v_on, false) THEN
    RAISE NOTICE 'MAR not in handpick — skip finance repair';
    RETURN;
  END IF;

  v_fin := public.handpick_apply_takeover_finances('MAR', true);
  RAISE NOTICE 'MAR takeover finances: %', v_fin;
END;
$mar$;

NOTIFY pgrst, 'reload schema';

SELECT
  f.balance AS mar_balance,
  public.club_stadium_infra_purchase_cost('MAR') AS stadium_cost,
  public.handpick_target_balance() AS starting_bal
FROM public."Club_Finances" f
WHERE upper(f.club_name) = 'MAR';
