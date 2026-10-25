-- =============================================================================
-- No-show strikes + attempts v2 (2026-10-25)
-- =============================================================================
-- Replaces the earlier attempt-3 ladder (warn / open-play dual forfeit).
--
-- Attempts (GPSL / Discord lanes; not manual black-box):
--   1 = first agreed KO
--   2 = rearrange or after a no-show from 1
--   3 = further rearrange / no-show from 2; play window = original month + 2
--       (clamped to season final month); unlimited rearranges; Play now OK
--
-- One-sided no-show (instant 窶・no month-lock wait):
--   1st on fixture 竊・竄ｿ500k + season strike
--   2nd 竊・竄ｿ1.0m + strike
--   3rd 竊・竄ｿ1.5m + strike + instant 0窶・ (offender loses; forfeit tariff 竄ｿ0)
-- Both miss 竊・each 竄ｿ500k + 1 strike; pick new time; attempt bumps
-- Season strikes: every 3rd (3/6/9窶ｦ) 竊・extra 竄ｿ2.5m
-- Attempt 3 window end unplayed 竊・fewer fixture no-shows wins; tie 竊・activity
-- Manual black-box month-lock mutual forfeit unchanged.
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
  play_attempt_no integer NOT NULL DEFAULT 1,
  action text NOT NULL DEFAULT 'fine',
  both_miss boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT competition_fixture_no_show_events_uniq
    UNIQUE (fixture_id, club_short_name, kickoff_at)
);

ALTER TABLE public.competition_fixture_no_show_events
  ADD COLUMN IF NOT EXISTS both_miss boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS competition_fixture_no_show_events_fixture_idx
  ON public.competition_fixture_no_show_events (fixture_id);

CREATE TABLE IF NOT EXISTS public.competition_owner_season_strikes (
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  owner_id uuid NOT NULL,
  strike_count integer NOT NULL DEFAULT 0 CHECK (strike_count >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, owner_id)
);

UPDATE public.competition_fixture_schedule
SET play_attempt_count = 1
WHERE agreed_kickoff_at IS NOT NULL
  AND coalesce(play_attempt_count, 0) = 0;

