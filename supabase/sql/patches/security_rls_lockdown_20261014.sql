-- =============================================================================
-- Supabase linter "RLS Disabled in Public" — enable RLS with READ-ONLY API
-- access by default. Replaces the allow-everything policy from
-- security_enable_rls_all_public_20261006.sql (safe whether or not that ran).
--
-- Per table:
--   • Not used by the site / Edge Functions / non-definer code → locked to the
--     API (definer functions, postgres and service_role still bypass RLS).
--   • Used by the site → anon + authenticated can SELECT (reads unchanged).
--   • Writes through the API are only kept where something actually writes:
--       - Player_Transfer_Listings: logged-in owners may INSERT for their own
--         club (admins any club).
--       - Tables the website writes directly → open writes (as today).
--       - Tables written by non-SECURITY-DEFINER functions/triggers → open
--         writes (as today) and listed in the preview so they can be moved to
--         definer functions later.
--   • Every change is logged in public.gpsl_rls_hardening_log; undo with
--     security_enable_rls_rollback_20261006.sql.
--
-- STEP 1 is read-only (preview). Run it, check, then run STEP 2.
-- =============================================================================

-- Tables/views the website queries directly with the anon/user key. Edge
-- Functions are not listed: they all use service_role, which bypasses RLS.
CREATE OR REPLACE FUNCTION public.gpsl_rls_site_tables()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'admin_security_hardening_checklist','admin_workflow_checklist','auction_exclusion_players',
    'bank_ledger_public','bookies_markets_public','bookies_my_bets_public','bookies_selections_public',
    'Club_Auction_Bids','Club_Auction_Listings','club_auction_listings_public','club_auction_purchases_public',
    'club_commercial_settings','club_dashboard_theme','club_emergency_loans','Club_Finances','club_kits',
    'club_loan_installments_public','club_loans_league_public','club_loans_public',
    'club_matchday_pitch_layout_public','club_matchday_saved_formation_public','club_matchday_squad_public',
    'club_owner_holidays_public','club_prestige_cup_targets','club_season_loans','Clubs','clubs_database_public',
    'competition_calendar_status_public','competition_challenge_awards_public','competition_challenge_config',
    'competition_challenge_period_bonus_awarded','competition_challenge_period_pack',
    'competition_challenge_period_packs_public','competition_challenge_templates','competition_challenges_public',
    'competition_club_finance_season_archive_public','competition_club_season_archive_public',
    'competition_club_season_public','competition_club_seasons','competition_club_stadium_overview_public',
    'competition_cup_bracket_nodes','competition_cup_bracket_public','competition_cup_manual_qualifiers',
    'competition_cup_prize_config_public','competition_cup_qualified_public','competition_finance_ledger',
    'competition_finance_ledger_public','competition_fine_applied','competition_fine_tariff',
    'competition_fixture_schedule_proposal','competition_fixtures','competition_fixtures_public',
    'competition_gov_subsidy_paid','competition_inbox','competition_league_prize_config_public',
    'competition_manager_month_awards_public','competition_owner_ranking_alltime_public',
    'competition_owner_ranking_rolling4_public','competition_owner_season_ranking_public',
    'competition_period_team','competition_period_team_public','competition_player_cup_stats_public',
    'competition_player_injuries','competition_player_season_stats_public','competition_result_submissions',
    'competition_season_calendar','competition_season_calendar_public','competition_season_movements',
    'competition_season_public','competition_seasons','competition_standings_prizes_public',
    'competition_standings_public','competition_tv_fixtures_public','draft_auction_favourites',
    'fixture_match_videos','global_settings','global_settings_public','gpsl_bank_account','gpsl_bank_public',
    'gpsl_discord_feed_queue','gpsl_owner_profile_public','gpsl_owner_registry','gpsl_planned_events',
    'gpsl_sport_editions','international_available_nation_managers_public','international_finals_standings_public',
    'international_fixtures_public','international_knockout_public','international_matchday_squad',
    'international_matchday_squad_player','international_my_nation_public','international_nations',
    'international_nations_public','international_owner_nations','international_owner_rank_public',
    'international_player_career_public','international_qual_standings_public','international_result_submissions',
    'international_selection_public','international_squad_public','international_wc_cycle_public',
    'international_wc_cycles','manager_club_status_public','manager_proficiency_expectancy',
    'manager_rating_targets','Manager_Transfer_Bids','Manager_Transfer_Listings','Managers',
    'managers_gpdb_public','owner_scouting_planner','owner_scouting_planner_player','owner_scouting_targets',
    'Player_Transfer_Bids','Player_Transfer_Listings','Players','special_auction_bids','special_auctions',
    'stadium_expansion_quotes_public','stadium_expansion_status_public','Transfer_History',
    'video_tutorial_folders','video_tutorial_links','owner_dashboard_layout','gpdb_players_view'
  ]::text[];
