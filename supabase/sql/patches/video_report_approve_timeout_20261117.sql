-- Approving a video report runs as the website role, which stops any statement
-- after 8 seconds. A draw on this tariff also replays the match, and the fine
-- waits if the club balance is already locked. Either one was cancelled at 8s,
-- so the fine never landed.
-- Give this approval the same 3 minute window as the other admin money actions.

ALTER FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric, boolean)
  SET statement_timeout = '180s';

ALTER FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric, boolean)
  SET lock_timeout = '180s';

SELECT jsonb_build_object(
  'proconfig', (
    SELECT p.proconfig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'admin_match_video_resolve_breach_report'
  ),
  'fixture', (
    SELECT jsonb_build_object(
      'status', f.status,
      'hg', f.home_goals,
      'ag', f.away_goals
    )
    FROM public.competition_fixtures f
    WHERE f.id = 9105
  ),
  'report', (
    SELECT jsonb_build_object('status', r.status, 'fine_applied_id', r.fine_applied_id)
    FROM public.match_video_breach_reports r
    WHERE r.id = 7
  )
) AS info;
