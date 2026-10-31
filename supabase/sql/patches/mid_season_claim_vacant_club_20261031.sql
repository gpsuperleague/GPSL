-- =============================================================================
-- Mid-season: waiting-list members claim a vacant club → handpick intake ON
-- Pre-season / setup: no claim — waiting list + club auction (existing flow)
--
-- RPCs:
--   gpsl_owner_intake_mode()              → pre_season | mid_season
--   waiting_list_vacant_clubs_for_claim() → list + whether caller may claim
--   waiting_list_claim_vacant_club(text)  → assign + handpick reset
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_owner_intake_mode()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
BEGIN
  SELECT lower(nullif(btrim(s.status), ''))
  INTO v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  -- Live season → mid-season intake (pick vacant club + handpick)
  IF v_status = 'active' THEN
    RETURN 'mid_season';
  END IF;

  -- setup / preseason / summer_break / unknown → auction path
  RETURN 'pre_season';
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_owner_intake_mode() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_owner_intake_mode() TO authenticated;

CREATE OR REPLACE FUNCTION public.waiting_list_vacant_clubs_for_claim()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_mode text := public.gpsl_owner_intake_mode();
  v_status text;
  v_has_club boolean := false;
  v_season_id bigint;
  v_season_label text;
  v_can_claim boolean := false;
  v_reason text := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'mode', v_mode);
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c.owner_id = v_uid
      AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
  ) INTO v_has_club;

  IF v_has_club THEN
    v_reason := 'already_has_club';
  ELSIF v_status IS NULL OR v_status = 'archived' THEN
    v_reason := 'not_on_registry';
  ELSIF v_status = 'awaiting_club_auction' THEN
    v_reason := 'auction_invite_active';
  ELSIF NOT public.waiting_list_on_list_status(v_status) THEN
    v_reason := 'not_on_waiting_list';
  ELSIF v_mode IS DISTINCT FROM 'mid_season' THEN
    v_reason := 'pre_season_use_auction';
  ELSE
    v_can_claim := true;
  END IF;

  SELECT s.id, s.label
  INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'mode', v_mode,
    'can_claim', v_can_claim,
    'reason', v_reason,
    'registry_status', v_status,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'clubs', CASE
      WHEN v_mode IS DISTINCT FROM 'mid_season' OR v_season_id IS NULL THEN '[]'::jsonb
      ELSE coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'short_name', q.short_name,
            'club_name', q.club_name,
            'division', q.division,
            'division_label', q.division_label
          )
          ORDER BY q.div_rank, q.club_name
        )
        FROM (
          SELECT
            c."ShortName" AS short_name,
            coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
            ccs.division,
            CASE
              WHEN to_regprocedure('public.gpsl_discord_division_label(text)') IS NOT NULL
                THEN public.gpsl_discord_division_label(ccs.division)
              ELSE ccs.division
            END AS division_label,
            CASE lower(ccs.division)
              WHEN 'superleague' THEN 1
              WHEN 'championship_a' THEN 2
              WHEN 'championship_b' THEN 3
              ELSE 4
            END AS div_rank
          FROM public.competition_club_seasons ccs
          JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
          WHERE ccs.season_id = v_season_id
            AND c.owner_id IS NULL
            AND upper(c."ShortName") <> 'FOREIGN'
            AND coalesce(c.is_archived, false) = false
        ) q
      ), '[]'::jsonb)
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.waiting_list_vacant_clubs_for_claim() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.waiting_list_vacant_clubs_for_claim() TO authenticated;

