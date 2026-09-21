-- =============================================================================
-- Test-season reset: ex-owner waiting-list priority
--
-- After clubs are vacated, active test owners move onto the waiting list:
--   KEEP PRIORITY (top of board, ready for invite) when they pass BOTH:
--     • fewer than 4 unplayed fixtures in the current competition season
--     • at least 2 site logins in each of the previous 2 GPSL months
--       (if only one prior month exists, that month alone is checked)
--   DEMOTE into the general waiting pool when they fail either rule.
--
-- Existing waiting-list members keep relative order beneath retained owners.
-- Confirm ticks are left unchanged.
--
-- Safe re-run. Wired into admin_test_reset_execute Phase H.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_test_reset_apply_ex_owner_waiting_priority(
  p_starting_balance numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_starting numeric := greatest(coalesce(p_starting_balance, 0), 0);
  v_season_id bigint;
  v_cur text;
  v_prev text;
  v_prev2 text;
  v_prev_unlock timestamptz;
  v_prev_lock timestamptz;
  v_prev2_unlock timestamptz;
  v_prev2_lock timestamptz;
  v_retained int := 0;
  v_demoted int := 0;
  v_waiters int := 0;
  v_sort int := 0;
  r record;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_starting <= 0 THEN
    BEGIN
      v_starting := greatest(coalesce(public.club_auction_default_starting_balance(), 0), 0);
    EXCEPTION WHEN OTHERS THEN
      v_starting := 0;
    END;
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_season_id IS NOT NULL THEN
    BEGIN
      v_cur := public.competition_active_gpsl_month(v_season_id, now());
    EXCEPTION WHEN OTHERS THEN
      v_cur := NULL;
    END;

    IF v_cur IS NOT NULL THEN
      SELECT m.gpsl_month, m.unlock_at, m.lock_at
      INTO v_prev, v_prev_unlock, v_prev_lock
      FROM public.competition_season_calendar m
      WHERE m.season_id = v_season_id
        AND public.competition_gpsl_month_sort(m.gpsl_month)
          < public.competition_gpsl_month_sort(v_cur)
      ORDER BY public.competition_gpsl_month_sort(m.gpsl_month) DESC
      LIMIT 1;

      IF v_prev IS NOT NULL THEN
        SELECT m.gpsl_month, m.unlock_at, m.lock_at
        INTO v_prev2, v_prev2_unlock, v_prev2_lock
        FROM public.competition_season_calendar m
        WHERE m.season_id = v_season_id
          AND public.competition_gpsl_month_sort(m.gpsl_month)
            < public.competition_gpsl_month_sort(v_prev)
        ORDER BY public.competition_gpsl_month_sort(m.gpsl_month) DESC
        LIMIT 1;
      END IF;
    END IF;
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _test_reset_ex_owners (
    owner_id uuid PRIMARY KEY,
    owner_tag text,
    club_short text,
    prior_admin_sort int,
    account_created_at timestamptz,
    unplayed_season int NOT NULL DEFAULT 0,
    logins_prev int,
    logins_prev2 int,
    fail_unplayed boolean NOT NULL DEFAULT false,
    fail_logins boolean NOT NULL DEFAULT false,
    retain boolean NOT NULL DEFAULT false
  ) ON COMMIT DROP;

  TRUNCATE _test_reset_ex_owners;

  INSERT INTO _test_reset_ex_owners (
    owner_id, owner_tag, club_short, prior_admin_sort, account_created_at,
    unplayed_season, logins_prev, logins_prev2, fail_unplayed, fail_logins, retain
  )
  SELECT
    r.owner_id,
    coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—'),
    nullif(btrim(coalesce(r.last_club_short_name, '')), ''),
    r.waiting_list_admin_sort,
    u.created_at,
    coalesce(up.unplayed_season, 0),
    CASE WHEN v_prev_unlock IS NULL THEN NULL ELSE coalesce(lp.logins_prev, 0) END,
    CASE WHEN v_prev2_unlock IS NULL THEN NULL ELSE coalesce(lp.logins_prev2, 0) END,
    coalesce(up.unplayed_season, 0) >= 4,
    (
      (v_prev_unlock IS NOT NULL AND coalesce(lp.logins_prev, 0) < 2)
      OR (v_prev2_unlock IS NOT NULL AND coalesce(lp.logins_prev2, 0) < 2)
    ),
    NOT (
      coalesce(up.unplayed_season, 0) >= 4
      OR (v_prev_unlock IS NOT NULL AND coalesce(lp.logins_prev, 0) < 2)
      OR (v_prev2_unlock IS NOT NULL AND coalesce(lp.logins_prev2, 0) < 2)
    )
  FROM public.gpsl_owner_registry r
  JOIN auth.users u ON u.id = r.owner_id
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS unplayed_season
    FROM public.competition_fixtures f
    WHERE v_season_id IS NOT NULL
      AND f.season_id = v_season_id
      AND coalesce(f.status, '') NOT IN ('played', 'cancelled')
      AND nullif(btrim(coalesce(r.last_club_short_name, '')), '') IS NOT NULL
      AND (
        f.home_club_short_name = r.last_club_short_name
        OR f.away_club_short_name = r.last_club_short_name
      )
  ) up ON true
  LEFT JOIN LATERAL (
    SELECT
      count(*) FILTER (
        WHERE v_prev_unlock IS NOT NULL
          AND e.logged_in_at >= v_prev_unlock
          AND e.logged_in_at < coalesce(v_prev_lock, now())
      )::int AS logins_prev,
      count(*) FILTER (
        WHERE v_prev2_unlock IS NOT NULL
          AND e.logged_in_at >= v_prev2_unlock
          AND e.logged_in_at < coalesce(v_prev2_lock, v_prev_unlock, now())
      )::int AS logins_prev2
    FROM public.owner_site_login_events e
    WHERE e.owner_id = r.owner_id
  ) lp ON true
  WHERE r.status = 'active';

  SELECT
    count(*) FILTER (WHERE retain)::int,
    count(*) FILTER (WHERE NOT retain)::int
  INTO v_retained, v_demoted
  FROM _test_reset_ex_owners;

  CREATE TEMP TABLE IF NOT EXISTS _test_reset_waiters (
    owner_id uuid PRIMARY KEY,
    prior_admin_sort int,
    account_created_at timestamptz,
    tier text
  ) ON COMMIT DROP;

  TRUNCATE _test_reset_waiters;

  INSERT INTO _test_reset_waiters (owner_id, prior_admin_sort, account_created_at, tier)
  SELECT
    r.owner_id,
    r.waiting_list_admin_sort,
    u.created_at,
    r.waiting_list_tier
  FROM public.gpsl_owner_registry r
  JOIN auth.users u ON u.id = r.owner_id
  WHERE public.waiting_list_on_list_status(r.status)
    AND NOT EXISTS (
      SELECT 1 FROM _test_reset_ex_owners x WHERE x.owner_id = r.owner_id
    );

  GET DIAGNOSTICS v_waiters = ROW_COUNT;

  -- Retained owners: top of board, member, ready for invite
  v_sort := 0;
  FOR r IN
    SELECT *
    FROM _test_reset_ex_owners
    WHERE retain
    ORDER BY prior_admin_sort NULLS LAST, account_created_at, owner_id
  LOOP
    v_sort := v_sort + 1000;
    UPDATE public.gpsl_owner_registry
    SET status = 'member',
        waiting_list_tier = 'returning',
        waiting_list_admin_sort = v_sort,
        waiting_list_use_admin_sort = true,
        pending_starting_balance = CASE
          WHEN v_starting > 0 THEN v_starting
          ELSE pending_starting_balance
        END,
        returned_to_list_at = coalesce(returned_to_list_at, now()),
        absence_note = NULL,
        status_changed_at = now()
    WHERE owner_id = r.owner_id;
  END LOOP;

  -- General pool: existing waiters, then demoted owners
  FOR r IN
    SELECT *
    FROM (
      SELECT
        w.owner_id,
        0 AS pool_kind,
        w.prior_admin_sort,
        public.waiting_list_tier_rank(w.tier) AS tier_rank,
        w.account_created_at
      FROM _test_reset_waiters w
      UNION ALL
      SELECT
        x.owner_id,
        1 AS pool_kind,
        x.prior_admin_sort,
        public.waiting_list_tier_rank('returning') AS tier_rank,
        x.account_created_at
      FROM _test_reset_ex_owners x
      WHERE NOT x.retain
    ) pool
    ORDER BY pool_kind, prior_admin_sort NULLS LAST, tier_rank, account_created_at, owner_id
  LOOP
    v_sort := v_sort + 1000;
    IF r.pool_kind = 0 THEN
      UPDATE public.gpsl_owner_registry
      SET waiting_list_admin_sort = v_sort,
          waiting_list_use_admin_sort = true
      WHERE owner_id = r.owner_id;
    ELSE
      UPDATE public.gpsl_owner_registry
      SET status = 'member',
          waiting_list_tier = 'returning',
          waiting_list_admin_sort = v_sort,
          waiting_list_use_admin_sort = true,
          pending_starting_balance = CASE
            WHEN v_starting > 0 THEN v_starting
            ELSE pending_starting_balance
          END,
          returned_to_list_at = now(),
          absence_note = NULL,
          status_changed_at = now()
      WHERE owner_id = r.owner_id;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'retained_priority', v_retained,
    'demoted_to_waiting', v_demoted,
    'existing_waiters_reordered', v_waiters,
    'season_id', v_season_id,
    'current_gpsl_month', v_cur,
    'previous_gpsl_month', v_prev,
    'previous2_gpsl_month', v_prev2,
    'rules', jsonb_build_object(
      'max_unplayed_to_retain', 3,
      'min_logins_per_previous_gpsl_month', 2,
      'previous_months_checked', CASE
        WHEN v_prev2_unlock IS NOT NULL THEN 2
        WHEN v_prev_unlock IS NOT NULL THEN 1
        ELSE 0
      END
    ),
    'retained', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'owner_id', owner_id,
        'owner_tag', owner_tag,
        'club_short', club_short,
        'unplayed_season', unplayed_season,
        'logins_prev', logins_prev,
        'logins_prev2', logins_prev2
      ) ORDER BY prior_admin_sort NULLS LAST, account_created_at)
      FROM _test_reset_ex_owners WHERE retain
    ), '[]'::jsonb),
    'demoted', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'owner_id', owner_id,
        'owner_tag', owner_tag,
        'club_short', club_short,
        'unplayed_season', unplayed_season,
        'logins_prev', logins_prev,
        'logins_prev2', logins_prev2,
        'fail_unplayed', fail_unplayed,
        'fail_logins', fail_logins
      ) ORDER BY account_created_at)
      FROM _test_reset_ex_owners WHERE NOT retain
    ), '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.admin_test_reset_apply_ex_owner_waiting_priority(numeric) IS
  'After test reset vacate: keep engaged ex-owners at top of waiting list; demote inactive into the general queue.';

