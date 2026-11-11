-- League replies: 48 hours, and a miss is a strike.
-- A 48-hour clock can finish in the next GPSL month. A lock during those
-- 48 hours does not strike. The strike lands when the 48 hours end.
-- Still silent at a later lock: another strike. The proposal stays open.
-- Cups keep the warning, then the ₿1m reply fine.
-- Deadlines already overdue when this is applied wait for the next lock.

CREATE TABLE IF NOT EXISTS public.gpsl_rule_cutover (
  rule_key text PRIMARY KEY,
  cutover_at timestamptz NOT NULL
);

INSERT INTO public.gpsl_rule_cutover (rule_key, cutover_at)
VALUES ('reply_strike_48h', now())
ON CONFLICT (rule_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.competition_fixture_reply_strikes (
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  club_short_name text NOT NULL,
  pending_proposal_id bigint NOT NULL,
  kind text NOT NULL,
  gpsl_month text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fixture_id, club_short_name, pending_proposal_id, kind, gpsl_month),
  CONSTRAINT competition_fixture_reply_strikes_kind
    CHECK (kind IN ('deadline', 'lock'))
);

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_strike_count(
  p_fixture_id bigint,
  p_club text
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (
    coalesce((
      SELECT count(*)::int
      FROM public.competition_fixture_no_show_events e
      WHERE e.fixture_id = p_fixture_id
        AND e.club_short_name = p_club
    ), 0)
    + coalesce((
      SELECT count(*)::int
      FROM public.competition_fixture_proposal_strikes s
      WHERE s.fixture_id = p_fixture_id
        AND s.club_short_name = p_club
    ), 0)
    + coalesce((
      SELECT count(*)::int
      FROM public.competition_fixture_reply_strikes r
      WHERE r.fixture_id = p_fixture_id
        AND r.club_short_name = p_club
    ), 0)
  );
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_compute_response_due_at(
  p_fixture_id bigint,
  p_proposal_id bigint,
  p_proposed_at timestamptz,
  p_proposer_club text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_play_unlock timestamptz;
  v_is_first_proposal boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN p_proposed_at + interval '48 hours';
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN p_proposed_at + interval '48 hours';
  END IF;

  SELECT cal.unlock_at INTO v_play_unlock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_fixture.season_id
    AND cal.gpsl_month = v_fixture.gpsl_month;

  SELECT NOT EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.id <> p_proposal_id
      AND p.status <> 'withdrawn'
  )
  INTO v_is_first_proposal;

  IF NOT v_is_first_proposal THEN
    RETURN p_proposed_at + interval '48 hours';
  END IF;

  IF v_play_unlock IS NOT NULL AND p_proposed_at < v_play_unlock THEN
    IF p_proposed_at >= v_play_unlock - interval '48 hours' THEN
      RETURN p_proposed_at + interval '48 hours';
    END IF;
    RETURN v_play_unlock;
  END IF;

  RETURN p_proposed_at + interval '48 hours';
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_record_reply_strike(
  p_fixture_id bigint,
  p_club text,
  p_proposal_id bigint,
  p_kind text,
  p_month text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows integer := 0;
BEGIN
  INSERT INTO public.competition_fixture_reply_strikes (
    fixture_id, club_short_name, pending_proposal_id, kind, gpsl_month
  )
  VALUES (
    p_fixture_id,
    p_club,
    p_proposal_id,
    p_kind,
    coalesce(lower(btrim(p_month)), '')
  )
  ON CONFLICT (fixture_id, club_short_name, pending_proposal_id, kind, gpsl_month)
  DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN false;
  END IF;

  PERFORM public.match_schedule_on_strike(p_fixture_id, p_club, 'reply');
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_apply_reply_lock_strike(
  p_fixture_id bigint,
  p_club text,
  p_proposal_id bigint,
  p_closed_month text,
  p_due_at timestamptz,
  p_lock timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cutover timestamptz;
  v_has_deadline boolean;
BEGIN
  IF p_due_at IS NULL OR p_lock IS NULL OR p_due_at >= p_lock OR p_proposal_id IS NULL THEN
    RETURN;
  END IF;

  SELECT c.cutover_at INTO v_cutover
  FROM public.gpsl_rule_cutover c
  WHERE c.rule_key = 'reply_strike_48h';

  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixture_reply_strikes r
    WHERE r.fixture_id = p_fixture_id
      AND r.club_short_name = p_club
      AND r.pending_proposal_id = p_proposal_id
      AND r.kind = 'deadline'
  )
  INTO v_has_deadline;

  IF v_has_deadline OR (v_cutover IS NOT NULL AND p_due_at < v_cutover) THEN
    PERFORM public.match_schedule_record_reply_strike(
      p_fixture_id, p_club, p_proposal_id, 'lock', p_closed_month
    );
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_reply_strike_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cutover timestamptz;
  v_row record;
  v_n integer := 0;
BEGIN
  SELECT c.cutover_at INTO v_cutover
  FROM public.gpsl_rule_cutover c
  WHERE c.rule_key = 'reply_strike_48h';

  IF v_cutover IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_cutover');
  END IF;

  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at,
      s.response_required_club_short_name AS club,
      f.season_id,
      f.gpsl_month
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_due_at IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at < now()
      AND s.response_due_at >= v_cutover
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.response_required_club_short_name
          AND c.owner_id IS NOT NULL
      )
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
      AND NOT (
        to_regprocedure('public.match_schedule_club_on_holiday_for_month(bigint,text,text)') IS NOT NULL
        AND public.match_schedule_club_on_holiday_for_month(
          f.season_id, s.response_required_club_short_name, f.gpsl_month
        )
      )
      AND NOT (
        to_regprocedure('public.club_scheduling_fines_in_new_owner_grace(bigint,text,text)') IS NOT NULL
        AND public.club_scheduling_fines_in_new_owner_grace(
          f.season_id, s.response_required_club_short_name, f.gpsl_month
        )
      )
      AND NOT (
        to_regprocedure('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)') IS NOT NULL
        AND public.match_schedule_fixture_deadlines_suppressed_for_club(
          f.id, s.response_required_club_short_name
        )
      )
  LOOP
    IF public.match_schedule_record_reply_strike(
      v_row.fixture_id, v_row.club, v_row.pending_proposal_id, 'deadline', ''
    ) THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'strikes', v_n);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_deadline_and_reply_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.owner_deadline_warning_tick();
  PERFORM public.match_schedule_reply_strike_tick();