CREATE OR REPLACE FUNCTION public.waiting_list_claim_vacant_club(
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_mode text := public.gpsl_owner_intake_mode();
  v_short text := upper(btrim(coalesce(p_club_short_name, '')));
  v_status text;
  v_club text;
  v_club_name text;
  v_owner_id uuid;
  v_handpick jsonb;
  v_gate jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_mode IS DISTINCT FROM 'mid_season' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'pre_season_use_auction',
      'mode', v_mode,
      'detail', 'Club self-pick is only available mid-season. Stay on the waiting list for the club auction.'
    );
  END IF;

  IF v_short = '' OR v_short = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  v_gate := public.waiting_list_vacant_clubs_for_claim();
  IF NOT coalesce((v_gate->>'can_claim')::boolean, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', coalesce(v_gate->>'reason', 'cannot_claim'),
      'mode', v_mode
    );
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid
  FOR UPDATE;

  -- Lock vacant club
  SELECT c."ShortName", c."Club", c.owner_id
  INTO v_club, v_club_name, v_owner_id
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_short
  FOR UPDATE;

  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF v_owner_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_taken', 'club', v_club);
  END IF;

  IF coalesce((
    SELECT c.is_archived FROM public."Clubs" c WHERE c."ShortName" = v_club
  ), false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_archived');
  END IF;

  -- Assign to claimant (clear any other club first)
  UPDATE public."Clubs"
  SET owner_id = NULL, owner = NULL
  WHERE owner_id = v_uid
    AND "ShortName" <> v_club;

  UPDATE public."Clubs"
  SET owner_id = v_uid
  WHERE "ShortName" = v_club
    AND owner_id IS NULL;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'assign_race_lost', 'club', v_club);
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, last_club_short_name, status_changed_at)
  VALUES (v_uid, 'active', v_club, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      last_club_short_name = v_club,
      status_note = NULL,
      waiting_list_tier = NULL,
      waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false,
      returned_to_list_at = NULL,
      absence_note = NULL,
      status_changed_at = now();

  IF to_regprocedure('public.waiting_list_leave_list(uuid)') IS NOT NULL THEN
    PERFORM public.waiting_list_leave_list(v_uid);
  END IF;

  -- Enable handpick with full reset (system path — session GUC unlocks admin RPC)
  PERFORM set_config('gpsl.handpick_claim', 'on', true);
  v_handpick := public.admin_club_handpick_set(v_club, true, true);

  IF coalesce((v_handpick->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'handpick_failed',
      'club', v_club,
      'club_name', v_club_name,
      'assigned', true,
      'handpick', v_handpick
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'mode', 'mid_season',
    'club', v_club,
    'club_name', v_club_name,
    'handpick_intake', true,
    'redirect', 'handpick_squad.html?club=' || v_club,
    'handpick', v_handpick
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.waiting_list_claim_vacant_club(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.waiting_list_claim_vacant_club(text) TO authenticated;

-- Allow claim path to run handpick reset (admin RPC checks GUC)
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
  v_bal numeric := 0;
  v_target numeric := public.handpick_target_balance();
  v_delta numeric := 0;
  v_ledger_id bigint;
  v_mgr_result jsonb;
  v_claim boolean := current_setting('gpsl.handpick_claim', true) = 'on';
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
      'detail', 'Confirm reset: release squad to FA, clear manager, set cash to rebuild pot.'
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

  v_delta := v_target - coalesce(v_bal, 0);

  IF v_delta <> 0 THEN
    v_ledger_id := public.post_club_ledger(
      v_club,
      'adjustment',
      v_delta,
      format(
        'Mid-season handpick rebuild budget → %s (was %s)',
        to_char(v_target, 'FM999,999,999,990'),
        to_char(coalesce(v_bal, 0), 'FM999,999,999,990')
      ),
      jsonb_build_object(
        'source', 'handpick_intake_reset',
        'kind', 'mid_season_handpick_rebuild',
        'club', v_club,
        'balance_before', v_bal,
        'target_balance', v_target,
        'delta', v_delta,
        'via_claim', v_claim
      ),
      NULL,
      NULL,
      true,
      true
    );
  END IF;

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
    'target_balance', v_target,
    'balance_before', v_bal,
    'ledger_id', v_ledger_id,
    'manager', v_mgr_result,
    'via_claim', v_claim
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
