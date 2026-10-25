-- =============================================================================
-- Attempt 3+ no-show ladder (2026-10-25)
-- =============================================================================
-- Does NOT replace attempts 1–2 (deferred month-lock 3–0 + match_agreed_no_show).
--
-- Attempt = each distinct agreed kick-off (play_attempt_count bumps when KO changes).
-- From attempt 3 onward (or once open play is active):
--   • 1st no-show per club on this fixture → warning only
--   • each further no-show by that club → ₿1.5m fine
--   • first fine starts open play: propose/accept for 2 more GPSL months
--   • at deadline lock, still unplayed:
--       - higher no-show count forfeits 3–0 (no extra tariff beyond history fines)
--       - tied counts (both have marks) → 0–0 dual forfeit + ₿1.5m each
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
ALTER TABLE public.competition_fixture_schedule
  ADD COLUMN IF NOT EXISTS play_attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS open_play_active boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS open_play_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS open_play_deadline_gpsl_month text;

CREATE TABLE IF NOT EXISTS public.competition_fixture_no_show_events (
  id bigserial PRIMARY KEY,
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures(id) ON DELETE CASCADE,
  club_short_name text NOT NULL,
  kickoff_at timestamptz NOT NULL,
  play_attempt_no integer NOT NULL,
  action text NOT NULL CHECK (action IN ('warn', 'fine')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT competition_fixture_no_show_events_uniq
    UNIQUE (fixture_id, club_short_name, kickoff_at)
);

CREATE INDEX IF NOT EXISTS competition_fixture_no_show_events_fixture_idx
  ON public.competition_fixture_no_show_events (fixture_id);

-- Backfill: already-agreed kick-offs count as attempt 1 if never bumped
UPDATE public.competition_fixture_schedule
SET play_attempt_count = 1
WHERE agreed_kickoff_at IS NOT NULL
  AND coalesce(play_attempt_count, 0) = 0;

-- ---------------------------------------------------------------------------
-- Tariffs (₿1.5m)
-- ---------------------------------------------------------------------------
INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES
  (
    'match_no_show_repeat',
    'Repeat no-show (attempt 3+)',
    'matchday',
    'fine',
    1500000,
    'fixed',
    62,
    true
  ),
  (
    'match_no_show_open_play_dual',
    'Open-play deadline — both no-shows',
    'matchday',
    'fine',
    1500000,
    'fixed',
    63,
    true
  )
ON CONFLICT (code) DO UPDATE SET
  label = EXCLUDED.label,
  amount = EXCLUDED.amount,
  is_active = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Inbox types
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NOT NULL
     AND position('''match_noshow_warning''' IN v_def) > 0
     AND position('''match_noshow_repeat_fine''' IN v_def) > 0
     AND position('''match_noshow_open_play''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t FROM public.competition_inbox WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'match_noshow_recorded'
    UNION SELECT 'match_noshow_warning'
    UNION SELECT 'match_noshow_repeat_fine'
    UNION SELECT 'match_noshow_open_play'
    UNION SELECT 'match_noshow_open_play_resolved'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_gpsl_month_plus(
  p_season_id bigint,
  p_gpsl_month text,
  p_ahead integer
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base_sort integer;
  v_month text;
BEGIN
  IF p_season_id IS NULL OR p_gpsl_month IS NULL OR p_ahead IS NULL OR p_ahead < 0 THEN
    RETURN NULL;
  END IF;

  v_base_sort := public.competition_gpsl_month_sort(lower(btrim(p_gpsl_month)));
  IF v_base_sort IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.gpsl_month
  INTO v_month
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND public.competition_gpsl_month_sort(c.gpsl_month) = v_base_sort + p_ahead
  LIMIT 1;

  IF v_month IS NOT NULL THEN
    RETURN v_month;
  END IF;

  -- Past end of calendar: clamp to last month of this season
  SELECT c.gpsl_month
  INTO v_month
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
  ORDER BY public.competition_gpsl_month_sort(c.gpsl_month) DESC
  LIMIT 1;

  RETURN v_month;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_bump_play_attempt_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.agreed_kickoff_at IS NOT NULL AND coalesce(NEW.play_attempt_count, 0) = 0 THEN
      NEW.play_attempt_count := 1;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.agreed_kickoff_at IS NOT NULL
     AND NEW.agreed_kickoff_at IS DISTINCT FROM OLD.agreed_kickoff_at THEN
    NEW.play_attempt_count := coalesce(OLD.play_attempt_count, 0) + 1;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS competition_fixture_schedule_play_attempt_trg
  ON public.competition_fixture_schedule;

CREATE TRIGGER competition_fixture_schedule_play_attempt_trg
  BEFORE INSERT OR UPDATE OF agreed_kickoff_at
  ON public.competition_fixture_schedule
  FOR EACH ROW
  EXECUTE FUNCTION public.match_schedule_bump_play_attempt_trg();

CREATE OR REPLACE FUNCTION public.match_schedule_no_show_counts(p_fixture_id bigint)
RETURNS TABLE (club_short_name text, no_show_count integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT e.club_short_name, count(*)::integer
  FROM public.competition_fixture_no_show_events e
  WHERE e.fixture_id = p_fixture_id
  GROUP BY e.club_short_name;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_start_open_play(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_deadline text;
  v_href text;
  v_was_active boolean := false;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT coalesce(s.open_play_active, false)
  INTO v_was_active
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  UPDATE public.competition_fixture_schedule s
  SET
    open_play_active = true,
    open_play_started_at = coalesce(s.open_play_started_at, now()),
    open_play_deadline_gpsl_month = coalesce(
      s.open_play_deadline_gpsl_month,
      public.match_schedule_gpsl_month_plus(
        v_fixture.season_id,
        coalesce(
          public.competition_active_gpsl_month(v_fixture.season_id, now()),
          v_fixture.gpsl_month
        ),
        2
      )
    ),
    updated_at = now()
  WHERE s.fixture_id = p_fixture_id
  RETURNING s.open_play_deadline_gpsl_month INTO v_deadline;

  IF v_was_active OR v_deadline IS NULL THEN
    RETURN;
  END IF;

  v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;
  PERFORM public.owner_inbox_send(
    'match_noshow_open_play',
    'Open play window started',
    'This fixture is on attempt 3+ open play after a repeat no-show. '
      || 'Arrange as usual (propose / accept) for the next 2 GPSL months '
      || '(through '
      || coalesce(public.competition_gpsl_month_label(v_deadline), v_deadline)
      || '). '
      || 'If still unplayed at that lock, the club with more no-shows forfeits; '
      || 'if both have equal no-shows, both forfeit 0-0 and each pays ₿1.5m.',
    v_fixture.home_club_short_name,
    NULL, p_fixture_id, NULL, NULL, NULL, v_href,
    'openplay:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_noshow_open_play',
    'Open play window started',
    'This fixture is on attempt 3+ open play after a repeat no-show. '
      || 'Arrange as usual (propose / accept) for the next 2 GPSL months '
      || '(through '
      || coalesce(public.competition_gpsl_month_label(v_deadline), v_deadline)
      || '). '
      || 'If still unplayed at that lock, the club with more no-shows forfeits; '
      || 'if both have equal no-shows, both forfeit 0-0 and each pays ₿1.5m.',
    v_fixture.away_club_short_name,
    NULL, p_fixture_id, NULL, NULL, NULL, v_href,
    'openplay:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_record_attempt3_no_show(
  p_fixture_id bigint,
  p_loser text,
  p_winner text,
  p_kickoff timestamptz,
  p_attempt integer
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_prior int;
  v_action text;
  v_fmt text;
  v_href text;
  v_rows int := 0;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::int
  INTO v_prior
  FROM public.competition_fixture_no_show_events e
  WHERE e.fixture_id = p_fixture_id
    AND e.club_short_name = p_loser;

  v_action := CASE WHEN v_prior = 0 THEN 'warn' ELSE 'fine' END;

  INSERT INTO public.competition_fixture_no_show_events (
    fixture_id, club_short_name, kickoff_at, play_attempt_no, action
  )
  VALUES (p_fixture_id, p_loser, p_kickoff, p_attempt, v_action)
  ON CONFLICT (fixture_id, club_short_name, kickoff_at) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN v_action;
  END IF;

  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff);
  v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;

  IF v_action = 'warn' THEN
    PERFORM public.owner_inbox_send(
      'match_noshow_warning',
      'No-show warning (attempt 3+)',
      coalesce(public.club_display_name(p_loser), p_loser)
        || ' did not check in at '
        || v_fmt
        || ' ('
        || coalesce(public.club_display_name(p_winner), p_winner)
        || ' did). This is a WARNING for '
        || coalesce(public.club_display_name(p_loser), p_loser)
        || ' on this fixture. Further no-shows by the same club cost ₿1.5m each. '
        || 'Pick a new time and play — the match is still open.',
      v_fixture.home_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow3warn:' || p_fixture_id::text || ':' || p_loser || ':' || p_kickoff::text || ':home',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
    PERFORM public.owner_inbox_send(
      'match_noshow_warning',
      'No-show warning (attempt 3+)',
      coalesce(public.club_display_name(p_loser), p_loser)
        || ' did not check in at '
        || v_fmt
        || ' ('
        || coalesce(public.club_display_name(p_winner), p_winner)
        || ' did). This is a WARNING for '
        || coalesce(public.club_display_name(p_loser), p_loser)
        || ' on this fixture. Further no-shows by the same club cost ₿1.5m each. '
        || 'Pick a new time and play — the match is still open.',
      v_fixture.away_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow3warn:' || p_fixture_id::text || ':' || p_loser || ':' || p_kickoff::text || ':away',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
  ELSE
    PERFORM public.competition_apply_club_fine_tariff(
      p_loser,
      'match_no_show_repeat',
      NULL,
      format('Attempt %s no-show at %s', p_attempt, v_fmt),
      p_fixture_id,
      v_fixture.season_id
    );

    PERFORM public.owner_inbox_send(
      'match_noshow_repeat_fine',
      'No-show fine ₿1.5m (attempt 3+)',
      coalesce(public.club_display_name(p_loser), p_loser)
        || ' missed check-in again at '
        || v_fmt
        || '. Fine: ₿1.5m. Open play arranging continues (propose / accept) — '
        || 'play the match before the open-play deadline.',
      v_fixture.home_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow3fine:' || p_fixture_id::text || ':' || p_loser || ':' || p_kickoff::text || ':home',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
    PERFORM public.owner_inbox_send(
      'match_noshow_repeat_fine',
      'No-show fine ₿1.5m (attempt 3+)',
      coalesce(public.club_display_name(p_loser), p_loser)
        || ' missed check-in again at '
        || v_fmt
        || '. Fine: ₿1.5m. Open play arranging continues (propose / accept) — '
        || 'play the match before the open-play deadline.',
      v_fixture.away_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow3fine:' || p_fixture_id::text || ':' || p_loser || ':' || p_kickoff::text || ':away',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );

    PERFORM public.match_schedule_start_open_play(p_fixture_id);
  END IF;

  RETURN v_action;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Record / route no-shows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fixture_try_checkin_forfeit(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_loser text;
  v_winner text;
  v_prev text;
  v_fmt text;
  v_href text;
  v_body text;
  v_attempt int := 0;
  v_open_play boolean := false;
  v_ladder boolean := false;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  PERFORM public.match_schedule_clear_no_show_if_played(p_fixture_id);

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  IF now() < v_window_end THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  IF NOT v_home_in AND NOT v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  IF v_home_in AND NOT v_away_in THEN
    v_loser := v_fixture.away_club_short_name;
    v_winner := v_fixture.home_club_short_name;
  ELSE
    v_loser := v_fixture.home_club_short_name;
    v_winner := v_fixture.away_club_short_name;
  END IF;

  SELECT
    coalesce(s.play_attempt_count, 0),
    coalesce(s.open_play_active, false),
    s.no_show_club_short_name
  INTO v_attempt, v_open_play, v_prev
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  IF v_attempt < 1 THEN
    v_attempt := 1;
  END IF;

  v_ladder := (v_attempt >= 3 OR v_open_play);

  UPDATE public.competition_fixture_schedule
  SET
    no_show_club_short_name = v_loser,
    no_show_kickoff_at = v_kickoff,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  IF v_ladder THEN
    PERFORM public.match_schedule_record_attempt3_no_show(
      p_fixture_id, v_loser, v_winner, v_kickoff, v_attempt
    );
    RETURN true;
  END IF;

  -- Attempts 1–2: existing soft record + month-lock forfeit path
  IF v_prev IS DISTINCT FROM v_loser THEN
    v_fmt := public.match_schedule_format_kickoff_uk(v_kickoff);
    v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;
    v_body :=
      'A one-sided no-show was recorded for kick-off '
      || v_fmt
      || E'.\n'
      || coalesce(public.club_display_name(v_loser), v_loser)
      || ' did not check in; '
      || coalesce(public.club_display_name(v_winner), v_winner)
      || E' did.\nYou can still play and confirm a normal result to clear this. '
      || E'If the match is still unfinished at the next GPSL month lock, the no-show club gets 3-0 and a ₿2.5m fine.';

    PERFORM public.owner_inbox_send(
      'match_noshow_recorded',
      'No-show recorded — still playable',
      v_body,
      v_fixture.home_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow:' || p_fixture_id::text || ':' || v_loser || ':home',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
    PERFORM public.owner_inbox_send(
      'match_noshow_recorded',
      'No-show recorded — still playable',
      v_body,
      v_fixture.away_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow:' || p_fixture_id::text || ':' || v_loser || ':away',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
  END IF;

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Month lock: skip attempt-3+ / open-play from classic deferred forfeit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_checkin_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_results jsonb := '[]'::jsonb;
  v_count int := 0;
  v_skipped int := 0;
  v_is_catch_up boolean;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  FOR v_row IN
    SELECT
      f.id AS fixture_id,
      s.no_show_club_short_name AS loser,
      f.matchday,
      f.gpsl_month,
      s.no_show_kickoff_at
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = p_season_id
      AND (
        CASE
          WHEN to_regprocedure('public.match_schedule_uses_club_month_rules(text)') IS NOT NULL
          THEN public.match_schedule_uses_club_month_rules(f.competition_type)
          ELSE f.competition_type IN ('league', 'cup')
        END
      )
      AND f.status = 'scheduled'
      AND s.no_show_club_short_name IS NOT NULL
      AND coalesce(s.play_attempt_count, 0) < 3
      AND coalesce(s.open_play_active, false) = false
      AND (
        f.gpsl_month = p_closed_gpsl_month
        OR public.match_schedule_fixture_is_catch_up(f.id)
      )
      AND (s.no_show_kickoff_at IS NULL OR s.no_show_kickoff_at < v_lock)
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.no_show_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_agreed_no_show'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_is_catch_up := public.match_schedule_fixture_is_catch_up(v_row.fixture_id)
      AND v_row.gpsl_month IS DISTINCT FROM p_closed_gpsl_month;

    PERFORM public.fixture_apply_forfeit(
      v_row.fixture_id,
      v_row.loser,
      'match_agreed_no_show',
      format(
        'sched_checkin_lock:%s:%s|No check-in at agreed kick-off · %s MD%s · assessed at month lock%s',
        p_closed_gpsl_month,
        v_row.fixture_id,
        public.competition_gpsl_month_label(v_row.gpsl_month),
        v_row.matchday,
        CASE WHEN v_is_catch_up THEN ' (catch-up)' ELSE '' END
      )
    );

    v_count := v_count + 1;
    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'loser', v_row.loser,
        'catch_up', v_is_catch_up
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'forfeits_applied', v_count,
    'skipped', v_skipped,
    'forfeited', v_results
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Open-play deadline resolution
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_apply_dual_no_show_forfeit(
  p_fixture_id bigint,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_href text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_fixture.status = 'played' THEN
    RETURN;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by dual no-show forfeit',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixtures
  SET
    home_goals = 0,
    away_goals = 0,
    status = 'played',
    is_forfeit = true,
    forfeit_loser_club = NULL
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_fine_tariff(
    v_fixture.home_club_short_name,
    'match_no_show_open_play_dual',
    NULL,
    coalesce(p_reason, 'Open-play deadline dual no-show'),
    p_fixture_id,
    v_fixture.season_id
  );
  PERFORM public.competition_apply_club_fine_tariff(
    v_fixture.away_club_short_name,
    'match_no_show_open_play_dual',
    NULL,
    coalesce(p_reason, 'Open-play deadline dual no-show'),
    p_fixture_id,
    v_fixture.season_id
  );

  IF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  ELSIF v_fixture.competition_type = 'league' THEN
    PERFORM public.competition_try_pay_league_division_prizes(
      v_fixture.season_id,
      v_fixture.division
    );
  END IF;

  v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;
  PERFORM public.owner_inbox_send(
    'match_noshow_open_play_resolved',
    'Open-play deadline — both forfeit 0-0',
    coalesce(p_reason, 'Both clubs had equal no-shows. Result 0-0; each club fined ₿1.5m.'),
    v_fixture.home_club_short_name,
    NULL, p_fixture_id, NULL, NULL, NULL, v_href,
    'openplay-dual:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_noshow_open_play_resolved',
    'Open-play deadline — both forfeit 0-0',
    coalesce(p_reason, 'Both clubs had equal no-shows. Result 0-0; each club fined ₿1.5m.'),
    v_fixture.away_club_short_name,
    NULL, p_fixture_id, NULL, NULL, NULL, v_href,
    'openplay-dual:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_enforce_open_play_no_show_resolution(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_home text;
  v_away text;
  v_home_n int;
  v_away_n int;
  v_results jsonb := '[]'::jsonb;
  v_count int := 0;
  v_closed_sort integer;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'month_not_closed');
  END IF;

  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);

  FOR v_row IN
    SELECT
      f.id AS fixture_id,
      f.home_club_short_name,
      f.away_club_short_name,
      f.matchday,
      f.gpsl_month,
      s.open_play_deadline_gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = p_season_id
      AND f.status = 'scheduled'
      AND coalesce(s.open_play_active, false) = true
      AND s.open_play_deadline_gpsl_month IS NOT NULL
      AND public.competition_gpsl_month_sort(s.open_play_deadline_gpsl_month) <= v_closed_sort
  LOOP
    v_home := v_row.home_club_short_name;
    v_away := v_row.away_club_short_name;

    SELECT coalesce(sum(CASE WHEN e.club_short_name = v_home THEN 1 ELSE 0 END), 0)::int,
           coalesce(sum(CASE WHEN e.club_short_name = v_away THEN 1 ELSE 0 END), 0)::int
    INTO v_home_n, v_away_n
    FROM public.competition_fixture_no_show_events e
    WHERE e.fixture_id = v_row.fixture_id;

    IF v_home_n = 0 AND v_away_n = 0 THEN
      -- Open play expired with no recorded attempt-3 events: leave for catch-up / admin
      CONTINUE;
    END IF;

    IF v_home_n = v_away_n THEN
      PERFORM public.match_schedule_apply_dual_no_show_forfeit(
        v_row.fixture_id,
        format(
          'Open-play deadline %s · equal no-shows (%s-%s) · 0-0 + ₿1.5m each',
          p_closed_gpsl_month, v_home_n, v_away_n
        )
      );
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'fixture_id', v_row.fixture_id, 'outcome', 'dual', 'home_n', v_home_n, 'away_n', v_away_n
      ));
    ELSIF v_home_n > v_away_n THEN
      PERFORM public.fixture_apply_forfeit(
        v_row.fixture_id,
        v_home,
        'match_agreed_no_show',
        format(
          'open_play_deadline:%s:%s|More no-shows (%s vs %s) · assessed at %s lock',
          p_closed_gpsl_month, v_row.fixture_id, v_home_n, v_away_n, p_closed_gpsl_month
        )
      );
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'fixture_id', v_row.fixture_id, 'outcome', 'home_forfeit', 'home_n', v_home_n, 'away_n', v_away_n
      ));
    ELSE
      PERFORM public.fixture_apply_forfeit(
        v_row.fixture_id,
        v_away,
        'match_agreed_no_show',
        format(
          'open_play_deadline:%s:%s|More no-shows (%s vs %s) · assessed at %s lock',
          p_closed_gpsl_month, v_row.fixture_id, v_away_n, v_home_n, p_closed_gpsl_month
        )
      );
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'fixture_id', v_row.fixture_id, 'outcome', 'away_forfeit', 'home_n', v_home_n, 'away_n', v_away_n
      ));
    END IF;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'resolved', v_count,
    'results', v_results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_process_scheduling_checkin_fines(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_job_key text;
  v_res jsonb := NULL;
  v_open jsonb := NULL;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = p_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month, c.lock_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'scheduling_checkin_fines:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
    ) THEN
      -- Still run open-play resolver if that sub-job has not run
      NULL;
    ELSE
      v_res := public.competition_enforce_scheduling_checkin_fines(
        p_season_id,
        v_cal.gpsl_month
      );

      INSERT INTO public.competition_season_calendar_jobs (
        season_id, job_key, gpsl_month, result
      )
      VALUES (
        p_season_id,
        v_job_key,
        v_cal.gpsl_month,
        coalesce(v_res, '{}'::jsonb)
      )
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result,
            gpsl_month = excluded.gpsl_month,
            ran_at = now();
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = 'scheduling_open_play_noshow:' || v_cal.gpsl_month
    ) THEN
      v_open := public.competition_enforce_open_play_no_show_resolution(
        p_season_id,
        v_cal.gpsl_month
      );
      INSERT INTO public.competition_season_calendar_jobs (
        season_id, job_key, gpsl_month, result
      )
      VALUES (
        p_season_id,
        'scheduling_open_play_noshow:' || v_cal.gpsl_month,
        v_cal.gpsl_month,
        coalesce(v_open, '{}'::jsonb)
      )
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result,
            gpsl_month = excluded.gpsl_month,
            ran_at = now();
    ELSE
      v_open := NULL;
    END IF;

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_cal.gpsl_month,
        'checkin_fines', v_res,
        'open_play', v_open
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'processed', v_results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_no_show_ladder_json(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sched public.competition_fixture_schedule;
  v_fixture public.competition_fixtures;
  v_home_n int := 0;
  v_away_n int := 0;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  SELECT * INTO v_sched FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'play_attempt_count', 0,
      'ladder_active', false,
      'open_play_active', false
    );
  END IF;

  SELECT coalesce(sum(CASE WHEN e.club_short_name = v_fixture.home_club_short_name THEN 1 ELSE 0 END), 0)::int,
         coalesce(sum(CASE WHEN e.club_short_name = v_fixture.away_club_short_name THEN 1 ELSE 0 END), 0)::int
  INTO v_home_n, v_away_n
  FROM public.competition_fixture_no_show_events e
  WHERE e.fixture_id = p_fixture_id;

  RETURN jsonb_build_object(
    'play_attempt_count', coalesce(v_sched.play_attempt_count, 0),
    'ladder_active', (coalesce(v_sched.play_attempt_count, 0) >= 3 OR coalesce(v_sched.open_play_active, false)),
    'open_play_active', coalesce(v_sched.open_play_active, false),
    'open_play_deadline_gpsl_month', v_sched.open_play_deadline_gpsl_month,
    'home_no_show_count', v_home_n,
    'away_no_show_count', v_away_n,
    'no_show_club_short_name', v_sched.no_show_club_short_name
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_gpsl_month_plus(bigint, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_no_show_ladder_json(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_try_checkin_forfeit(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_checkin_fines(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_enforce_open_play_no_show_resolution(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_checkin_fines(bigint) TO service_role;


-- ---------------------------------------------------------------------------
-- Context: expose attempt / open-play ladder
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_context(p_fixture_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_schedule_found boolean := false;
  v_pending public.competition_fixture_schedule_proposal;
  v_override public.competition_fixture_mutual_override;
  v_role text;
  v_home text;
  v_away text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_prop_unlock timestamptz;
  v_prop_lock timestamptz;
  v_prop_month text;
  v_prop_catch_up boolean := false;
  v_prop_holiday_early boolean := false;
  v_is_catch_up boolean := false;
  v_is_holiday_early boolean := false;
  v_slots jsonb;
  v_status text;
  v_agreed timestamptz;
  v_home_count smallint;
  v_away_count smallint;
  v_discord_hint boolean;
  v_pending_id bigint;
  v_mutual_used boolean := false;
  v_kickoff timestamptz;
  v_home_in boolean := false;
  v_away_in boolean := false;
  v_my_in boolean := false;
  v_emergency_used integer;
  v_reschedule_used boolean;
  v_play_now_kickoff timestamptz;
  v_can_play_now boolean := false;
  v_can_mutual_new_time boolean := false;
  v_my_override_confirmed boolean := false;
  v_can_confirm_override boolean := false;
  v_can_cancel_override boolean := false;
  v_can_catch_up_reset boolean := false;
  v_can_replay_reset boolean := false;
  v_has_mgr boolean := false;
BEGIN
  PERFORM public.match_schedule_mutual_override_expire();
  v_club := public.my_club_shortname();
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixture not found'; END IF;
  IF NOT public.is_gpsl_admin()
     AND v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
  THEN RAISE EXCEPTION 'You are not in this fixture'; END IF;
  PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  v_is_catch_up := public.match_schedule_fixture_is_catch_up(p_fixture_id);
  IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL THEN
    v_is_holiday_early := public.match_schedule_fixture_is_holiday_early(p_fixture_id);
  END IF;
  v_home := v_fixture.home_club_short_name;
  v_away := v_fixture.away_club_short_name;
  IF v_club = v_home THEN v_role := 'home';
  ELSIF v_club = v_away THEN v_role := 'away';
  ELSE v_role := 'admin'; END IF;
  SELECT * INTO v_schedule FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
  v_schedule_found := FOUND;
  IF v_schedule_found THEN
    v_status := v_schedule.status;
    v_agreed := v_schedule.agreed_kickoff_at;
    v_home_count := v_schedule.home_proposal_count;
    v_away_count := v_schedule.away_proposal_count;
    v_discord_hint := v_schedule.discord_hint_shown;
    v_pending_id := v_schedule.pending_proposal_id;
    v_mutual_used := COALESCE(v_schedule.mutual_override_used, false);
  ELSE
    v_status := 'unscheduled'; v_agreed := NULL;
    v_home_count := 0; v_away_count := 0; v_discord_hint := false;
    v_pending_id := NULL; v_mutual_used := false;
  END IF;
  IF v_pending_id IS NOT NULL THEN
    SELECT * INTO v_pending FROM public.competition_fixture_schedule_proposal WHERE id = v_pending_id;
  END IF;
  SELECT * INTO v_override FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id AND status = 'pending' ORDER BY created_at DESC LIMIT 1;
  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up, w.is_holiday_early
  INTO v_prop_unlock, v_prop_lock, v_prop_month, v_prop_catch_up, v_prop_holiday_early
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;
  v_slots := public.match_schedule_club_weekly_slots_json(v_fixture.season_id, v_club);
  IF to_regprocedure('public.club_has_signed_manager(text)') IS NOT NULL THEN
    v_has_mgr := coalesce(public.club_has_signed_manager(v_club), false);
  ELSE
    v_has_mgr := true;
  END IF;
  v_kickoff := v_agreed;
  IF v_kickoff IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_home) INTO v_home_in;
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_away) INTO v_away_in;
    IF v_club IS NOT NULL THEN
      SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_club) INTO v_my_in;
    END IF;
  END IF;
  v_emergency_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  v_reschedule_used := public.match_schedule_reschedule_used_this_month(v_fixture.season_id, v_club, v_fixture.gpsl_month);
  IF v_is_catch_up AND v_fixture.status = 'scheduled' THEN
    v_can_catch_up_reset := v_status IN ('agreed', 'negotiating')
      AND (v_kickoff IS NULL OR v_kickoff < now() OR NOT public.match_schedule_kickoff_in_proposal_window(p_fixture_id, v_kickoff))
      AND v_override.id IS NULL;
  END IF;
  IF NOT v_is_catch_up
     AND v_fixture.status = 'scheduled'
     AND public.match_schedule_fixture_play_month_open(p_fixture_id)
     AND v_status = 'agreed'
     AND v_kickoff IS NOT NULL
     AND v_kickoff < now()
     AND v_override.id IS NULL
  THEN
    v_can_replay_reset := true;
  END IF;
  -- Play now: available on any future agreed KO (not gated by mutual_override_used).
  -- Free mutual new-time: one-shot per fixture (mutual_override_used).
  IF v_fixture.status = 'scheduled' AND v_status = 'agreed' AND v_agreed IS NOT NULL AND v_override.id IS NULL THEN
    BEGIN
      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      v_can_play_now := true;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := false; v_play_now_kickoff := NULL;
    END;
    v_can_mutual_new_time := (NOT v_mutual_used) AND now() < v_agreed;
  END IF;
  IF v_override.id IS NOT NULL AND v_club IS NOT NULL THEN
    IF v_club = v_home THEN v_my_override_confirmed := v_override.home_confirmed_at IS NOT NULL;
    ELSE v_my_override_confirmed := v_override.away_confirmed_at IS NOT NULL; END IF;
    v_can_confirm_override := NOT v_my_override_confirmed AND v_override.requested_by_club <> v_club;
    v_can_cancel_override := true; -- either club may decline / cancel a pending Discord lock
  END IF;
  RETURN jsonb_build_object(
    'fixture', jsonb_build_object('id', v_fixture.id, 'gpsl_month', v_fixture.gpsl_month, 'division', v_fixture.division, 'cup_code', v_fixture.cup_code, 'home_club_short_name', v_home, 'away_club_short_name', v_away, 'status', v_fixture.status, 'competition_type', v_fixture.competition_type, 'is_forfeit', v_fixture.is_forfeit, 'is_catch_up', v_is_catch_up, 'is_holiday_early', v_is_holiday_early),
    'schedule', jsonb_build_object('status', v_status, 'agreed_kickoff_at', v_agreed, 'home_proposal_count', v_home_count, 'away_proposal_count', v_away_count, 'discord_hint_shown', v_discord_hint, 'mutual_override_used', v_mutual_used, 'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END, 'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END, 'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END, 'play_attempt_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.play_attempt_count, 0) ELSE 0 END, 'open_play_active', CASE WHEN v_schedule_found THEN coalesce(v_schedule.open_play_active, false) ELSE false END, 'open_play_deadline_gpsl_month', CASE WHEN v_schedule_found THEN v_schedule.open_play_deadline_gpsl_month ELSE NULL END),
    'no_show_ladder', CASE WHEN to_regprocedure('public.match_schedule_no_show_ladder_json(bigint)') IS NOT NULL THEN public.match_schedule_no_show_ladder_json(p_fixture_id) ELSE NULL END,
    'pending_proposal', CASE WHEN v_pending.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_pending.id, 'proposed_by_club_short_name', v_pending.proposed_by_club_short_name, 'kickoff_at', v_pending.kickoff_at) END,
    'mutual_override', CASE WHEN v_override.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_override.id, 'kind', v_override.kind, 'proposed_kickoff_at', v_override.proposed_kickoff_at, 'requested_by_club_short_name', v_override.requested_by_club, 'expires_at', v_override.expires_at, 'my_confirmed', v_my_override_confirmed, 'can_confirm', v_can_confirm_override, 'can_cancel', v_can_cancel_override) END,
    'my_role', v_role, 'is_catch_up', v_is_catch_up, 'is_holiday_early', v_is_holiday_early,
    'my_has_manager', v_has_mgr,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'proposal_window', jsonb_build_object('unlock_at', v_prop_unlock, 'lock_at', v_prop_lock, 'gpsl_month', v_prop_month, 'is_catch_up', coalesce(v_prop_catch_up, false), 'is_holiday_early', coalesce(v_prop_holiday_early, false)),
    'my_timezone', public.match_schedule_club_timezone(v_club),
    'home_timezone', public.match_schedule_club_timezone(v_home),
    'away_timezone', public.match_schedule_club_timezone(v_away),
    'my_weekly_slots', v_slots,
    'my_window_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_club_window_slots(p_fixture_id, v_club) i),
    'intersection_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_intersection_slots(p_fixture_id) i),
    'manual_black_box', (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
      AND public.fixture_is_manual_black_box(p_fixture_id)
    ),
    'can_propose_first', (
      v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(p_fixture_id)
      )
    ),
    'can_respond', (
      v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club
      AND v_status = 'negotiating' AND v_has_mgr
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(p_fixture_id)
      )
    ),
    'response_deadline', public.match_schedule_response_deadline_json(p_fixture_id, v_club),
    'mutual_override_options', jsonb_build_object('can_request_play_now', v_can_play_now, 'play_now_kickoff_at', v_play_now_kickoff, 'can_request_new_time', v_can_mutual_new_time),
    'checkin', jsonb_build_object('home_checked_in', v_home_in, 'away_checked_in', v_away_in, 'my_checked_in', v_my_in, 'window_opens_at', public.match_schedule_checkin_opens_at(v_kickoff), 'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END, 'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END, 'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= public.match_schedule_checkin_opens_at(v_kickoff) AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in AND v_has_mgr), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval)),
    'allowances', jsonb_build_object('emergency_drops_used', v_emergency_used, 'emergency_drops_remaining', greatest(0, 2 - v_emergency_used), 'reschedule_used_this_month', v_reschedule_used, 'can_voluntary_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() <= v_kickoff - interval '24 hours' AND NOT v_reschedule_used AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_emergency_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() < v_kickoff AND now() > v_kickoff - interval '24 hours' AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_catch_up_reset', v_can_catch_up_reset, 'can_replay_reset', v_can_replay_reset)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_context(bigint) TO authenticated;
