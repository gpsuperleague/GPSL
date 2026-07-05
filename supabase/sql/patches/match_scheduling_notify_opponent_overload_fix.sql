-- =============================================================================
-- Fix: match_schedule_notify_opponent is not unique (6-arg vs 7-arg overload)
-- =============================================================================
-- Adding p_proposal_id with DEFAULT via CREATE OR REPLACE leaves the old
-- 6-parameter version in place. Six-argument calls (replay reset, voluntary drop,
-- etc.) then match both overloads → "function is not unique".
--
-- Run once in Supabase SQL Editor. Safe to re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.match_schedule_notify_opponent(
  public.competition_fixtures,
  text,
  text,
  text,
  text,
  text
);

CREATE OR REPLACE FUNCTION public.match_schedule_notify_opponent(
  p_fixture public.competition_fixtures,
  p_message_type text,
  p_title text,
  p_body text,
  p_opponent_club text,
  p_dedupe_suffix text,
  p_proposal_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_href text;
  v_title text;
  v_body text;
BEGIN
  v_href := 'fixture_schedule.html?fixture=' || p_fixture.id::text;
  v_title := public.competition_fixture_inbox_title(p_fixture.id, p_title);
  v_body := public.competition_fixture_inbox_body(p_fixture.id, p_body);

  PERFORM public.owner_inbox_send(
    p_message_type,
    v_title,
    v_body,
    p_opponent_club,
    NULL,
    p_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix,
    p_fixture.gpsl_month,
    p_fixture.season_id,
    p_proposal_id
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
