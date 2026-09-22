-- =============================================================================
-- Fixture network incidents (mid-match disconnect / visibility) — 2026-09-22
--
-- Additive only. Safe re-run.
--
-- Design (v1 — do not break scheduling / month-lock / result flow):
--   • Light report  → insert row + inbox opponent. NO fixture.status change.
--   • Peer retry / reschedule ack → incident status only (use existing schedule UI).
--   • Escalate      → status=escalated, hold_requested=true, staff inbox alert.
--                     Does NOT rewrite competition_fixtures.status.
--   • Admin resolve → records outcome + inbox clubs. Does NOT auto-forfeit,
--                     auto-deploy, or rewrite kickoff. Admin uses existing tools.
--   • Month-lock    → helper fixture_network_incident_holds_fixture() exists for
--                     a later patch; this file does NOT alter month-lock RPCs.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_fixture_network_incidents (
  id bigserial PRIMARY KEY,
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures(id) ON DELETE CASCADE,
  season_id bigint NULL,
  gpsl_month text NULL,
  reporter_club_short_name text NOT NULL,
  opponent_club_short_name text NOT NULL,
  reporter_owner_id uuid NULL,
  -- Match state at report time (informational; not written to fixture)
  score_home smallint NULL,
  score_away smallint NULL,
  match_minute smallint NULL CHECK (match_minute IS NULL OR (match_minute >= 0 AND match_minute <= 120)),
  visibility_ok boolean NOT NULL DEFAULT true,
  video_available boolean NOT NULL DEFAULT false,
  evidence_url text NULL,
  note text NULL,
  -- logged | peer_retry | peer_reschedule | escalated | resolved
  status text NOT NULL DEFAULT 'logged'
    CHECK (status IN (
      'logged',
      'peer_retry',
      'peer_reschedule',
      'escalated',
      'resolved'
    )),
  hold_requested boolean NOT NULL DEFAULT false,
  -- Admin outcome when status = resolved
  -- dismiss | forfeit_reporter | forfeit_opponent | free_replay | resume | carry_over
  resolve_outcome text NULL
    CHECK (
      resolve_outcome IS NULL
      OR resolve_outcome IN (
        'dismiss',
        'forfeit_reporter',
        'forfeit_opponent',
        'free_replay',
        'resume',
        'carry_over'
      )
    ),
  resolve_note text NULL,
  resolved_by uuid NULL,
  resolved_at timestamptz NULL,
  escalated_at timestamptz NULL,
  escalated_by_club text NULL,
  peer_ack_at timestamptz NULL,
  peer_ack_by_club text NULL,
  staff_alerted_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS competition_fixture_network_incidents_fixture_idx
  ON public.competition_fixture_network_incidents (fixture_id, created_at DESC);

CREATE INDEX IF NOT EXISTS competition_fixture_network_incidents_open_idx
  ON public.competition_fixture_network_incidents (status)
  WHERE status IN ('logged', 'peer_retry', 'peer_reschedule', 'escalated');

CREATE INDEX IF NOT EXISTS competition_fixture_network_incidents_hold_idx
  ON public.competition_fixture_network_incidents (fixture_id)
  WHERE hold_requested AND status = 'escalated';

COMMENT ON TABLE public.competition_fixture_network_incidents IS
  'Mid-match network / visibility reports. Isolated from fixture.status until admin acts with existing tools.';

ALTER TABLE public.competition_fixture_network_incidents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_fixture_network_incidents_select ON public.competition_fixture_network_incidents;
CREATE POLICY competition_fixture_network_incidents_select
  ON public.competition_fixture_network_incidents
  FOR SELECT
  TO authenticated
  USING (
    public.is_gpsl_admin()
    OR EXISTS (
      SELECT 1
      FROM public."Clubs" c
      WHERE c.owner_id = auth.uid()
        AND upper(c."ShortName") IN (
          upper(reporter_club_short_name),
          upper(opponent_club_short_name)
        )
    )
  );

-- Writes only via SECURITY DEFINER RPCs
DROP POLICY IF EXISTS competition_fixture_network_incidents_write ON public.competition_fixture_network_incidents;
CREATE POLICY competition_fixture_network_incidents_write
  ON public.competition_fixture_network_incidents
  FOR ALL
  TO authenticated
  USING (false)
  WITH CHECK (false);

GRANT SELECT ON public.competition_fixture_network_incidents TO authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_network_incident_holds_fixture(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixture_network_incidents i
    WHERE i.fixture_id = p_fixture_id
      AND i.hold_requested
      AND i.status = 'escalated'
  );
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_network_incident_holds_fixture(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.fixture_network_my_club()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;
  RETURN nullif(btrim(v_club), '');
END;
$function$;

-- ---------------------------------------------------------------------------
-- File (light report) — no fixture mutation
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_network_incident_file(
  p_fixture_id bigint,
  p_score_home smallint DEFAULT NULL,
  p_score_away smallint DEFAULT NULL,
  p_match_minute smallint DEFAULT NULL,
  p_visibility_ok boolean DEFAULT true,
  p_video_available boolean DEFAULT false,
  p_evidence_url text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_my text;
  v_f record;
  v_opp text;
  v_id bigint;
  v_url text := nullif(btrim(p_evidence_url), '');
  v_note text := nullif(btrim(p_note), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_my := public.fixture_network_my_club();
  IF v_my IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT
    f.id,
    f.season_id,
    f.gpsl_month,
    f.home_club_short_name,
    f.away_club_short_name,
    f.status
  INTO v_f
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF coalesce(v_f.status, '') = 'played' THEN
    RAISE EXCEPTION 'This fixture is already played';
  END IF;

  IF upper(v_my) = upper(v_f.home_club_short_name) THEN
    v_opp := v_f.away_club_short_name;
  ELSIF upper(v_my) = upper(v_f.away_club_short_name) THEN
    v_opp := v_f.home_club_short_name;
  ELSE
    RAISE EXCEPTION 'You are not a participant in this fixture';
  END IF;

  IF p_match_minute IS NOT NULL AND (p_match_minute < 0 OR p_match_minute > 120) THEN
    RAISE EXCEPTION 'Match minute must be between 0 and 120';
  END IF;

  IF v_url IS NOT NULL AND length(v_url) > 2000 THEN
    RAISE EXCEPTION 'Evidence URL is too long';
  END IF;

  IF v_note IS NOT NULL AND length(v_note) > 2000 THEN
    RAISE EXCEPTION 'Note is too long';
  END IF;

  INSERT INTO public.competition_fixture_network_incidents (
    fixture_id,
    season_id,
    gpsl_month,
    reporter_club_short_name,
    opponent_club_short_name,
    reporter_owner_id,
    score_home,
    score_away,
    match_minute,
    visibility_ok,
    video_available,
    evidence_url,
    note,
    status
  ) VALUES (
    p_fixture_id,
    v_f.season_id,
    v_f.gpsl_month,
    v_my,
    v_opp,
    v_uid,
    p_score_home,
    p_score_away,
    p_match_minute,
    coalesce(p_visibility_ok, true),
    coalesce(p_video_available, false),
    v_url,
    v_note,
    'logged'
  )
  RETURNING id INTO v_id;

  -- Opponent inbox (best-effort; never fail the report)
  BEGIN
    PERFORM public.owner_inbox_send(
      'network_incident_logged',
      'Network issue reported — ' || upper(v_my),
      format(
        '%s reported a mid-match network / visibility issue on your fixture (id %s). Score noted: %s-%s at %s''. Open Match Day to acknowledge a retry/reschedule or escalate if needed.',
        upper(v_my),
        p_fixture_id,
        coalesce(p_score_home::text, '?'),
        coalesce(p_score_away::text, '?'),
        coalesce(p_match_minute::text, '?')
      ),
      v_opp,
      NULL,
      p_fixture_id,
      NULL,
      NULL,
      NULL,
      'matchday.html?fixture=' || p_fixture_id::text,
      'network_incident_' || v_id::text,
      v_f.gpsl_month,
      v_f.season_id,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'incident_id', v_id,
    'fixture_id', p_fixture_id,
    'status', 'logged',
    'fixture_status_unchanged', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_network_incident_file(
  bigint, smallint, smallint, smallint, boolean, boolean, text, text
) TO authenticated;

-- ---------------------------------------------------------------------------
-- List for a fixture (participants + admin)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_network_incident_list_for_fixture(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_my text;
  v_f record;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_f
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN '[]'::jsonb;
  END IF;

  v_my := public.fixture_network_my_club();

  IF NOT public.is_gpsl_admin()
     AND (
       v_my IS NULL
       OR (
         upper(v_my) IS DISTINCT FROM upper(v_f.home_club_short_name)
         AND upper(v_my) IS DISTINCT FROM upper(v_f.away_club_short_name)
       )
     )
  THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC)
    FROM (
      SELECT
        i.id,
        i.fixture_id,
        i.reporter_club_short_name,
        i.opponent_club_short_name,
        i.score_home,
        i.score_away,
        i.match_minute,
        i.visibility_ok,
        i.video_available,
        i.evidence_url,
        i.note,
        i.status,
        i.hold_requested,
        i.resolve_outcome,
        i.resolve_note,
        i.resolved_at,
        i.escalated_at,
        i.peer_ack_at,
        i.peer_ack_by_club,
        i.created_at
      FROM public.competition_fixture_network_incidents i
      WHERE i.fixture_id = p_fixture_id
    ) x
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_network_incident_list_for_fixture(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Peer acknowledge → retry or reschedule intent (no schedule mutation)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_network_incident_peer_ack(
  p_incident_id bigint,
  p_action text -- 'retry' | 'reschedule'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_my text;
  v_i record;
  v_new_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_my := public.fixture_network_my_club();
  IF v_my IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF lower(coalesce(p_action, '')) NOT IN ('retry', 'reschedule') THEN
    RAISE EXCEPTION 'Action must be retry or reschedule';
  END IF;

  SELECT * INTO v_i
  FROM public.competition_fixture_network_incidents
  WHERE id = p_incident_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident not found';
  END IF;

  IF v_i.status NOT IN ('logged', 'peer_retry', 'peer_reschedule') THEN
    RAISE EXCEPTION 'Incident can no longer be peer-acknowledged (status=%)', v_i.status;
  END IF;

  IF upper(v_my) IS DISTINCT FROM upper(v_i.opponent_club_short_name)
     AND upper(v_my) IS DISTINCT FROM upper(v_i.reporter_club_short_name) THEN
    RAISE EXCEPTION 'You are not a party to this incident';
  END IF;

  -- Prefer opponent ack; reporter can also mark preferred path
  v_new_status := CASE WHEN lower(p_action) = 'retry' THEN 'peer_retry' ELSE 'peer_reschedule' END;

  UPDATE public.competition_fixture_network_incidents
  SET
    status = v_new_status,
    peer_ack_at = now(),
    peer_ack_by_club = v_my,
    updated_at = now()
  WHERE id = p_incident_id;

  BEGIN
    PERFORM public.owner_inbox_send(
      'network_incident_peer_ack',
      'Network incident — ' || upper(v_new_status),
      format(
        '%s marked the network incident as %s. Use Match Scheduling to set a new kick-off if needed (fixture %s).',
        upper(v_my),
        v_new_status,
        v_i.fixture_id
      ),
      CASE
        WHEN upper(v_my) = upper(v_i.reporter_club_short_name)
          THEN v_i.opponent_club_short_name
        ELSE v_i.reporter_club_short_name
      END,
      NULL,
      v_i.fixture_id,
      NULL,
      NULL,
      NULL,
      'matchday.html?fixture=' || v_i.fixture_id::text,
      'network_incident_ack_' || p_incident_id::text || '_' || v_new_status,
      v_i.gpsl_month,
      v_i.season_id,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'incident_id', p_incident_id,
    'status', v_new_status,
    'fixture_status_unchanged', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_network_incident_peer_ack(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Escalate → hold flag on incident only + staff alert
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_network_incident_escalate(
  p_incident_id bigint,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_my text;
  v_i record;
  v_note text := nullif(btrim(p_note), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_my := public.fixture_network_my_club();
  IF v_my IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_i
  FROM public.competition_fixture_network_incidents
  WHERE id = p_incident_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident not found';
  END IF;

  IF upper(v_my) IS DISTINCT FROM upper(v_i.reporter_club_short_name)
     AND upper(v_my) IS DISTINCT FROM upper(v_i.opponent_club_short_name) THEN
    RAISE EXCEPTION 'You are not a party to this incident';
  END IF;

  IF v_i.status = 'resolved' THEN
    RAISE EXCEPTION 'Incident already resolved';
  END IF;

  UPDATE public.competition_fixture_network_incidents
  SET
    status = 'escalated',
    hold_requested = true,
    escalated_at = coalesce(escalated_at, now()),
    escalated_by_club = v_my,
    note = CASE
      WHEN v_note IS NULL THEN note
      WHEN note IS NULL OR note = '' THEN v_note
      ELSE note || E'\n--- escalate ---\n' || v_note
    END,
    staff_alerted_at = coalesce(staff_alerted_at, now()),
    updated_at = now()
  WHERE id = p_incident_id;

  -- Alert both clubs
  BEGIN
    PERFORM public.owner_inbox_send(
      'network_incident_escalated',
      'Network incident escalated to staff',
      format(
        'Fixture %s network incident #%s was escalated by %s and is held for admin review. Fixture status was not changed automatically.',
        v_i.fixture_id,
        p_incident_id,
        upper(v_my)
      ),
      v_i.reporter_club_short_name,
      NULL,
      v_i.fixture_id,
      NULL, NULL, NULL,
      'matchday.html?fixture=' || v_i.fixture_id::text,
      'network_escalated_rep_' || p_incident_id::text,
      v_i.gpsl_month,
      v_i.season_id,
      NULL
    );
    PERFORM public.owner_inbox_send(
      'network_incident_escalated',
      'Network incident escalated to staff',
      format(
        'Fixture %s network incident #%s was escalated by %s and is held for admin review. Fixture status was not changed automatically.',
        v_i.fixture_id,
        p_incident_id,
        upper(v_my)
      ),
      v_i.opponent_club_short_name,
      NULL,
      v_i.fixture_id,
      NULL, NULL, NULL,
      'matchday.html?fixture=' || v_i.fixture_id::text,
      'network_escalated_opp_' || p_incident_id::text,
      v_i.gpsl_month,
      v_i.season_id,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'incident_id', p_incident_id,
    'status', 'escalated',
    'hold_requested', true,
    'fixture_status_unchanged', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_network_incident_escalate(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin queue list
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_network_incident_admin_list(
  p_include_resolved boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_ts DESC)
    FROM (
      SELECT
        i.id,
        i.fixture_id,
        i.gpsl_month,
        i.season_id,
        i.reporter_club_short_name,
        i.opponent_club_short_name,
        i.score_home,
        i.score_away,
        i.match_minute,
        i.visibility_ok,
        i.video_available,
        i.evidence_url,
        i.note,
        i.status,
        i.hold_requested,
        i.resolve_outcome,
        i.resolve_note,
        i.resolved_at,
        i.escalated_at,
        i.created_at,
        coalesce(i.escalated_at, i.created_at) AS sort_ts,
        f.home_club_short_name,
        f.away_club_short_name,
        f.competition_type,
        f.division,
        f.cup_code,
        f.status AS fixture_status,
        f.agreed_kickoff_at
      FROM public.competition_fixture_network_incidents i
      JOIN public.competition_fixtures f ON f.id = i.fixture_id
      WHERE p_include_resolved
         OR i.status IN ('logged', 'peer_retry', 'peer_reschedule', 'escalated')
    ) x
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_network_incident_admin_list(boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin resolve — records decision only (no auto fixture mutation)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_network_incident_admin_resolve(
  p_incident_id bigint,
  p_outcome text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_i record;
  v_outcome text := lower(nullif(btrim(p_outcome), ''));
  v_note text := nullif(btrim(p_note), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_outcome IS NULL OR v_outcome NOT IN (
    'dismiss',
    'forfeit_reporter',
    'forfeit_opponent',
    'free_replay',
    'resume',
    'carry_over'
  ) THEN
    RAISE EXCEPTION 'Invalid outcome';
  END IF;

  SELECT * INTO v_i
  FROM public.competition_fixture_network_incidents
  WHERE id = p_incident_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident not found';
  END IF;

  IF v_i.status = 'resolved' THEN
    RAISE EXCEPTION 'Already resolved';
  END IF;

  UPDATE public.competition_fixture_network_incidents
  SET
    status = 'resolved',
    hold_requested = false,
    resolve_outcome = v_outcome,
    resolve_note = v_note,
    resolved_by = auth.uid(),
    resolved_at = now(),
    updated_at = now()
  WHERE id = p_incident_id;

  BEGIN
    PERFORM public.owner_inbox_send(
      'network_incident_resolved',
      'Network incident resolved — ' || v_outcome,
      format(
        'Staff resolved network incident #%s on fixture %s as %s.%s Fixture rows were not auto-changed; follow any staff instructions for replay / forfeit / resume.',
        p_incident_id,
        v_i.fixture_id,
        v_outcome,
        CASE WHEN v_note IS NULL THEN '' ELSE E'\n\n' || v_note END
      ),
      v_i.reporter_club_short_name,
      NULL,
      v_i.fixture_id,
      NULL, NULL, NULL,
      'matchday.html?fixture=' || v_i.fixture_id::text,
      'network_resolved_rep_' || p_incident_id::text,
      v_i.gpsl_month,
      v_i.season_id,
      NULL
    );
    PERFORM public.owner_inbox_send(
      'network_incident_resolved',
      'Network incident resolved — ' || v_outcome,
      format(
        'Staff resolved network incident #%s on fixture %s as %s.%s Fixture rows were not auto-changed; follow any staff instructions for replay / forfeit / resume.',
        p_incident_id,
        v_i.fixture_id,
        v_outcome,
        CASE WHEN v_note IS NULL THEN '' ELSE E'\n\n' || v_note END
      ),
      v_i.opponent_club_short_name,
      NULL,
      v_i.fixture_id,
      NULL, NULL, NULL,
      'matchday.html?fixture=' || v_i.fixture_id::text,
      'network_resolved_opp_' || p_incident_id::text,
      v_i.gpsl_month,
      v_i.season_id,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'incident_id', p_incident_id,
    'status', 'resolved',
    'resolve_outcome', v_outcome,
    'fixture_status_unchanged', true,
    'note', 'Apply forfeit / replay / resume via existing admin tools if required.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_network_incident_admin_resolve(bigint, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