GRANT EXECUTE ON FUNCTION public.admin_test_reset_apply_ex_owner_waiting_priority(numeric)
  TO authenticated;

-- Dry-run preview for current club owners (no writes)
CREATE OR REPLACE FUNCTION public.admin_test_reset_preview_ex_owner_waiting_priority()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_cur text;
  v_prev text;
  v_prev2 text;
  v_prev_unlock timestamptz;
  v_prev_lock timestamptz;
  v_prev2_unlock timestamptz;
  v_prev2_lock timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_season_id IS NOT NULL THEN
    BEGIN
      v_cur := public.competition_active_gpsl_month(v_season_id, now());
    EXCEPTION WHEN OTHERS THEN
      v_cur := NULL;
    END;

    IF v_cur IS NOT NULL THEN
      SELECT m.gpsl_month, m.unlock_at, m.lock_at
      INTO v_prev, v_prev_unlock, v_prev_lock
      FROM public.competition_season_calendar m
      WHERE m.season_id = v_season_id
        AND public.competition_gpsl_month_sort(m.gpsl_month)
          < public.competition_gpsl_month_sort(v_cur)
      ORDER BY public.competition_gpsl_month_sort(m.gpsl_month) DESC
      LIMIT 1;

      IF v_prev IS NOT NULL THEN
        SELECT m.gpsl_month, m.unlock_at, m.lock_at
        INTO v_prev2, v_prev2_unlock, v_prev2_lock
        FROM public.competition_season_calendar m
        WHERE m.season_id = v_season_id
          AND public.competition_gpsl_month_sort(m.gpsl_month)
            < public.competition_gpsl_month_sort(v_prev)
        ORDER BY public.competition_gpsl_month_sort(m.gpsl_month) DESC
        LIMIT 1;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'current_gpsl_month', v_cur,
    'previous_gpsl_month', v_prev,
    'previous2_gpsl_month', v_prev2,
    'owners', coalesce((
      SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.retain DESC, x.prior_admin_sort NULLS LAST, x.account_created_at)
      FROM (
        SELECT
          r.owner_id,
          coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
          nullif(btrim(coalesce(
            (SELECT c."ShortName" FROM public."Clubs" c WHERE c.owner_id = r.owner_id LIMIT 1),
            r.last_club_short_name,
            ''
          )), '') AS club_short,
          r.waiting_list_admin_sort AS prior_admin_sort,
          u.created_at AS account_created_at,
          coalesce(up.unplayed_season, 0) AS unplayed_season,
          CASE WHEN v_prev_unlock IS NULL THEN NULL ELSE coalesce(lp.logins_prev, 0) END AS logins_prev,
          CASE WHEN v_prev2_unlock IS NULL THEN NULL ELSE coalesce(lp.logins_prev2, 0) END AS logins_prev2,
          coalesce(up.unplayed_season, 0) >= 4 AS fail_unplayed,
          (
            (v_prev_unlock IS NOT NULL AND coalesce(lp.logins_prev, 0) < 2)
            OR (v_prev2_unlock IS NOT NULL AND coalesce(lp.logins_prev2, 0) < 2)
          ) AS fail_logins,
          NOT (
            coalesce(up.unplayed_season, 0) >= 4
            OR (v_prev_unlock IS NOT NULL AND coalesce(lp.logins_prev, 0) < 2)
            OR (v_prev2_unlock IS NOT NULL AND coalesce(lp.logins_prev2, 0) < 2)
          ) AS retain
        FROM public.gpsl_owner_registry r
        JOIN auth.users u ON u.id = r.owner_id
        LEFT JOIN LATERAL (
          SELECT count(*)::int AS unplayed_season
          FROM public.competition_fixtures f
          CROSS JOIN LATERAL (
            SELECT nullif(btrim(coalesce(
              (SELECT c."ShortName" FROM public."Clubs" c WHERE c.owner_id = r.owner_id LIMIT 1),
              r.last_club_short_name,
              ''
            )), '') AS club_short
          ) club
          WHERE v_season_id IS NOT NULL
            AND f.season_id = v_season_id
            AND coalesce(f.status, '') NOT IN ('played', 'cancelled')
            AND club.club_short IS NOT NULL
            AND (
              f.home_club_short_name = club.club_short
              OR f.away_club_short_name = club.club_short
            )
        ) up ON true
        LEFT JOIN LATERAL (
          SELECT
            count(*) FILTER (
              WHERE v_prev_unlock IS NOT NULL
                AND e.logged_in_at >= v_prev_unlock
                AND e.logged_in_at < coalesce(v_prev_lock, now())
            )::int AS logins_prev,
            count(*) FILTER (
              WHERE v_prev2_unlock IS NOT NULL
                AND e.logged_in_at >= v_prev2_unlock
                AND e.logged_in_at < coalesce(v_prev2_lock, v_prev_unlock, now())
            )::int AS logins_prev2
          FROM public.owner_site_login_events e
          WHERE e.owner_id = r.owner_id
        ) lp ON true
        WHERE r.status = 'active'
           OR EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
      ) x
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_test_reset_preview_ex_owner_waiting_priority()
  TO authenticated;

-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Wire Phase H into admin_test_reset_execute
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_test_reset_execute(
  p_confirm_phrase text,
  p_options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '600s'
AS $function$
DECLARE
  v_enabled boolean;
  v_audit_id bigint;
  v_preview jsonb;
  v_starting numeric;
  v_reset_owners boolean;
  v_clear_history boolean;
  v_seed_club boolean;
  v_deleted int;
  v_result jsonb := '{}'::jsonb;
BEGIN
  -- Hosted Supabase default timeout is often too short for a full wipe
  PERFORM set_config('statement_timeout', '600s', true);

  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(g.allow_test_environment_reset, false)
  INTO v_enabled
  FROM public.global_settings g
  WHERE g.id = 1;

  IF NOT v_enabled THEN
    RAISE EXCEPTION 'Test reset is disabled. Enable it on the admin page first (allow_test_environment_reset).';
  END IF;

  IF btrim(coalesce(p_confirm_phrase, '')) <> 'RESET TEST ENVIRONMENT' THEN
    RAISE EXCEPTION 'Confirmation phrase incorrect. Type exactly: RESET TEST ENVIRONMENT';
  END IF;

  v_starting := greatest(coalesce((p_options ->> 'starting_balance')::numeric, 650000000), 0);
  v_reset_owners := coalesce((p_options ->> 'reset_owners_to_auction')::boolean, true);
  -- Vanilla reset always clears competition / history archives (option kept for audit only).
  v_clear_history := true;
  v_seed_club := coalesce((p_options ->> 'seed_club_auction')::boolean, false);

  UPDATE public.global_settings
  SET club_auction_starting_balance = v_starting,
      updated_at = now()
  WHERE id = 1;

  v_preview := public.admin_test_reset_counts();

  INSERT INTO public.test_reset_audit_log (
    admin_email,
    confirm_phrase_used,
    options,
    preview_before
  )
  VALUES (
    coalesce(auth.jwt() ->> 'email', 'unknown'),
    true,
    coalesce(p_options, '{}'::jsonb),
    v_preview
  )
  RETURNING id INTO v_audit_id;

  -- Phase A: stop engines / schedules
  PERFORM public.admin_reset_draft_auction();

  -- Phase B0: copy owner tags into registry before vacate clears Clubs.owner
  INSERT INTO public.gpsl_owner_registry (
    owner_id,
    status,
    owner_tag,
    pending_starting_balance,
    last_club_short_name,
    status_changed_at
  )
  SELECT
    c.owner_id,
    'awaiting_club_auction',
    nullif(btrim(c.owner), ''),
    v_starting,
    c."ShortName",
    now()
  FROM public."Clubs" c
  WHERE c.owner_id IS NOT NULL
  ON CONFLICT (owner_id) DO UPDATE
  SET owner_tag = coalesce(
        nullif(btrim(excluded.owner_tag), ''),
        nullif(btrim(gpsl_owner_registry.owner_tag), '')
      ),
      last_club_short_name = coalesce(
        excluded.last_club_short_name,
        gpsl_owner_registry.last_club_short_name
      ),
      pending_starting_balance = excluded.pending_starting_balance,
      status_changed_at = now()
  WHERE gpsl_owner_registry.status <> 'archived';

  UPDATE public.gpsl_owner_registry r
  SET owner_tag = x.owner_tag
  FROM (
    SELECT DISTINCT ON (owner_id)
      owner_id,
      nullif(btrim(owner_tag), '') AS owner_tag
    FROM public.competition_owner_season_ranking
    WHERE nullif(btrim(owner_tag), '') IS NOT NULL
    ORDER BY owner_id, season_id DESC
  ) x
  WHERE r.owner_id = x.owner_id
    AND nullif(btrim(r.owner_tag), '') IS NULL;

  -- Phase B: detach all owners (bulk — faster than per-club vacate)
  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE is_active = true;

  UPDATE public."Clubs"
  SET owner_id = NULL,
      owner = NULL
  WHERE owner_id IS NOT NULL;

  IF to_regclass('public.gpsl_club_caretaker') IS NOT NULL THEN
    UPDATE public.gpsl_club_caretaker
    SET ended_at = now(),
        ended_by = 'TEST_RESET'
    WHERE ended_at IS NULL;
  END IF;

  IF to_regprocedure('public.international_admin_clear_nation_assignments()') IS NOT NULL THEN
    PERFORM public.international_admin_clear_nation_assignments();
  END IF;

  -- Phase C: transfer market + auctions (WHERE true — Supabase blocks bare DELETE)
  DELETE FROM public."Player_Transfer_Bids" WHERE true;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  v_result := v_result || jsonb_build_object('deleted_player_bids', v_deleted);

  DELETE FROM public."Manager_Transfer_Bids" WHERE true;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  v_result := v_result || jsonb_build_object('deleted_manager_bids', v_deleted);

  DELETE FROM public."Transfer_History" WHERE true;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  v_result := v_result || jsonb_build_object('deleted_transfer_history', v_deleted);

  DELETE FROM public."Player_Transfer_Listings" WHERE true;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  v_result := v_result || jsonb_build_object('deleted_player_listings', v_deleted);

  DELETE FROM public."Manager_Transfer_Listings" WHERE true;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  v_result := v_result || jsonb_build_object('deleted_manager_listings', v_deleted);

  v_result := v_result || public.admin_club_auction_reset();

  IF to_regclass('public.special_auction_gauntlet_bids') IS NOT NULL THEN
    DELETE FROM public.special_auction_gauntlet_bids WHERE true;
  END IF;
  DELETE FROM public.special_auction_bids WHERE true;
  DELETE FROM public.special_auctions WHERE true;

  -- Phase D: squads (bulk — no per-player ledger reversals)
  UPDATE public."Players"
  SET
    "Contracted_Team" = NULL,
    "Season_Signed" = NULL,
    contract_seasons_remaining = NULL,
    contract_wage = NULL,
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Contracted_Team" IS NOT NULL
     OR "Season_Signed" IS NOT NULL
     OR foreign_contract_club IS NOT NULL;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  v_result := v_result || jsonb_build_object('players_contract_cleared', v_deleted);

  -- Bulk clear manager contracts (seasons/wage are NOT NULL — use 0)
  UPDATE public."Managers"
  SET contracted_club = NULL,
      contract_seasons_remaining = 0,
      weekly_wage = 0,
      signed_season_id = NULL,
      updated_at = now()
  WHERE contracted_club IS NOT NULL
     OR weekly_wage <> 0
     OR signed_season_id IS NOT NULL
     OR contract_seasons_remaining <> 0;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL
  WHERE manager_id IS NOT NULL;

  -- Phase E: finances & loans
  DELETE FROM public.club_loan_installments
  WHERE loan_id IN (SELECT id FROM public.club_loans);
  DELETE FROM public.club_loans WHERE true;

  -- Applied fines reference fixtures + ledger; clear before ledger/season wipe.
  -- Keep competition_fine_tariff (admin config).
  IF to_regclass('public.competition_fine_applied') IS NOT NULL THEN
    DELETE FROM public.competition_fine_applied WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_fines_applied', v_deleted);
  END IF;

  DELETE FROM public.bank_ledger WHERE true;
  DELETE FROM public.competition_finance_ledger WHERE true;

  UPDATE public."Club_Finances"
  SET balance = 0
  WHERE true;

  -- Phase E2: owner personal wallets → opening ₿50k
  -- (full helper lives in admin_prelaunch_test_reset_owner_wallets_20260918.sql;
  --  inline fallback if that patch is already applied)
  IF to_regprocedure('public.admin_test_reset_reset_owner_wallets()') IS NOT NULL THEN
    v_result := v_result || public.admin_test_reset_reset_owner_wallets();
  END IF;

  UPDATE public.gpsl_bank_account
  SET reserves = 0,
      loan_book_outstanding = 0,
      updated_at = now()
  WHERE id = 1;

  -- Phase F: matchday / stadium / inbox
  DELETE FROM public.club_matchday_squad_player WHERE true;
  DELETE FROM public.club_matchday_squad WHERE true;

  DELETE FROM public.stadium_expansion_orders WHERE true;
  DELETE FROM public.stadium_expansion_quotes WHERE true;

  DELETE FROM public.competition_inbox WHERE true;

  -- Phase F1b: medical room (club state only; keep consultancy catalog / prize inventory)
  IF to_regclass('public.club_medical_token_use') IS NOT NULL THEN
    DELETE FROM public.club_medical_token_use WHERE true;
  END IF;
  IF to_regclass('public.club_medical_consults') IS NOT NULL THEN
    DELETE FROM public.club_medical_consults WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_medical_consults', v_deleted);
  END IF;
  IF to_regclass('public.club_medical_staff') IS NOT NULL THEN
    DELETE FROM public.club_medical_staff WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_medical_staff', v_deleted);
  END IF;
  IF to_regclass('public.club_medical_centre') IS NOT NULL THEN
    DELETE FROM public.club_medical_centre WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_medical_centres', v_deleted);
  END IF;

  -- Phase F1c: season FK blockers (no ON DELETE CASCADE) - clear before wiping seasons
  -- Reports point at friendlies (matched_fk); friendlies point at reports — clear match link first.
  IF to_regclass('public.gpsl_friendly_reports') IS NOT NULL THEN
    UPDATE public.gpsl_friendly_reports
    SET matched_friendly_id = NULL
    WHERE matched_friendly_id IS NOT NULL;
  END IF;
  IF to_regclass('public.gpsl_friendlies') IS NOT NULL THEN
    DELETE FROM public.gpsl_friendlies WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_friendlies', v_deleted);
  END IF;
  IF to_regclass('public.gpsl_friendly_reports') IS NOT NULL THEN
    DELETE FROM public.gpsl_friendly_reports WHERE true;
  END IF;
  IF to_regclass('public.gpsl_transfer_rumours') IS NOT NULL THEN
    DELETE FROM public.gpsl_transfer_rumours WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_transfer_rumours', v_deleted);
  END IF;
  IF to_regclass('public.club_one_of_our_own_draws') IS NOT NULL THEN
    DELETE FROM public.club_one_of_our_own_draws WHERE true;
  END IF;

  -- Phase F2: vanilla history / media / manager career (always)
  IF to_regclass('public.manager_club_sack_blocks') IS NOT NULL THEN
    DELETE FROM public.manager_club_sack_blocks WHERE true;
  END IF;
  IF to_regclass('public.manager_club_stints') IS NOT NULL THEN
    DELETE FROM public.manager_club_stints WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_manager_club_stints', v_deleted);
  END IF;

  IF to_regclass('public.natter_reactions') IS NOT NULL THEN
    DELETE FROM public.natter_reactions WHERE true;
  END IF;
  IF to_regclass('public.natter_reads') IS NOT NULL THEN
    DELETE FROM public.natter_reads WHERE true;
  END IF;
  IF to_regclass('public.natter_posts') IS NOT NULL THEN
    DELETE FROM public.natter_posts WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_natter_posts', v_deleted);
  END IF;

  IF to_regclass('public.gpsl_sport_reads') IS NOT NULL THEN
    DELETE FROM public.gpsl_sport_reads WHERE true;
  END IF;
  IF to_regclass('public.gpsl_sport_owner_comments') IS NOT NULL THEN
    DELETE FROM public.gpsl_sport_owner_comments WHERE true;
  END IF;
  IF to_regclass('public.gpsl_sport_editions') IS NOT NULL THEN
    DELETE FROM public.gpsl_sport_editions WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_gpsl_sport_editions', v_deleted);
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Clubs' AND column_name = 'sport_comment_draft'
  ) THEN
    UPDATE public."Clubs" SET sport_comment_draft = NULL WHERE sport_comment_draft IS NOT NULL;
  END IF;

  -- Note: admin_workflow_checklist is intentionally NOT deleted (admin data kept).

  IF to_regclass('public.competition_period_team_member') IS NOT NULL THEN
    DELETE FROM public.competition_period_team_member WHERE true;
  END IF;
  IF to_regclass('public.competition_period_team') IS NOT NULL THEN
    DELETE FROM public.competition_period_team WHERE true;
  END IF;

  IF to_regclass('public.competition_club_finance_season_archive') IS NOT NULL THEN
    DELETE FROM public.competition_club_finance_season_archive WHERE true;
  END IF;
  IF to_regclass('public.competition_club_prestige_snapshot') IS NOT NULL THEN
    DELETE FROM public.competition_club_prestige_snapshot WHERE true;
  END IF;
  IF to_regclass('public.competition_club_season_ranking') IS NOT NULL THEN
    DELETE FROM public.competition_club_season_ranking WHERE true;
  END IF;

  -- League / cup / owner points history (mandatory for vanilla)
  IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
    DELETE FROM public.competition_match_player_stats WHERE true;
  END IF;
  IF to_regclass('public.competition_player_season_archive') IS NOT NULL THEN
    DELETE FROM public.competition_player_season_archive WHERE true;
  END IF;
  IF to_regclass('public.competition_club_season_archive') IS NOT NULL THEN
    DELETE FROM public.competition_club_season_archive WHERE true;
  END IF;
  IF to_regclass('public.competition_cup_season_winner') IS NOT NULL THEN
    DELETE FROM public.competition_cup_season_winner WHERE true;
  END IF;
  IF to_regclass('public.competition_season_award') IS NOT NULL THEN
    DELETE FROM public.competition_season_award WHERE true;
  END IF;
  IF to_regclass('public.competition_owner_season_ranking') IS NOT NULL THEN
    DELETE FROM public.competition_owner_season_ranking WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_owner_season_ranking', v_deleted);
  END IF;

  -- Phase F3: international competition → vanilla (keep nation catalog)
  IF to_regclass('public.international_matchday_squad_player') IS NOT NULL THEN
    DELETE FROM public.international_matchday_squad_player WHERE true;
  END IF;
  IF to_regclass('public.international_matchday_squad') IS NOT NULL THEN
    DELETE FROM public.international_matchday_squad WHERE true;
  END IF;
  IF to_regclass('public.international_result_submissions') IS NOT NULL THEN
    DELETE FROM public.international_result_submissions WHERE true;
  END IF;
  IF to_regclass('public.international_fixture_schedule_proposal') IS NOT NULL THEN
    DELETE FROM public.international_fixture_schedule_proposal WHERE true;
  END IF;
  IF to_regclass('public.international_fixture_schedule') IS NOT NULL THEN
    DELETE FROM public.international_fixture_schedule WHERE true;
  END IF;
  IF to_regclass('public.international_fixtures') IS NOT NULL THEN
    DELETE FROM public.international_fixtures WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_international_fixtures', v_deleted);
  END IF;
  IF to_regclass('public.international_squad_callups') IS NOT NULL THEN
    DELETE FROM public.international_squad_callups WHERE true;
  END IF;
  IF to_regclass('public.international_player_career') IS NOT NULL THEN
    DELETE FROM public.international_player_career WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_international_player_career', v_deleted);
  END IF;
  IF to_regclass('public.international_owner_nations') IS NOT NULL THEN
    DELETE FROM public.international_owner_nations WHERE true;
  END IF;
  IF to_regclass('public.international_owner_rank') IS NOT NULL THEN
    UPDATE public.international_owner_rank
    SET rank_points = 0, updated_at = now()
    WHERE true;
  END IF;
  IF to_regclass('public.international_selection_windows') IS NOT NULL THEN
    DELETE FROM public.international_selection_windows WHERE true;
  END IF;
  IF to_regclass('public.international_nation_player_pool_cache') IS NOT NULL THEN
    DELETE FROM public.international_nation_player_pool_cache WHERE true;
  END IF;
  IF to_regclass('public.international_nation_player_pool_meta') IS NOT NULL THEN
    DELETE FROM public.international_nation_player_pool_meta WHERE true;
  END IF;
  IF to_regclass('public.international_wc_cycles') IS NOT NULL THEN
    -- Cascades qual/finals groups + knockout nodes
    DELETE FROM public.international_wc_cycles WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_result := v_result || jsonb_build_object('deleted_international_wc_cycles', v_deleted);
  END IF;

  -- Detach season FKs without ON DELETE CASCADE (e.g. Clubs.stadium_fill_season_id)
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'stadium_fill_season_id'
  ) THEN
    UPDATE public."Clubs"
    SET stadium_fill_season_id = NULL
    WHERE stadium_fill_season_id IS NOT NULL;
  END IF;

  -- Extra season/fixture dependents that can block or trip FK updates on wipe
  IF to_regclass('public.competition_result_submissions') IS NOT NULL THEN
    DELETE FROM public.competition_result_submissions WHERE true;
  END IF;
  IF to_regclass('public.competition_league_points_adjustments') IS NOT NULL THEN
    DELETE FROM public.competition_league_points_adjustments WHERE true;
  END IF;
  IF to_regclass('public.competition_suspension_appeals') IS NOT NULL THEN
    DELETE FROM public.competition_suspension_appeals WHERE true;
  END IF;
  IF to_regclass('public.competition_player_suspension_matches') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspension_matches WHERE true;
  END IF;
  IF to_regclass('public.competition_player_suspensions') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspensions WHERE true;
  END IF;
  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    DELETE FROM public.competition_player_injury_fixtures WHERE true;
  END IF;
  IF to_regclass('public.competition_player_injuries') IS NOT NULL THEN
    DELETE FROM public.competition_player_injuries WHERE true;
  END IF;
  IF to_regclass('public.competition_fixture_injury_roll') IS NOT NULL THEN
    DELETE FROM public.competition_fixture_injury_roll WHERE true;
  END IF;
  IF to_regclass('public.competition_club_injury_season') IS NOT NULL THEN
    DELETE FROM public.competition_club_injury_season WHERE true;
  END IF;
  IF to_regclass('public.competition_injury_preseason_tick') IS NOT NULL THEN
    DELETE FROM public.competition_injury_preseason_tick WHERE true;
  END IF;
  IF to_regclass('public.competition_contract_tick_log') IS NOT NULL THEN
    DELETE FROM public.competition_contract_tick_log WHERE true;
  END IF;
  IF to_regclass('public.admin_expiry_bid_audit_snapshot') IS NOT NULL THEN
    DELETE FROM public.admin_expiry_bid_audit_snapshot WHERE true;
  END IF;

  DELETE FROM public.competition_seasons WHERE true;
  v_result := v_result || jsonb_build_object('vanilla_history_cleared', true);

  -- Phase G: per-club counters (WHERE required by Supabase safe-update)
  -- Also clear Club Management soft-archive so archived clubs return for next test cycle.
  UPDATE public."Clubs"
  SET foreign_interest_remaining = CASE WHEN "ShortName" = 'FOREIGN' THEN 0 ELSE 3 END,
      foreign_tracking_teams = '{}'::text[],
      voluntary_contract_releases_remaining = 3,
      manager_sacks_remaining = 1,
      -- New Owner first-season slots (also cleared by vacate trigger + season FK ON DELETE SET NULL)
      owner_assigned_season_id = NULL,
      new_owner_releases_remaining = 0,
      is_archived = false,
      archived_at = NULL,
      archived_note = NULL,
      gp_saved = NULL
  WHERE "ShortName" IS NOT NULL;

  IF to_regprocedure('public.manager_reset_season_quotas()') IS NOT NULL THEN
    PERFORM public.manager_reset_season_quotas();
  END IF;

  IF to_regprocedure('public.club_reset_voluntary_contract_releases()') IS NOT NULL THEN
    PERFORM public.club_reset_voluntary_contract_releases();
  END IF;

  -- Phase H: vacated / active owners → waiting list with activity-based priority.
  -- Engaged ex-owners keep top spots (ready for invite); inactive join normal queue.
  -- Confirm ticks / existing waiters kept. Requires admin_test_reset_ex_owner_waiting_priority_20260921.sql.
  IF v_reset_owners THEN
    v_result := v_result || jsonb_build_object(
      'ex_owner_waiting_priority',
      public.admin_test_reset_apply_ex_owner_waiting_priority(v_starting)
    );
  END IF;

  IF v_seed_club THEN
    v_result := v_result || public.admin_club_auction_seed_listings();
  END IF;

  v_result := v_result || jsonb_build_object(
    'counts_after', public.admin_test_reset_counts(),
    'starting_balance_set', v_starting,
    'reset_owners_to_auction', v_reset_owners,
    'ex_owner_waiting_priority_applied', v_reset_owners,
    'clear_competition_history', v_clear_history,
    'seed_club_auction', v_seed_club
  );

  UPDATE public.test_reset_audit_log
  SET completed_at = now(),
      result = v_result,
      ok = true
  WHERE id = v_audit_id;

  RETURN jsonb_build_object(
    'ok', true,
    'audit_id', v_audit_id,
    'preview_before', v_preview,
    'result', v_result
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE public.test_reset_audit_log
  SET completed_at = now(),
      result = jsonb_build_object('error', SQLERRM),
      ok = false
  WHERE id = v_audit_id;
  RAISE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_test_reset_execute(text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