-- ---------------------------------------------------------------------------
-- Tariffs
-- ---------------------------------------------------------------------------
INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES
  ('match_no_show_1', 'No-show (1st on fixture)', 'matchday', 'fine', 500000, 'fixed', 70, true),
  ('match_no_show_2', 'No-show (2nd on fixture)', 'matchday', 'fine', 1000000, 'fixed', 71, true),
  ('match_no_show_3', 'No-show (3rd on fixture)', 'matchday', 'fine', 1500000, 'fixed', 72, true),
  ('match_no_show_strike_triple', 'No-show season strike (every 3rd)', 'matchday', 'fine', 2500000, 'fixed', 73, true),
  ('match_no_show_fixture_forfeit', 'No-show fixture forfeit (3 misses)', 'matchday', 'fine', 0, 'fixed', 74, true)
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
     AND position('''match_noshow_fine''' IN v_def) > 0
     AND position('''match_noshow_strike_triple''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t FROM public.competition_inbox WHERE message_type IS NOT NULL
    UNION SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'match_noshow_recorded'
    UNION SELECT 'match_noshow_warning'
    UNION SELECT 'match_noshow_repeat_fine'
    UNION SELECT 'match_noshow_open_play'
    UNION SELECT 'match_noshow_open_play_resolved'
    UNION SELECT 'match_noshow_fine'
    UNION SELECT 'match_noshow_both_miss'
    UNION SELECT 'match_noshow_strike_triple'
    UNION SELECT 'match_noshow_fixture_forfeit'
    UNION SELECT 'match_attempt3_window'
    UNION SELECT 'match_attempt3_awarded'
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
  SELECT c.gpsl_month INTO v_month
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND public.competition_gpsl_month_sort(c.gpsl_month) = v_base_sort + p_ahead
  LIMIT 1;
  IF v_month IS NOT NULL THEN
    RETURN v_month;
  END IF;
  SELECT c.gpsl_month INTO v_month
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
  ORDER BY public.competition_gpsl_month_sort(c.gpsl_month) DESC
  LIMIT 1;
  RETURN v_month;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_club_owner_id(p_club_short_name text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT c.owner_id
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_add_season_strike(
  p_season_id bigint,
  p_owner_id uuid,
  p_fixture_id bigint,
  p_club_short_name text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer;
  v_href text;
BEGIN
  IF p_season_id IS NULL OR p_owner_id IS NULL THEN
    RETURN 0;
  END IF;

  INSERT INTO public.competition_owner_season_strikes (season_id, owner_id, strike_count, updated_at)
  VALUES (p_season_id, p_owner_id, 1, now())
  ON CONFLICT (season_id, owner_id) DO UPDATE
    SET strike_count = public.competition_owner_season_strikes.strike_count + 1,
        updated_at = now()
  RETURNING strike_count INTO v_count;

  IF v_count > 0 AND v_count % 3 = 0 THEN
    PERFORM public.competition_apply_club_fine_tariff(
      p_club_short_name,
      'match_no_show_strike_triple',
      NULL,
      format('Season no-show strike #%s', v_count),
      p_fixture_id,
      p_season_id
    );
    v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;
    PERFORM public.owner_inbox_send(
      'match_noshow_strike_triple',
      'Season strike ' || v_count::text || ' 窶・竄ｿ2.5m',
      'You reached season no-show strike #' || v_count::text
        || '. Extra fine: 竄ｿ2.5m. Strikes continue for the season (next extras at 6, 9, 窶ｦ).',
      p_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'strike3:' || p_season_id::text || ':' || p_owner_id::text || ':' || v_count::text,
      NULL, p_season_id, NULL
    );
  END IF;

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_bump_attempt_on_noshow(p_fixture_id bigint)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_attempt integer;
  v_deadline text;
  v_href text;
  v_was integer;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT coalesce(play_attempt_count, 0) INTO v_was
  FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;

  v_attempt := least(3, greatest(v_was, 1) + 1);

  UPDATE public.competition_fixture_schedule
  SET
    play_attempt_count = v_attempt,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  IF v_attempt >= 3 THEN
    v_deadline := public.match_schedule_gpsl_month_plus(
      v_fixture.season_id, v_fixture.gpsl_month, 2
    );
    UPDATE public.competition_fixture_schedule s
    SET
      open_play_active = true,
      open_play_started_at = coalesce(s.open_play_started_at, now()),
      open_play_deadline_gpsl_month = coalesce(s.open_play_deadline_gpsl_month, v_deadline),
      updated_at = now()
    WHERE s.fixture_id = p_fixture_id
      AND coalesce(s.open_play_active, false) = false
    RETURNING s.open_play_deadline_gpsl_month INTO v_deadline;

    IF v_deadline IS NOT NULL AND v_was < 3 THEN
      v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;
      PERFORM public.owner_inbox_send(
        'match_attempt3_window',
        'Attempt 3 window opened',
        'This fixture is on attempt 3. You may rearrange as needed through '
          || coalesce(public.competition_gpsl_month_label(v_deadline), v_deadline)
          || ' (original play month + up to 2 GPSL months, or season end). '
          || 'Play now remains available when a kick-off is locked. '
          || 'No-show fines and season strikes still apply. '
          || 'If still unplayed at that lock, the club with fewer no-shows is awarded the match (activity tie-break if equal).',
        v_fixture.home_club_short_name,
        NULL, p_fixture_id, NULL, NULL, NULL, v_href,
        'attempt3:' || p_fixture_id::text || ':home',
        v_fixture.gpsl_month, v_fixture.season_id, NULL
      );
      PERFORM public.owner_inbox_send(
        'match_attempt3_window',
        'Attempt 3 window opened',
        'This fixture is on attempt 3. You may rearrange as needed through '
          || coalesce(public.competition_gpsl_month_label(v_deadline), v_deadline)
          || ' (original play month + up to 2 GPSL months, or season end). '
          || 'Play now remains available when a kick-off is locked. '
          || 'No-show fines and season strikes still apply. '
          || 'If still unplayed at that lock, the club with fewer no-shows is awarded the match (activity tie-break if equal).',
        v_fixture.away_club_short_name,
        NULL, p_fixture_id, NULL, NULL, NULL, v_href,
        'attempt3:' || p_fixture_id::text || ':away',
        v_fixture.gpsl_month, v_fixture.season_id, NULL
      );
    END IF;
  END IF;

  RETURN v_attempt;
END;
$function$;

-- First agree 竊・attempt 1; later KO changes advance 1竊・竊・ (rearranges)
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
     AND OLD.agreed_kickoff_at IS NOT NULL
     AND NEW.agreed_kickoff_at IS DISTINCT FROM OLD.agreed_kickoff_at THEN
    IF coalesce(OLD.play_attempt_count, 0) <= 1 THEN
      NEW.play_attempt_count := 2;
    ELSIF coalesce(OLD.play_attempt_count, 0) = 2 THEN
      NEW.play_attempt_count := 3;
    ELSE
      NEW.play_attempt_count := greatest(coalesce(OLD.play_attempt_count, 0), 3);
    END IF;
  ELSIF NEW.agreed_kickoff_at IS NOT NULL
        AND OLD.agreed_kickoff_at IS NULL
        AND coalesce(NEW.play_attempt_count, 0) = 0 THEN
    NEW.play_attempt_count := 1;
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

CREATE OR REPLACE FUNCTION public.match_schedule_ensure_attempt3_window_on_ko()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_deadline text;
BEGIN
  IF NEW.play_attempt_count < 3 OR coalesce(NEW.open_play_active, false) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = NEW.fixture_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_deadline := public.match_schedule_gpsl_month_plus(
    v_fixture.season_id, v_fixture.gpsl_month, 2
  );
  NEW.open_play_active := true;
  NEW.open_play_started_at := coalesce(NEW.open_play_started_at, now());
  NEW.open_play_deadline_gpsl_month := coalesce(NEW.open_play_deadline_gpsl_month, v_deadline);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS competition_fixture_schedule_attempt3_window_trg
  ON public.competition_fixture_schedule;
CREATE TRIGGER competition_fixture_schedule_attempt3_window_trg
  BEFORE UPDATE OF play_attempt_count
  ON public.competition_fixture_schedule
  FOR EACH ROW
  WHEN (NEW.play_attempt_count >= 3 AND coalesce(OLD.play_attempt_count, 0) < 3)
  EXECUTE FUNCTION public.match_schedule_ensure_attempt3_window_on_ko();

CREATE OR REPLACE FUNCTION public.match_schedule_apply_club_noshow(
  p_fixture_id bigint,
  p_club text,
  p_kickoff timestamptz,
  p_attempt integer,
  p_both_miss boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_owner uuid;
  v_prior integer;
  v_n integer;
  v_tariff text;
  v_amount_label text;
  v_rows integer := 0;
  v_strikes integer := 0;
  v_href text;
  v_fmt text;
  v_forfeited boolean := false;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_scheduled');
  END IF;

  -- Manual black-box: do not use GPSL no-show ladder
  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manual_black_box');
  END IF;

  INSERT INTO public.competition_fixture_no_show_events (
    fixture_id, club_short_name, kickoff_at, play_attempt_no, action, both_miss
  )
  VALUES (
    p_fixture_id, p_club, p_kickoff, greatest(p_attempt, 1), 'fine', coalesce(p_both_miss, false)
  )
  ON CONFLICT (fixture_id, club_short_name, kickoff_at) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN jsonb_build_object('ok', true, 'deduped', true);
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.competition_fixture_no_show_events e
  WHERE e.fixture_id = p_fixture_id AND e.club_short_name = p_club;

  v_tariff := CASE
    WHEN v_n <= 1 THEN 'match_no_show_1'
    WHEN v_n = 2 THEN 'match_no_show_2'
    ELSE 'match_no_show_3'
  END;
  v_amount_label := CASE
    WHEN v_n <= 1 THEN '竄ｿ500k'
    WHEN v_n = 2 THEN '竄ｿ1m'
    ELSE '竄ｿ1.5m'
  END;

  PERFORM public.competition_apply_club_fine_tariff(
    p_club, v_tariff, NULL,
    format('Fixture no-show #%s at attempt %s', v_n, p_attempt),
    p_fixture_id, v_fixture.season_id
  );

  v_owner := public.match_schedule_club_owner_id(p_club);
  v_strikes := public.match_schedule_add_season_strike(
    v_fixture.season_id, v_owner, p_fixture_id, p_club
  );

  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff);
  v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;

  PERFORM public.owner_inbox_send(
    CASE WHEN p_both_miss THEN 'match_noshow_both_miss' ELSE 'match_noshow_fine' END,
    'No-show fine ' || v_amount_label,
    coalesce(public.club_display_name(p_club), p_club)
      || CASE WHEN p_both_miss THEN ' 窶・both clubs missed check-in at '
              ELSE ' did not check in at ' END
      || v_fmt
      || '. Fine: ' || v_amount_label
      || ' (no-show #' || v_n::text || ' on this fixture). Season strikes: '
      || v_strikes::text || '.',
    p_club,
    NULL, p_fixture_id, NULL, NULL, NULL, v_href,
    'noshowfine:' || p_fixture_id::text || ':' || p_club || ':' || p_kickoff::text,
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );

  IF v_n >= 3 AND NOT p_both_miss THEN
    PERFORM public.fixture_apply_forfeit(
      p_fixture_id,
      p_club,
      'match_no_show_fixture_forfeit',
      format('Third no-show on fixture ﾂｷ %s', v_fmt)
    );
    v_forfeited := true;
    PERFORM public.owner_inbox_send(
      'match_noshow_fixture_forfeit',
      'Third no-show 窶・match forfeited 0窶・',
      coalesce(public.club_display_name(p_club), p_club)
        || ' reached 3 no-shows on this fixture. Result: 0窶・ forfeit.',
      v_fixture.home_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow3ff:' || p_fixture_id::text || ':home',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
    PERFORM public.owner_inbox_send(
      'match_noshow_fixture_forfeit',
      'Third no-show 窶・match forfeited 0窶・',
      coalesce(public.club_display_name(p_club), p_club)
        || ' reached 3 no-shows on this fixture. Result: 0窶・ forfeit.',
      v_fixture.away_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'noshow3ff:' || p_fixture_id::text || ':away',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_no_show_n', v_n,
    'season_strikes', v_strikes,
    'forfeited', v_forfeited,
    'tariff', v_tariff
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Check-in window 竊・record no-shows
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
  v_attempt integer := 1;
  v_manual boolean := false;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  PERFORM public.match_schedule_clear_no_show_if_played(p_fixture_id);

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL THEN
    v_manual := public.fixture_is_manual_black_box(p_fixture_id);
  END IF;

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
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;
  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  -- Manual black-box: no GPSL check-in ladder (result entry anytime)
  IF v_manual THEN
    RETURN false;
  END IF;

  SELECT coalesce(s.play_attempt_count, 1) INTO v_attempt
  FROM public.competition_fixture_schedule s WHERE s.fixture_id = p_fixture_id;
  IF v_attempt < 1 THEN v_attempt := 1; END IF;

  IF NOT v_home_in AND NOT v_away_in THEN
    PERFORM public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.home_club_short_name, v_kickoff, v_attempt, true
    );
    PERFORM public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.away_club_short_name, v_kickoff, v_attempt, true
    );
    PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    -- Clear KO so they must pick a new time
    UPDATE public.competition_fixture_schedule
    SET agreed_kickoff_at = NULL,
        status = CASE WHEN status = 'agreed' THEN 'unscheduled' ELSE status END,
        updated_at = now()
    WHERE fixture_id = p_fixture_id;
    DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;
    RETURN true;
  END IF;

  IF v_home_in AND NOT v_away_in THEN
    v_loser := v_fixture.away_club_short_name;
    v_winner := v_fixture.home_club_short_name;
  ELSE
    v_loser := v_fixture.home_club_short_name;
    v_winner := v_fixture.away_club_short_name;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET no_show_club_short_name = v_loser,
      no_show_kickoff_at = v_kickoff,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  PERFORM public.match_schedule_apply_club_noshow(
    p_fixture_id, v_loser, v_kickoff, v_attempt, false
  );

  -- If not forfeited by 3rd miss, bump attempt for rearrange
  IF EXISTS (
    SELECT 1 FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id AND f.status = 'scheduled'
  ) THEN
    PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
  END IF;

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Disable deferred month-lock no-show 3-0 for GPSL-arranged fixtures
-- (manual mutual forfeit stays on its own job)
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
BEGIN
  -- GPSL no-shows are fined/forfeited instantly at check-in close.
  -- Keep function for month-lock job compatibility.
  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'forfeits_applied', 0,
    'skipped', 0,
    'note', 'deferred_noshow_forfeit_disabled_v2'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Attempt-3 window end award
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_enforce_attempt3_window_awards(
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
  v_closed_sort integer;
  v_home text;
  v_away text;
  v_home_n integer;
  v_away_n integer;
  v_loser text;
  v_results jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_href text;
BEGIN
  SELECT c.lock_at INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND c.gpsl_month = p_closed_gpsl_month;
  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'month_not_closed');
  END IF;

  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);

  FOR v_row IN
    SELECT f.id AS fixture_id,
           f.home_club_short_name,
           f.away_club_short_name,
           f.matchday,
           f.gpsl_month,
           s.open_play_deadline_gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = p_season_id
      AND f.status = 'scheduled'
      AND coalesce(s.play_attempt_count, 0) >= 3
      AND coalesce(s.open_play_active, false) = true
      AND s.open_play_deadline_gpsl_month IS NOT NULL
      AND public.competition_gpsl_month_sort(s.open_play_deadline_gpsl_month) <= v_closed_sort
      AND (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NULL
        OR NOT public.fixture_is_manual_black_box(f.id)
      )
  LOOP
    v_home := v_row.home_club_short_name;
    v_away := v_row.away_club_short_name;

    SELECT coalesce(sum(CASE WHEN e.club_short_name = v_home THEN 1 ELSE 0 END), 0)::int,
           coalesce(sum(CASE WHEN e.club_short_name = v_away THEN 1 ELSE 0 END), 0)::int
    INTO v_home_n, v_away_n
    FROM public.competition_fixture_no_show_events e
    WHERE e.fixture_id = v_row.fixture_id;

    v_href := 'fixture_schedule.html?fixture=' || v_row.fixture_id::text;

    IF v_home_n < v_away_n THEN
      v_loser := v_away;
    ELSIF v_away_n < v_home_n THEN
      v_loser := v_home;
    ELSE
      -- Equal no-shows 竊・existing activity ladder (loser = lower activity)
      IF to_regprocedure('public.match_schedule_pick_window_loser(bigint,bigint,text)') IS NOT NULL THEN
        v_loser := public.match_schedule_pick_window_loser(
          p_season_id, v_row.fixture_id, p_closed_gpsl_month
        );
      ELSE
        v_loser := NULL;
      END IF;
    END IF;

    IF v_loser IS NULL THEN
      IF to_regprocedure('public.fixture_apply_score_draw_0_0(bigint,text)') IS NOT NULL THEN
        PERFORM public.fixture_apply_score_draw_0_0(
          v_row.fixture_id,
          format(
            'Attempt 3 window ended ﾂｷ equal no-shows (%s-%s) ﾂｷ activity tied 竊・0窶・',
            v_home_n, v_away_n
          )
        );
      ELSE
        UPDATE public.competition_fixtures
        SET home_goals = 0, away_goals = 0, status = 'played', is_forfeit = false
        WHERE id = v_row.fixture_id;
      END IF;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'fixture_id', v_row.fixture_id, 'outcome', 'draw', 'home_n', v_home_n, 'away_n', v_away_n
      ));
    ELSE
      PERFORM public.fixture_apply_forfeit(
        v_row.fixture_id,
        v_loser,
        'match_window_expiry',
        format(
          'attempt3_window:%s:%s|Fewer no-shows / activity ﾂｷ %s vs %s',
          p_closed_gpsl_month, v_row.fixture_id, v_home_n, v_away_n
        )
      );
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'fixture_id', v_row.fixture_id, 'outcome', 'forfeit', 'loser', v_loser,
        'home_n', v_home_n, 'away_n', v_away_n
      ));
    END IF;

    PERFORM public.owner_inbox_send(
      'match_attempt3_awarded',
      'Attempt 3 window ended 窶・result awarded',
      'The attempt 3 arrange/play window closed with the match still unplayed. Result awarded by no-show count / GPSL activity.',
      v_home, NULL, v_row.fixture_id, NULL, NULL, NULL, v_href,
      'attempt3award:' || v_row.fixture_id::text || ':home',
      v_row.gpsl_month, p_season_id, NULL
    );
    PERFORM public.owner_inbox_send(
      'match_attempt3_awarded',
      'Attempt 3 window ended 窶・result awarded',
      'The attempt 3 arrange/play window closed with the match still unplayed. Result awarded by no-show count / GPSL activity.',
      v_away, NULL, v_row.fixture_id, NULL, NULL, NULL, v_href,
      'attempt3award:' || v_row.fixture_id::text || ':away',
      v_row.gpsl_month, p_season_id, NULL
    );

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
  v_a3 jsonb := NULL;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c WHERE c.season_id = p_season_id
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
    IF NOT EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id AND j.job_key = v_job_key
    ) THEN
      v_res := public.competition_enforce_scheduling_checkin_fines(p_season_id, v_cal.gpsl_month);
      INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
      VALUES (p_season_id, v_job_key, v_cal.gpsl_month, coalesce(v_res, '{}'::jsonb))
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = 'scheduling_attempt3_window:' || v_cal.gpsl_month
    ) THEN
      v_a3 := public.competition_enforce_attempt3_window_awards(p_season_id, v_cal.gpsl_month);
      INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
      VALUES (
        p_season_id,
        'scheduling_attempt3_window:' || v_cal.gpsl_month,
        v_cal.gpsl_month,
        coalesce(v_a3, '{}'::jsonb)
      )
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();
    ELSE
      v_a3 := NULL;
    END IF;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'gpsl_month', v_cal.gpsl_month,
      'checkin_fines', v_res,
      'attempt3_window', v_a3
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'processed', v_results);
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
  v_home_owner uuid;
  v_away_owner uuid;
  v_home_strikes int := 0;
  v_away_strikes int := 0;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  SELECT * INTO v_sched FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('play_attempt_count', 0, 'ladder_active', false);
  END IF;

  SELECT coalesce(sum(CASE WHEN e.club_short_name = v_fixture.home_club_short_name THEN 1 ELSE 0 END), 0)::int,
         coalesce(sum(CASE WHEN e.club_short_name = v_fixture.away_club_short_name THEN 1 ELSE 0 END), 0)::int
  INTO v_home_n, v_away_n
  FROM public.competition_fixture_no_show_events e
  WHERE e.fixture_id = p_fixture_id;

  v_home_owner := public.match_schedule_club_owner_id(v_fixture.home_club_short_name);
  v_away_owner := public.match_schedule_club_owner_id(v_fixture.away_club_short_name);

  SELECT coalesce(s.strike_count, 0) INTO v_home_strikes
  FROM public.competition_owner_season_strikes s
  WHERE s.season_id = v_fixture.season_id AND s.owner_id = v_home_owner;
  SELECT coalesce(s.strike_count, 0) INTO v_away_strikes
  FROM public.competition_owner_season_strikes s
  WHERE s.season_id = v_fixture.season_id AND s.owner_id = v_away_owner;

  RETURN jsonb_build_object(
    'play_attempt_count', coalesce(v_sched.play_attempt_count, 0),
    'ladder_active', coalesce(v_sched.play_attempt_count, 0) >= 1,
    'attempt3_active', coalesce(v_sched.play_attempt_count, 0) >= 3 OR coalesce(v_sched.open_play_active, false),
    'open_play_active', coalesce(v_sched.open_play_active, false),
    'open_play_deadline_gpsl_month', v_sched.open_play_deadline_gpsl_month,
    'home_no_show_count', v_home_n,
    'away_no_show_count', v_away_n,
    'home_season_strikes', coalesce(v_home_strikes, 0),
    'away_season_strikes', coalesce(v_away_strikes, 0),
    'no_show_club_short_name', v_sched.no_show_club_short_name
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_gpsl_month_plus(bigint, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_no_show_ladder_json(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_try_checkin_forfeit(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_checkin_fines(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_enforce_attempt3_window_awards(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_checkin_fines(bigint) TO service_role;
