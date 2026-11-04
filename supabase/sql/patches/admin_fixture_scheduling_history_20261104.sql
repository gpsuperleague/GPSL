-- =============================================================================
-- Admin: read-only scheduling negotiation history for a fixture
-- Proposals + inbox + schedule state + mutual override + check-ins + no-shows
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_fixture_scheduling_history(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
  v_schedule jsonb;
  v_proposals jsonb;
  v_inbox jsonb;
  v_overrides jsonb;
  v_checkins jsonb;
  v_noshows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_fixture_id IS NULL OR p_fixture_id <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_id_required');
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  SELECT to_jsonb(s) INTO v_schedule
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.created_at, p.id), '[]'::jsonb)
  INTO v_proposals
  FROM public.competition_fixture_schedule_proposal p
  WHERE p.fixture_id = p_fixture_id;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', i.id,
        'recipient_club_short_name', i.recipient_club_short_name,
        'message_type', i.message_type,
        'title', i.title,
        'body', i.body,
        'schedule_proposal_id', i.schedule_proposal_id,
        'gpsl_month', i.gpsl_month,
        'created_at', i.created_at,
        'read_at', i.read_at
      )
      ORDER BY i.created_at, i.id
    ),
    '[]'::jsonb
  )
  INTO v_inbox
  FROM public.competition_inbox i
  WHERE i.fixture_id = p_fixture_id
    AND (
      i.message_type LIKE 'match_%'
      OR i.schedule_proposal_id IS NOT NULL
    );

  SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY o.created_at, o.id), '[]'::jsonb)
  INTO v_overrides
  FROM public.competition_fixture_mutual_override o
  WHERE o.fixture_id = p_fixture_id;

  SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.checked_in_at), '[]'::jsonb)
  INTO v_checkins
  FROM public.competition_fixture_checkin c
  WHERE c.fixture_id = p_fixture_id;

  SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY n.created_at, n.id), '[]'::jsonb)
  INTO v_noshows
  FROM public.competition_fixture_no_show_events n
  WHERE n.fixture_id = p_fixture_id;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture', jsonb_build_object(
      'fixture_id', v_f.id,
      'season_id', v_f.season_id,
      'status', v_f.status,
      'competition_type', v_f.competition_type,
      'division', v_f.division,
      'cup_code', v_f.cup_code,
      'matchday', v_f.matchday,
      'gpsl_month', v_f.gpsl_month,
      'home_club_short_name', v_f.home_club_short_name,
      'away_club_short_name', v_f.away_club_short_name,
      'home_goals', v_f.home_goals,
      'away_goals', v_f.away_goals,
      'is_forfeit', coalesce(v_f.is_forfeit, false)
    ),
    'schedule', v_schedule,
    'proposals', v_proposals,
    'inbox', v_inbox,
    'mutual_overrides', v_overrides,
    'checkins', v_checkins,
    'no_show_events', v_noshows
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_fixture_scheduling_history(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_fixture_scheduling_history(bigint) TO authenticated;