$$;

CREATE OR REPLACE FUNCTION public.gpsl_rls_client_written_tables()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'Player_Transfer_Bids','Manager_Transfer_Bids','video_tutorial_folders',
    'video_tutorial_links','club_commercial_settings','owner_dashboard_layout'
  ]::text[];
$$;

CREATE OR REPLACE FUNCTION public.gpsl_rls_lockdown_plan()
RETURNS TABLE (
  table_name text,
  api_read boolean,
  api_write text,
  reason text,
  invoker_writers text
)
LANGUAGE sql
STABLE
AS $$
  WITH t AS (
    SELECT c.relname::text AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND (
        NOT c.relrowsecurity
        OR EXISTS (
          SELECT 1 FROM pg_policies p
          WHERE p.schemaname = 'public'
            AND p.tablename = c.relname
            AND p.policyname = 'gpsl_keep_current_access'
        )
      )
      AND c.relname <> 'gpsl_rls_hardening_log'
  ),
  -- Only invoker code the API roles can reach: triggers (fire for any writer)
  -- or functions anon/authenticated can EXECUTE.
  invoker_fns AS (
    SELECT p.proname::text AS proname, p.prosrc AS src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT p.prosecdef
      AND p.prokind IN ('f', 'p')
      AND (
        p.prorettype = 'trigger'::regtype
        OR has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      )
  ),
  invoker_views AS (
    SELECT string_agg(pg_get_viewdef(c.oid), E'\n') AS src
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'v'
      AND coalesce(c.reloptions::text, '') ILIKE '%security_invoker=true%'
  ),
  x AS (
    SELECT
      t.table_name,
      t.table_name = ANY (public.gpsl_rls_site_tables()) AS client_used,
      t.table_name = ANY (public.gpsl_rls_client_written_tables()) AS client_written,
      EXISTS (
        SELECT 1 FROM invoker_fns f
        WHERE f.src ~* ('\m' || t.table_name || '\M')
      ) AS invoker_reads,
      coalesce(v.src, '') ~* ('\m' || t.table_name || '\M') AS view_reads,
      (
        SELECT string_agg(DISTINCT f.proname, ', ' ORDER BY f.proname)
        FROM invoker_fns f
        WHERE f.src ~* (
          '(insert\s+into|update|delete\s+from)\s+(only\s+)?(public\s*\.\s*)?"?'
          || t.table_name || '"?\M'
        )
      ) AS writers
    FROM t
    CROSS JOIN invoker_views v
  )
  SELECT
    x.table_name,
    (x.client_used OR x.invoker_reads OR x.view_reads) AS api_read,
    CASE
      WHEN x.writers IS NOT NULL OR x.client_written THEN 'open'
      WHEN x.table_name = 'Player_Transfer_Listings' THEN 'owner_insert'
      ELSE 'none'
    END AS api_write,
    CASE
      WHEN x.writers IS NOT NULL THEN 'written by non-definer function/trigger'
      WHEN x.client_written THEN 'written directly by website'
      WHEN x.table_name = 'Player_Transfer_Listings' THEN 'website creates listings (own club only)'
      WHEN x.client_used THEN 'read by website / Edge Function'
      WHEN x.invoker_reads THEN 'read by non-definer function'
      WHEN x.view_reads THEN 'read by security_invoker view'
      ELSE 'locked to API (definer functions / service role only)'
    END AS reason,
    x.writers AS invoker_writers
  FROM x
  ORDER BY 3, 2 DESC, 1;
$$;

REVOKE EXECUTE ON FUNCTION public.gpsl_rls_site_tables() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.gpsl_rls_client_written_tables() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.gpsl_rls_lockdown_plan() FROM PUBLIC, anon, authenticated;

-- STEP 1 (preview — read only)
SELECT * FROM public.gpsl_rls_lockdown_plan();


-- STEP 2 (apply) — run everything below once you're happy with the preview

-- Legacy invoker functions that kept Club_Finances / Player_Transfer_Listings /
-- international_nation_catalog / seasons / player_season_stats writable.
DO $$
DECLARE
  f record;
  v_result text;
