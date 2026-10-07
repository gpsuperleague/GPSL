-- =============================================================================
-- Supabase "RLS Disabled in Public" (critical) — enable RLS on every public
-- table that doesn't have it, WITHOUT breaking the site.
--
-- How it stays safe:
--   • SECURITY DEFINER functions, the table owner (postgres) and service_role
--     (Edge Functions, cron) bypass RLS — they keep working unchanged.
--   • Tables the website / Edge Functions query directly, or that are touched by
--     non-SECURITY-DEFINER functions/triggers, get a policy that keeps today's
--     access exactly ("gpsl_keep_current_access"). Table GRANTs still apply.
--   • Every other table is locked to the API (anon / authenticated) — they were
--     only reachable through definer functions anyway.
--   • Every change is logged in public.gpsl_rls_hardening_log so it can be
--     undone with security_enable_rls_rollback_20261006.sql.
--
-- STEP 1 is read-only (preview). Run it, check, then run STEP 2.
-- =============================================================================

-- Tables/views the frontend + Edge Functions query directly (from the code).
CREATE OR REPLACE FUNCTION public.gpsl_rls_client_tables()
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
    'video_tutorial_folders','video_tutorial_links','owner_dashboard_layout','gpdb_players_view',
    -- Edge Functions
    'discord_join_tickets','gpsl_discord_club_directory_state','gpsl_discord_friendlies_settings',
    'gpsl_discord_match_videos_settings','gpsl_discord_whos_who_state','gpsl_email_outbox',
    'gpsl_visitors','owner_login_origin_events'
  ]::text[];
$$;

-- Plan: one row per public table without RLS
CREATE OR REPLACE FUNCTION public.gpsl_rls_hardening_plan()
RETURNS TABLE (table_name text, keep_current_access boolean, reason text)
LANGUAGE sql
STABLE
AS $$
  WITH t AS (
    SELECT c.relname::text AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relrowsecurity
  ),
  invoker_src AS (
    SELECT string_agg(p.prosrc, E'\n') AS src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT p.prosecdef
      AND p.prokind IN ('f', 'p')
  ),
  invoker_views AS (
    SELECT string_agg(pg_get_viewdef(c.oid), E'\n') AS src
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'v'
      AND coalesce(c.reloptions::text, '') ILIKE '%security_invoker=true%'
  )
  SELECT
    t.table_name,
    (t.table_name = ANY (public.gpsl_rls_client_tables())
      OR coalesce(i.src, '') ~* ('\m' || t.table_name || '\M')
      OR coalesce(v.src, '') ~* ('\m' || t.table_name || '\M')) AS keep_current_access,
    CASE
      WHEN t.table_name = ANY (public.gpsl_rls_client_tables()) THEN 'used directly by website / Edge Function'
      WHEN coalesce(i.src, '') ~* ('\m' || t.table_name || '\M') THEN 'used by a non-definer function or trigger'
      WHEN coalesce(v.src, '') ~* ('\m' || t.table_name || '\M') THEN 'used by a security_invoker view'
      ELSE 'locked to API (definer functions / service role only)'
    END AS reason
  FROM t
  CROSS JOIN invoker_src i
  CROSS JOIN invoker_views v
  ORDER BY 2 DESC, 1;
$$;

REVOKE EXECUTE ON FUNCTION public.gpsl_rls_client_tables() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.gpsl_rls_hardening_plan() FROM PUBLIC, anon, authenticated;

-- STEP 1 (preview — read only)
SELECT * FROM public.gpsl_rls_hardening_plan();


-- STEP 2 (apply) — run everything below once you're happy with the preview
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
  v_kept int := 0;
BEGIN
  FOR r IN SELECT * FROM public.gpsl_rls_hardening_plan() LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.table_name);
    IF r.keep_current_access THEN
      EXECUTE format('DROP POLICY IF EXISTS gpsl_keep_current_access ON public.%I', r.table_name);
      EXECUTE format(
        'CREATE POLICY gpsl_keep_current_access ON public.%I FOR ALL TO anon, authenticated USING (true) WITH CHECK (true)',
        r.table_name
      );
      v_kept := v_kept + 1;
    ELSE
      v_locked := v_locked + 1;
    END IF;
    INSERT INTO public.gpsl_rls_hardening_log (table_name, kept_current_access, reason)
    VALUES (r.table_name, r.keep_current_access, r.reason)
    ON CONFLICT (table_name) DO UPDATE
      SET kept_current_access = excluded.kept_current_access,
          reason = excluded.reason,
          applied_at = now();
  END LOOP;
  RAISE NOTICE 'RLS enabled: % table(s) kept current access, % table(s) locked to API.', v_kept, v_locked;
END $$;

-- Should return no rows now
SELECT c.relname AS still_without_rls
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity;
