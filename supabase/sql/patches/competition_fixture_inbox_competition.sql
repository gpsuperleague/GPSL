-- =============================================================================
-- Competition label on fixture inbox + scheduling messages
-- Run once. Safe to re-run (CREATE OR REPLACE).
-- Adds SuperLeague / Championship A / League Cup / Super8 etc. to titles & bodies.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_display_name(p_short text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT c."Club"
      FROM public."Clubs" c
      WHERE c."ShortName" = nullif(btrim(p_short), '')
      LIMIT 1
    ),
    nullif(btrim(p_short), '')
  );
$$;

-- ---------------------------------------------------------------------------
-- Labels (mirror competition.js DIVISION_LABELS + CUP_LABELS)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_fixture_competition_label(
  p_fixture public.competition_fixtures
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_fixture.competition_type = 'cup' OR p_fixture.cup_code IS NOT NULL THEN
      CASE p_fixture.cup_code
        WHEN 'super8' THEN 'Super8'
        WHEN 'plate' THEN 'Plate'
        WHEN 'shield' THEN 'Shield'
        WHEN 'bowl' THEN 'Bowl'
        WHEN 'league_cup' THEN 'League Cup'
        ELSE initcap(replace(coalesce(p_fixture.cup_code, 'cup'), '_', ' '))
      END
    WHEN p_fixture.division = 'superleague' THEN 'SuperLeague'
    WHEN p_fixture.division = 'championship_a' THEN 'Championship A'
    WHEN p_fixture.division = 'championship_b' THEN 'Championship B'
    WHEN p_fixture.division IS NOT NULL THEN initcap(replace(p_fixture.division, '_', ' '))
    ELSE 'League'
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_fixture_inbox_line(p_fixture_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home text;
  v_away text;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT c."Club" INTO v_home FROM public."Clubs" c WHERE c."ShortName" = v_fixture.home_club_short_name;
  SELECT c."Club" INTO v_away FROM public."Clubs" c WHERE c."ShortName" = v_fixture.away_club_short_name;

  RETURN public.competition_fixture_competition_label(v_fixture)
    || ' · '
    || coalesce(v_home, v_fixture.home_club_short_name)
    || ' vs '
    || coalesce(v_away, v_fixture.away_club_short_name);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_fixture_inbox_title(
  p_fixture_id bigint,
  p_title text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_label text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN p_title;
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN p_title;
  END IF;

  v_label := public.competition_fixture_competition_label(v_fixture);
  IF p_title ILIKE v_label || '%' OR p_title ILIKE '[' || v_label || ']%' THEN
    RETURN p_title;
  END IF;

  RETURN format('[%s] %s', v_label, p_title);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_fixture_inbox_body(
  p_fixture_id bigint,
  p_body text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_line text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN p_body;
  END IF;

  v_line := public.competition_fixture_inbox_line(p_fixture_id);
  IF v_line IS NULL OR v_line = '' THEN
    RETURN p_body;
  END IF;

  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RETURN v_line;
  END IF;

  IF left(p_body, length(v_line)) = v_line THEN
    RETURN p_body;
  END IF;

  RETURN v_line || E'\n' || p_body;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Central inbox wrappers (result confirm/submit/reject + scheduling)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_inbox_notify(
  p_recipient_club text,
  p_message_type text,
  p_fixture_id bigint,
  p_submission_id bigint,
  p_title text,
  p_body text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.owner_inbox_send(
    p_message_type,
    public.competition_fixture_inbox_title(p_fixture_id, p_title),
    public.competition_fixture_inbox_body(p_fixture_id, p_body),
    p_recipient_club,
    NULL,
    p_fixture_id,
    p_submission_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_notify_pair(
  p_fixture public.competition_fixtures,
  p_message_type text,
  p_title text,
  p_body text,
  p_proposal_id bigint,
  p_dedupe_suffix text
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
    p_fixture.home_club_short_name,
    NULL,
    p_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix || ':home',
    p_fixture.gpsl_month,
    p_fixture.season_id,
    p_proposal_id
  );

  PERFORM public.owner_inbox_send(
    p_message_type,
    v_title,
    v_body,
    p_fixture.away_club_short_name,
    NULL,
    p_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix || ':away',
    p_fixture.gpsl_month,
    p_fixture.season_id,
    p_proposal_id
  );
END;
$function$;

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

-- ---------------------------------------------------------------------------
-- Scheduling notifications (Phase 2 + 3) — use competition-aware wrapper
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_voluntary_reschedule_drop(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_opponent text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open for reschedule';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'No agreed kick-off to drop';
  END IF;

  IF now() > v_kickoff - interval '24 hours' THEN
    RAISE EXCEPTION 'Within 24 hours of kick-off — use emergency drop instead';
  END IF;

  IF public.match_schedule_reschedule_used_this_month(
    v_fixture.season_id, v_club, v_fixture.gpsl_month
  ) THEN
    RAISE EXCEPTION 'You have already used your reschedule allowance for GPSL %',
      public.competition_gpsl_month_label(v_fixture.gpsl_month);
  END IF;

  INSERT INTO public.competition_club_month_reschedule_use (
    season_id, club_short_name, gpsl_month, fixture_id
  )
  VALUES (v_fixture.season_id, v_club, v_fixture.gpsl_month, p_fixture_id);

  PERFORM public.match_schedule_reset_to_unscheduled(p_fixture_id);

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_rescheduled',
    'Match returned to scheduling',
    public.club_display_name(v_club) || ' dropped the agreed time (24h+ notice). Propose a new kick-off on the schedule page.',
    v_opponent,
    'reschedule:' || p_fixture_id::text || ':' || v_club
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_emergency_drop(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_opponent text;
  v_used integer;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'No agreed kick-off';
  END IF;

  IF now() <= v_kickoff - interval '24 hours' THEN
    RAISE EXCEPTION 'More than 24 hours before kick-off — use voluntary drop instead';
  END IF;

  IF now() >= v_kickoff THEN
    RAISE EXCEPTION 'Kick-off has passed';
  END IF;

  v_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  IF v_used >= 2 THEN
    RAISE EXCEPTION 'No emergency drops remaining this season';
  END IF;

  INSERT INTO public.competition_club_emergency_drop_use (
    season_id, club_short_name, fixture_id
  )
  VALUES (v_fixture.season_id, v_club, p_fixture_id);

  PERFORM public.match_schedule_reset_to_unscheduled(p_fixture_id);

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_emergency_drop',
    'Emergency drop — reschedule needed',
    public.club_display_name(v_club) || ' used an emergency drop (<24h). The match is back on the schedule page.',
    v_opponent,
    'emergency:' || p_fixture_id::text || ':' || v_club
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_apply_forfeit(
  p_fixture_id bigint,
  p_loser_club text,
  p_tariff_code text,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_goals smallint;
  v_away_goals smallint;
  v_winner text;
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status = 'played' THEN
    RETURN;
  END IF;

  IF p_loser_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Loser must be a club in this fixture';
  END IF;

  v_winner := CASE
    WHEN p_loser_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
    ELSE v_fixture.home_club_short_name
  END;

  IF v_winner = v_fixture.home_club_short_name THEN
    v_home_goals := 3;
    v_away_goals := 0;
  ELSE
    v_home_goals := 0;
    v_away_goals := 3;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by forfeit',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixtures
  SET
    home_goals = v_home_goals,
    away_goals = v_away_goals,
    status = 'played',
    is_forfeit = true,
    forfeit_loser_club = p_loser_club
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_fine_tariff(
    p_loser_club,
    p_tariff_code,
    NULL,
    coalesce(p_reason, 'Match forfeit'),
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

  v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Match forfeited');
  v_body := public.competition_fixture_inbox_body(
    p_fixture_id,
    format('%s forfeited 3–0. %s', public.club_display_name(p_loser_club), coalesce(p_reason, ''))
  );

  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.home_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'forfeit:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.away_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'forfeit:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
END;
$function$;

-- Result submitted trigger (owner_inbox path)
CREATE OR REPLACE FUNCTION public.trg_result_submission_notify_submitter()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_name text;
  v_away_name text;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = NEW.fixture_id;
  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  PERFORM public.owner_inbox_send(
    'result_submitted',
    public.competition_fixture_inbox_title(
      NEW.fixture_id,
      format('Result submitted: %s vs %s', v_home_name, v_away_name)
    ),
    public.competition_fixture_inbox_body(
      NEW.fixture_id,
      format(
        E'You submitted %s %s–%s %s.\nWaiting for your opponent to confirm or reject.',
        v_home_name, NEW.home_goals, NEW.away_goals, v_away_name
      )
    ),
    NEW.submitted_by_club,
    NULL,
    NEW.fixture_id,
    NEW.id,
    NULL, NULL,
    'matchday.html?fixture=' || NEW.fixture_id::text,
    'result_submitted:' || NEW.id::text,
    v_fixture.gpsl_month,
    v_fixture.season_id
  );

  RETURN NEW;
END;
$function$;

NOTIFY pgrst, 'reload schema';