BEGIN
  -- Not called by the website: SQL editor / service role only.
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('transfer_funds', 'extend_club_auction', 'international_catalog_add_aliases')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
  END LOOP;

  -- Admin season page: keep working, but admin-only and run as owner.
  IF to_regprocedure('public.rollover_season()') IS NOT NULL
     AND to_regprocedure('public.rollover_season_base()') IS NULL THEN
    SELECT pg_get_function_result(p.oid)
    INTO v_result
    FROM pg_proc p
    WHERE p.oid = 'public.rollover_season()'::regprocedure
      AND NOT p.proretset;

    IF v_result IS NULL THEN
      RAISE NOTICE 'rollover_season() returns a set — left unchanged; revoking public access instead.';
      REVOKE EXECUTE ON FUNCTION public.rollover_season() FROM PUBLIC, anon;
    ELSE
      ALTER FUNCTION public.rollover_season() RENAME TO rollover_season_base;
      REVOKE EXECUTE ON FUNCTION public.rollover_season_base() FROM PUBLIC, anon, authenticated;
      EXECUTE format(
        $f$
        CREATE FUNCTION public.rollover_season()
        RETURNS %s
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = public
        AS $body$
        BEGIN
          IF NOT public.is_gpsl_admin() THEN
            RAISE EXCEPTION 'Admin only';
          END IF;
          %s
        END;
        $body$
        $f$,
        v_result,
        CASE WHEN v_result = 'void'
          THEN 'PERFORM public.rollover_season_base();'
          ELSE 'RETURN public.rollover_season_base();'
        END
      );
      REVOKE EXECUTE ON FUNCTION public.rollover_season() FROM PUBLIC, anon;
      GRANT EXECUTE ON FUNCTION public.rollover_season() TO authenticated, service_role;
    END IF;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.gpsl_rls_hardening_log (
  table_name text PRIMARY KEY,
  kept_current_access boolean NOT NULL,
  reason text,
  applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.gpsl_rls_hardening_log ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  r record;
  v_locked int := 0;
  v_read int := 0;
  v_open int := 0;
BEGIN
  FOR r IN SELECT * FROM public.gpsl_rls_lockdown_plan() LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.table_name);
    EXECUTE format('DROP POLICY IF EXISTS gpsl_keep_current_access ON public.%I', r.table_name);
    EXECUTE format('DROP POLICY IF EXISTS gpsl_api_read ON public.%I', r.table_name);
    EXECUTE format('DROP POLICY IF EXISTS gpsl_api_insert ON public.%I', r.table_name);
    EXECUTE format('DROP POLICY IF EXISTS gpsl_api_update ON public.%I', r.table_name);
    EXECUTE format('DROP POLICY IF EXISTS gpsl_api_delete ON public.%I', r.table_name);

    IF r.api_read OR r.api_write <> 'none' THEN
      EXECUTE format(
        'CREATE POLICY gpsl_api_read ON public.%I FOR SELECT TO anon, authenticated USING (true)',
        r.table_name
      );
    END IF;

    IF r.api_write = 'open' THEN
      EXECUTE format(
        'CREATE POLICY gpsl_api_insert ON public.%I FOR INSERT TO anon, authenticated WITH CHECK (true)',
        r.table_name
      );
      EXECUTE format(
        'CREATE POLICY gpsl_api_update ON public.%I FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true)',
        r.table_name
      );
      EXECUTE format(
        'CREATE POLICY gpsl_api_delete ON public.%I FOR DELETE TO anon, authenticated USING (true)',
        r.table_name
      );
      v_open := v_open + 1;
    ELSIF r.api_write = 'owner_insert' THEN
      EXECUTE format(
        'CREATE POLICY gpsl_api_insert ON public.%I FOR INSERT TO authenticated WITH CHECK ('
        || 'public.is_gpsl_admin() OR EXISTS (SELECT 1 FROM public."Clubs" c '
        || 'WHERE c."ShortName" = seller_club_id AND c.owner_id = auth.uid()))',
        r.table_name
      );
      v_read := v_read + 1;
    ELSIF r.api_read THEN
      v_read := v_read + 1;
    ELSE
      v_locked := v_locked + 1;
    END IF;

    INSERT INTO public.gpsl_rls_hardening_log (table_name, kept_current_access, reason)
    VALUES (r.table_name, r.api_read OR r.api_write <> 'none', r.api_write || ': ' || r.reason)
    ON CONFLICT (table_name) DO UPDATE
      SET kept_current_access = excluded.kept_current_access,
          reason = excluded.reason,
          applied_at = now();
  END LOOP;
  RAISE NOTICE 'RLS: % read-only, % still writable, % locked to API.', v_read, v_open, v_locked;
END $$;

NOTIFY pgrst, 'reload schema';

-- Report
SELECT 'still without RLS' AS check_name, c.relname::text AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity
UNION ALL
SELECT 'summary', l.reason || ' — ' || count(*)::text || ' table(s)'
FROM public.gpsl_rls_hardening_log l
WHERE l.applied_at > now() - interval '10 minutes'
GROUP BY l.reason
UNION ALL
SELECT 'function access', p.proname || ': '
  || CASE WHEN p.prosecdef THEN 'definer' ELSE 'invoker' END
  || ', anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
  || ', authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('transfer_funds', 'extend_club_auction', 'international_catalog_add_aliases',
                    'rollover_season', 'rollover_season_base')
ORDER BY 1, 2;