END;
$function$;

-- Label a reply strike, and tell the club. The proposal stays open.
DO $on_strike$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_schedule_on_strike(bigint,text,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('Missed reply' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$  v_note := CASE
    WHEN p_reason = 'no_proposal' THEN 'No home proposal'
    ELSE 'Missed check-in'
  END;$old$, E'\r\n', E'\n');
  v_new := replace($new$  v_note := CASE
    WHEN p_reason = 'no_proposal' THEN 'No home proposal'
    WHEN p_reason = 'reply' THEN 'Missed reply'
    ELSE 'Missed check-in'
  END;$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'on_strike note case not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$  IF p_reason = 'no_proposal' THEN
    PERFORM public.owner_inbox_send($old$, E'\r\n', E'\n');
  v_new := replace($new$  IF p_reason = 'reply' THEN
    PERFORM public.owner_inbox_send(
      'match_noshow_fine',
      'Reply missed — strike, ₿500k',
      coalesce(public.club_display_name(p_club), p_club)
        || ' missed a reply. Strike ' || v_fix::text
        || ' of 3 on this fixture. Season strikes: ' || v_season_n::text
        || '. Each strike is ₿500k. A third on this fixture forfeits it and adds ₿1m. The proposal stays open.',
      p_club,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'replystrike:' || p_fixture_id::text || ':' || p_club || ':' || v_fix::text,
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
  END IF;

  IF p_reason = 'no_proposal' THEN
    PERFORM public.owner_inbox_send($new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'on_strike inbox branch not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END;
$on_strike$;

-- League rows at a month lock use the strike. Cups keep the warning and ₿1m.
DO $lock$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_enforce_scheduling_response_fines(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('pending_proposal_id' IN v_def) = 0 THEN
    RAISE EXCEPTION 'response fines row has no pending proposal';
  END IF;
  IF position('match_schedule_apply_reply_lock_strike' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$    v_href := 'fixture_schedule.html?fixture=' || v_row.fixture_id::text;

    IF v_row.response_deadline_warned_at IS NULL THEN$old$, E'\r\n', E'\n');
  v_new := replace($new$    v_href := 'fixture_schedule.html?fixture=' || v_row.fixture_id::text;

    IF EXISTS (
      SELECT 1
      FROM public.competition_fixtures fx
      WHERE fx.id = v_row.fixture_id
        AND fx.competition_type = 'league'
        AND NOT (
          to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
          AND public.fixture_is_manual_black_box(fx.id)
        )
    ) THEN
      PERFORM public.match_schedule_apply_reply_lock_strike(
        v_row.fixture_id,
        v_row.response_required_club_short_name,
        v_row.pending_proposal_id,
        p_closed_gpsl_month,
        v_row.response_due_at,
        v_lock
      );
      CONTINUE;
    END IF;

    IF v_row.response_deadline_warned_at IS NULL THEN$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'response fines href block not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$lock$;

-- Open negotiations pick up the 48-hour clock. A date already in the past
-- stays before the cutover, so it is not struck until the next lock.
DO $recalc$
DECLARE
  v_row record;
  v_new_due timestamptz;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at AS old_due,
      p.created_at AS proposed_at,
      p.proposed_by_club_short_name AS proposer
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    JOIN public.competition_fixture_schedule_proposal p ON p.id = s.pending_proposal_id
    WHERE s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND p.status = 'pending'
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
  LOOP
    v_new_due := public.match_schedule_compute_response_due_at(
      v_row.fixture_id,
      v_row.pending_proposal_id,
      v_row.proposed_at,
      v_row.proposer
    );
    IF v_new_due IS DISTINCT FROM v_row.old_due THEN
      UPDATE public.competition_fixture_schedule
      SET response_due_at = v_new_due, updated_at = now()
      WHERE fixture_id = v_row.fixture_id;
    END IF;
  END LOOP;
END;
$recalc$;

DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — reply strikes will not run on their own';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-deadline-warnings') THEN
    PERFORM cron.unschedule('gpsl-deadline-warnings');
  END IF;
  PERFORM cron.schedule(
    'gpsl-deadline-warnings',
    '*/15 * * * *',
    $q$SELECT public.gpsl_deadline_and_reply_tick();$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule reply strikes: %', SQLERRM;
END;
$cron$;

REVOKE ALL ON FUNCTION public.match_schedule_reply_strike_tick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gpsl_deadline_and_reply_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_reply_strike_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_deadline_and_reply_tick() TO service_role;

NOTIFY pgrst, 'reload schema';
