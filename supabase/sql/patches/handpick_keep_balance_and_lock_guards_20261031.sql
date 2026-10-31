-- Mid-season handpick:
-- 1) Do NOT grant a fresh ₿650m starting budget (inherit club cash, incl. overdraft).
-- 2) Reverse Marseille's mistaken rebuild bailout (ledger id 52484).
-- 3) Block foreign / paid-up / unsignable FAs from handpick basket tags + search.
-- Safe re-run.

-- ---------------------------------------------------------------------------
-- Reverse MAR bailout (only if still at the post-bailout balance)
-- ---------------------------------------------------------------------------
DO $rev$
DECLARE
  v_bal numeric;
  v_delta numeric := -677109389;
  v_expected numeric := 650000000;
  v_restore numeric := -27109389;
  v_ledger_id bigint;
  v_already boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE upper(l.club_short_name) = 'MAR'
      AND coalesce(l.metadata->>'source', '') = 'handpick_intake_reset_reverse'
      AND coalesce(l.metadata->>'reverses_ledger_id', '') = '52484'
  ) INTO v_already;

  IF v_already THEN
    RAISE NOTICE 'MAR handpick reverse already posted — skip';
    RETURN;
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_bal
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = 'MAR'
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE NOTICE 'MAR Club_Finances missing — skip reverse';
    RETURN;
  END IF;

  -- Only reverse if balance still matches the bailout target (no spend yet).
  IF round(v_bal, 2) <> round(v_expected, 2) THEN
    RAISE NOTICE 'MAR balance % is not %, skip auto-reverse (manual check needed)',
      v_bal, v_expected;
    RETURN;
  END IF;

  v_ledger_id := public.post_club_ledger(
    'MAR',
    'adjustment',
    v_delta,
    format(
      'Reverse mistaken mid-season handpick rebuild bailout — restore pre-handpick balance %s (was %s)',
      to_char(v_restore, 'FM999,999,999,990'),
      to_char(v_expected, 'FM999,999,999,990')
    ),
    jsonb_build_object(
      'source', 'handpick_intake_reset_reverse',
      'kind', 'correct_no_fresh_starting_budget',
      'club', 'MAR',
      'reverses_ledger_id', 52484,
      'balance_before_handpick', v_restore,
      'balance_after_bailout', v_expected,
      'delta', v_delta
    ),
    NULL,
    NULL,
    true,
    true
  );

  RAISE NOTICE 'MAR reverse posted ledger_id=%', v_ledger_id;
END;
$rev$;

-- ---------------------------------------------------------------------------
-- Handpick enable: keep existing cash (no ₿650m reset)
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
  v_bal numeric := 0;
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
    SELECT coalesce(f.balance, 0) INTO v_bal
    FROM public."Club_Finances" f
    WHERE upper(f.club_name) = v_club;
    RETURN jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_name', v_name,
      'handpick_intake', true,
      'already_on', true,
      'action', 'noop',
      'balance', coalesce(v_bal, 0)
    );
  END IF;

  IF NOT coalesce(p_confirm_reset, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'confirm_required',
      'club', v_club,
      'club_name', v_name,
      'detail',
        'Confirm reset: release squad to FA and clear manager. Club cash is kept as-is (no fresh starting budget).'
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

  -- Ensure finances row exists, but DO NOT top up / wipe cash.
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
    'balance_kept', v_bal,
    'balance_before', v_bal,
    'cash_reset', false,
    'manager', v_mgr_result,
    'via_claim', v_claim,
    'note', 'Club cash kept as-is (no fresh starting budget).'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_club_handpick_set(text, boolean, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_club_handpick_set(text, boolean, boolean)
  TO authenticated;

COMMENT ON FUNCTION public.handpick_target_balance() IS
  'Legacy auction starting balance helper. Mid-season handpick no longer resets club cash to this value.';

-- ---------------------------------------------------------------------------
-- Basket toggle: reject foreign/paid-up locks + signing guards
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handpick_basket_toggle(
  p_player_id text,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_handpick boolean := false;
  v_exists boolean := false;
  v_team text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_player');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF NOT v_handpick THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_in_handpick',
      'detail', 'Handpick intake is not open for this club.'
    );
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE b.club_short_name = v_club AND b.player_id = v_pid
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_club AND player_id = v_pid;
    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'player_id', v_pid
    );
  END IF;

  SELECT nullif(btrim(p."Contracted_Team"::text), '') INTO v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'player_not_found');
  END IF;

  IF v_team IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_free_agent',
      'detail', 'Only free agents can be handpick-tagged.'
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
      AND coalesce(p.pesdb_unavailable, false)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'legacy_card');
  END IF;

  IF to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
     AND public.gpdb_player_is_season_excluded(v_pid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'season_excluded');
  END IF;

  IF to_regprocedure('public.player_foreign_contract_locked(text)') IS NOT NULL
     AND public.player_foreign_contract_locked(v_pid) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'foreign_or_paid_up_lock',
      'detail', 'Unavailable until next season (foreign / paid-up lock).'
    );
  END IF;

  BEGIN
    IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
      PERFORM public.assert_player_available_for_signing(v_pid);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_signable',
      'detail', SQLERRM
    );
  END;

  INSERT INTO public.club_handpick_basket (club_short_name, player_id, added_by)
  VALUES (v_club, v_pid, auth.uid())
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'ok', true,
    'tagged', true,
    'club', v_club,
    'player_id', v_pid
  );
