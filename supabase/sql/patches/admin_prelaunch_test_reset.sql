-- =============================================================================
-- Pre-launch / vanilla GPSL test environment reset
-- Preview → arm flag → typed confirm → full sandbox wipe back to day-zero GPSL.
-- Run once in Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
--
-- KEEP: Players GPDB, auth users, Clubs rows, Managers catalog, nation catalog,
--       global rule/config templates (tax tariffs, prize templates, etc.).
-- WIPE: owners on clubs, squads/contracts, finances/ledger, transfers, seasons,
--       league+cup fixtures/results/player stats, archives/awards/owner points,
--       GPSL Sport, Natter, inbox, manager career history, internationals
--       (fixtures/results/cycles/assignments/caps), club auction (optional re-seed).
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS allow_test_environment_reset boolean NOT NULL DEFAULT false;

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS club_auction_starting_balance numeric(14, 2) NOT NULL DEFAULT 600000000;

COMMENT ON COLUMN public.global_settings.allow_test_environment_reset IS
  'When true, admin_test_reset_execute() may run. Off by default — pre-launch only.';

COMMENT ON COLUMN public.global_settings.club_auction_starting_balance IS
  'Default pending budget for owners in club auction (awaiting_club / register). Updated by test reset.';

CREATE TABLE IF NOT EXISTS public.test_reset_audit_log (
  id bigserial PRIMARY KEY,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  admin_email text,
  confirm_phrase_used boolean NOT NULL DEFAULT false,
  options jsonb NOT NULL DEFAULT '{}'::jsonb,
  preview_before jsonb,
  result jsonb,
  ok boolean NOT NULL DEFAULT false
);

ALTER TABLE public.test_reset_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS test_reset_audit_log_admin ON public.test_reset_audit_log;
CREATE POLICY test_reset_audit_log_admin ON public.test_reset_audit_log
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.test_reset_audit_log TO authenticated;

CREATE OR REPLACE FUNCTION public.club_auction_default_starting_balance()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT g.club_auction_starting_balance FROM public.global_settings g WHERE g.id = 1),
    600000000::numeric
  );
$$;

CREATE OR REPLACE FUNCTION public.club_auction_get_config()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'starting_balance', public.club_auction_default_starting_balance()
  );
$$;

