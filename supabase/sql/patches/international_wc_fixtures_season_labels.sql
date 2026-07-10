-- =============================================================================
-- Fixtures public view: include season label/ordinal for WC window tabs + calendar
-- Safe re-run.
-- =============================================================================

DROP VIEW IF EXISTS public.international_fixtures_public;
CREATE VIEW public.international_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.cycle_id,
  wc.cycle_no,
  wc.label AS cycle_label,
  f.season_id,
  cs.label AS season_label,
  public.competition_season_ordinal(f.season_id) AS season_ordinal,
  f.phase,
  f.group_id,
  COALESCE(qg.group_code, fg.group_code) AS group_code,
  f.knockout_node_id,
  kn.stage AS knockout_stage,
  kn.match_no AS knockout_match_no,
  f.home_nation,
  hn.name AS home_nation_name,
  hn.flag_emoji AS home_flag,
  f.away_nation,
  an.name AS away_nation_name,
  an.flag_emoji AS away_flag,
  f.home_goals,
  f.away_goals,
  f.match_no,
  f.gpsl_month,
  f.week_in_month,
  f.status,
  f.played,
  f.played_at,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  f.created_at
FROM public.international_fixtures f
JOIN public.international_wc_cycles wc ON wc.id = f.cycle_id
JOIN public.international_nations hn ON hn.code = f.home_nation
JOIN public.international_nations an ON an.code = f.away_nation
LEFT JOIN public.competition_seasons cs ON cs.id = f.season_id
LEFT JOIN public.international_qual_groups qg
  ON qg.id = f.group_id AND f.phase = 'qualifying'
LEFT JOIN public.international_finals_groups fg
  ON fg.id = f.group_id AND f.phase = 'finals_group'
LEFT JOIN public.international_knockout_nodes kn ON kn.id = f.knockout_node_id
LEFT JOIN public.international_fixture_schedule sch ON sch.fixture_id = f.id;

GRANT SELECT ON public.international_fixtures_public TO authenticated;

NOTIFY pgrst, 'reload schema';