END;
$function$;

-- Search: exclude locked FAs
CREATE OR REPLACE FUNCTION public.handpick_search_free_agents(
  p_query text DEFAULT NULL,
  p_limit int DEFAULT 30,
  p_nation text DEFAULT NULL,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' AND NOT public.is_gpsl_admin() THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_club
      AND coalesce(c.handpick_intake, false)
  ) AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Club is not in handpick intake';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(r) ORDER BY r.rating DESC NULLS LAST, r.player_name)
    FROM (
      SELECT
        p."Konami_ID"::text AS player_id,
        p."Name" AS player_name,
        p."Position" AS position,
        p."Rating" AS rating,
        p."Nation" AS nation,
        coalesce(
          nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
          0
        ) AS market_value,
        coalesce(p.pesdb_unavailable, false) AS legacy
      FROM public."Players" p
      WHERE nullif(btrim(p."Contracted_Team"::text), '') IS NULL
        AND coalesce(p.pesdb_unavailable, false) = false
        AND (
          nullif(btrim(coalesce(p_nation, '')), '') IS NULL
          OR lower(btrim(p."Nation"::text)) = lower(btrim(p_nation))
        )
        AND (
          length(btrim(coalesce(p_query, ''))) < 2
          OR lower(p."Name") LIKE '%' || lower(btrim(p_query)) || '%'
          OR p."Konami_ID"::text = btrim(p_query)
        )
        AND (
          to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NULL
          OR NOT public.gpdb_player_is_season_excluded(p."Konami_ID"::text)
        )
        AND (
          to_regprocedure('public.player_foreign_contract_locked(text)') IS NULL
          OR NOT public.player_foreign_contract_locked(p."Konami_ID"::text)
        )
      ORDER BY p."Rating" DESC NULLS LAST, p."Name"
      LIMIT greatest(1, least(coalesce(p_limit, 30), 80))
    ) r
  ), '[]'::jsonb);
END;
$function$;

-- Context: expose kept balance; stop advertising 650m rebuild pot as cash
CREATE OR REPLACE FUNCTION public.handpick_club_context(p_club_short_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_my text;
  v_ctx jsonb;
  v_pending jsonb;
  v_handpick boolean := false;
  v_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    IF public.is_gpsl_admin() THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'club_required');
    END IF;
    v_my := public.my_club_shortname();
    v_club := upper(btrim(coalesce(v_my, '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed for this club';
  END IF;

  SELECT coalesce(c.handpick_intake, false), c."Club"
  INTO v_handpick, v_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF public.is_gpsl_admin()
     AND to_regprocedure('public.admin_sign_fa_club_build_context(text)') IS NOT NULL THEN
    v_ctx := public.admin_sign_fa_club_build_context(v_club);
  ELSE
    SELECT jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_nation', c."Nation",
      'balance', coalesce(f.balance, 0),
      'income_tax_pct', coalesce((SELECT g.gov_income_tax_pct FROM public.global_settings g LIMIT 1), 0),
      'manager', (
        SELECT to_jsonb(m)
        FROM (
          SELECT mgr.id AS manager_id, mgr.name AS manager_name,
                 mgr.rating AS manager_rating, mgr.market_value AS manager_market_value
          FROM public."Managers" mgr
          WHERE upper(nullif(btrim(mgr.contracted_club::text), '')) = v_club
          LIMIT 1
        ) m
      ),
      'players', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'player_name', p."Name",
          'position', p."Position",
          'rating', p."Rating",
          'market_value', coalesce(
            nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          )
        ) ORDER BY p."Name")
        FROM public."Players" p
        WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
      ), '[]'::jsonb),
      'min_squad_size', 24,
      'max_squad_size', 28,
      'target_squad_size', 24,
      'min_home_grown', 8,
      'min_under_21', 5,
      'min_goalkeepers', 1
    )
    INTO v_ctx
    FROM public."Clubs" c
    LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = v_club
    WHERE upper(c."ShortName") = v_club;
  END IF;

  SELECT to_jsonb(s) INTO v_pending
  FROM public.club_handpick_submissions s
  WHERE s.club_short_name = v_club
    AND s.status = 'pending'
  ORDER BY s.submitted_at DESC
  LIMIT 1;

  RETURN coalesce(v_ctx, jsonb_build_object('ok', false))
    || jsonb_build_object(
      'handpick_intake', v_handpick,
      'club_name', v_name,
      'cash_reset', false,
      'pending_submission', v_pending,
      'is_admin', public.is_gpsl_admin()
    );
END;
$function$;

NOTIFY pgrst, 'reload schema';

SELECT balance AS mar_balance_after
FROM public."Club_Finances"
WHERE upper(club_name) = 'MAR';