-- ---------------------------------------------------------------------------
-- Count helpers (preview + audit)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_test_reset_table_count(p_rel text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n int := 0;
BEGIN
  IF to_regclass(p_rel) IS NULL THEN
    RETURN 0;
  END IF;
  EXECUTE format('SELECT count(*)::int FROM %s', p_rel) INTO v_n;
  RETURN coalesce(v_n, 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_test_reset_counts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finance_nonzero int;
BEGIN
  SELECT count(*)::int
  INTO v_finance_nonzero
  FROM public."Club_Finances" f
  WHERE coalesce(f.balance, 0) <> 0;

  RETURN jsonb_build_object(
    'clubs_with_owner', (
      SELECT count(*)::int FROM public."Clubs" c WHERE c.owner_id IS NOT NULL
    ),
    'contracted_players', (
      SELECT count(*)::int FROM public."Players" p
      WHERE p."Contracted_Team" IS NOT NULL AND btrim(p."Contracted_Team") <> ''
    ),
    'contracted_managers', (
      SELECT count(*)::int FROM public."Managers" m
      WHERE m.contracted_club IS NOT NULL AND btrim(m.contracted_club) <> ''
    ),
    'club_finances_nonzero', v_finance_nonzero,
    'finance_ledger_rows', (SELECT count(*)::int FROM public.competition_finance_ledger),
    'bank_ledger_rows', (SELECT count(*)::int FROM public.bank_ledger),
    'player_transfer_bids', (SELECT count(*)::int FROM public."Player_Transfer_Bids"),
    'player_transfer_listings', (SELECT count(*)::int FROM public."Player_Transfer_Listings"),
    'manager_transfer_bids', (SELECT count(*)::int FROM public."Manager_Transfer_Bids"),
    'manager_transfer_listings', (SELECT count(*)::int FROM public."Manager_Transfer_Listings"),
    'transfer_history_rows', (SELECT count(*)::int FROM public."Transfer_History"),
    'club_auction_active', (
      SELECT count(*)::int FROM public."Club_Auction_Listings" WHERE status = 'Active'
    ),
    'club_auction_bids', (SELECT count(*)::int FROM public."Club_Auction_Bids"),
    'special_auctions', (SELECT count(*)::int FROM public.special_auctions),
    'club_loans', (SELECT count(*)::int FROM public.club_loans),
    'competition_seasons', (SELECT count(*)::int FROM public.competition_seasons),
    'competition_fixtures', (SELECT count(*)::int FROM public.competition_fixtures),
    'competition_match_player_stats', public.admin_test_reset_table_count('public.competition_match_player_stats'),
    'competition_inbox', (SELECT count(*)::int FROM public.competition_inbox),
    'owner_season_ranking_rows', public.admin_test_reset_table_count('public.competition_owner_season_ranking'),
    'player_season_archive_rows', public.admin_test_reset_table_count('public.competition_player_season_archive'),
    'club_season_archive_rows', public.admin_test_reset_table_count('public.competition_club_season_archive'),
    'manager_club_stints', public.admin_test_reset_table_count('public.manager_club_stints'),
    'gpsl_sport_editions', public.admin_test_reset_table_count('public.gpsl_sport_editions'),
    'natter_posts', public.admin_test_reset_table_count('public.natter_posts'),
    'international_fixtures', public.admin_test_reset_table_count('public.international_fixtures'),
    'international_wc_cycles', public.admin_test_reset_table_count('public.international_wc_cycles'),
    'international_player_career', public.admin_test_reset_table_count('public.international_player_career'),
    'international_nations_active', (
      SELECT CASE
        WHEN to_regclass('public.international_owner_nations') IS NULL THEN 0
        ELSE (
          SELECT count(*)::int FROM public.international_owner_nations WHERE is_active = true
        )
      END
    ),
    'owners_registry_active', (
      SELECT count(*)::int FROM public.gpsl_owner_registry WHERE status = 'active'
    ),
    'owners_registry_awaiting_auction', (
      SELECT count(*)::int FROM public.gpsl_owner_registry WHERE status = 'awaiting_club_auction'
    ),
    'players_foreign_contract', (
      SELECT count(*)::int FROM public."Players" p
      WHERE p.foreign_contract_club IS NOT NULL AND btrim(p.foreign_contract_club) <> ''
    )
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Arm / disarm + config
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_test_reset_set_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.global_settings
  SET allow_test_environment_reset = coalesce(p_enabled, false),
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'allow_test_environment_reset', coalesce(p_enabled, false)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_test_reset_get_config()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(g.allow_test_environment_reset, false)
  INTO v_enabled
  FROM public.global_settings g
  WHERE g.id = 1;

  RETURN jsonb_build_object(
    'allow_test_environment_reset', v_enabled,
    'confirm_phrase', 'RESET TEST ENVIRONMENT',
    'default_starting_balance', public.club_auction_default_starting_balance()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_test_reset_preview()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'preview_at', now(),
    'counts', public.admin_test_reset_counts(),
    'allow_test_environment_reset', (
      SELECT coalesce(g.allow_test_environment_reset, false)
      FROM public.global_settings g WHERE g.id = 1
    )
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Execute (destructive)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_test_reset_execute(
  p_confirm_phrase text,
  p_options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
  v_audit_id bigint;
  v_preview jsonb;
  v_club text;
  v_mgr record;
  v_starting numeric;
  v_reset_owners boolean;
  v_clear_history boolean;
  v_seed_club boolean;
  v_deleted int;
  v_result jsonb := '{}'::jsonb;
BEGIN
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

  v_starting := greatest(coalesce((p_options ->> 'starting_balance')::numeric, 600000000), 0);
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

  -- Phase B: detach all owners
  FOR v_club IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
    ORDER BY c."ShortName"
  LOOP
    PERFORM public.admin_club_vacate(v_club);
  END LOOP;

  PERFORM public.international_admin_clear_nation_assignments();

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

  FOR v_mgr IN
    SELECT m.id
    FROM public."Managers" m
    WHERE m.contracted_club IS NOT NULL AND btrim(m.contracted_club) <> ''
  LOOP
    BEGIN
      PERFORM public.manager_release_from_club(v_mgr.id, NULL, NULL, 'transfer_sale');
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Managers"
      SET contracted_club = NULL,
          contract_seasons_remaining = NULL,
          weekly_wage = NULL,
          signed_season_id = NULL,
          updated_at = now()
      WHERE id = v_mgr.id;
    END;
  END LOOP;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL
  WHERE manager_id IS NOT NULL;

  -- Phase E: finances & loans
  DELETE FROM public.club_loan_installments
  WHERE loan_id IN (SELECT id FROM public.club_loans);
  DELETE FROM public.club_loans WHERE true;

  DELETE FROM public.bank_ledger WHERE true;
  DELETE FROM public.competition_finance_ledger WHERE true;

  UPDATE public."Club_Finances"
  SET balance = 0
  WHERE true;

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

  IF to_regclass('public.admin_workflow_checklist') IS NOT NULL THEN
    DELETE FROM public.admin_workflow_checklist WHERE true;
  END IF;

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

  DELETE FROM public.competition_seasons WHERE true;
  v_result := v_result || jsonb_build_object('vanilla_history_cleared', true);

  -- Phase G: per-club counters (WHERE required by Supabase safe-update)
  UPDATE public."Clubs"
  SET foreign_interest_remaining = CASE WHEN "ShortName" = 'FOREIGN' THEN 0 ELSE 3 END,
      foreign_tracking_teams = '{}'::text[],
      voluntary_contract_releases_remaining = 3,
      manager_sacks_remaining = 1
  WHERE "ShortName" IS NOT NULL;

  IF to_regprocedure('public.manager_reset_season_quotas()') IS NOT NULL THEN
    PERFORM public.manager_reset_season_quotas();
  END IF;

  IF to_regprocedure('public.club_reset_voluntary_contract_releases()') IS NOT NULL THEN
    PERFORM public.club_reset_voluntary_contract_releases();
  END IF;

  -- Phase H: owner registry → awaiting club auction
  IF v_reset_owners THEN
    UPDATE public.gpsl_owner_registry r
    SET status = 'awaiting_club_auction',
        pending_starting_balance = v_starting,
        last_club_short_name = NULL,
        last_nation_code = NULL,
        status_changed_at = now()
    WHERE r.status IS DISTINCT FROM 'archived';
  END IF;

  IF v_seed_club THEN
    v_result := v_result || public.admin_club_auction_seed_listings();
  END IF;

  v_result := v_result || jsonb_build_object(
    'counts_after', public.admin_test_reset_counts(),
    'starting_balance_set', v_starting,
    'reset_owners_to_auction', v_reset_owners,
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

GRANT EXECUTE ON FUNCTION public.admin_test_reset_set_enabled(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_test_reset_get_config() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_test_reset_preview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_test_reset_execute(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_test_reset_counts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_test_reset_table_count(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_default_starting_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_get_config() TO authenticated;

NOTIFY pgrst, 'reload schema';
