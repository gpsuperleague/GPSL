-- =============================================================================
-- Owner match guidance (2026-10-04)
--
-- 1. Inbox types used by scheduling / squad warnings are allowed.
-- 2. match_schedule_fixture_deadlines(fixture)  → propose-by, month lock,
--    last play lock (for the Schedule page).
-- 3. owner_upcoming_arrangements()              → my next-month fixtures that
--    still need arranging (Dashboard "Arrange now" block).
-- 4. my_next_fixture_squad_check()              → is my saved squad valid for
--    my next fixture (Match Day squad tab).
-- 5. matchday_squad_issues_for_club(club, fix)  → club-scoped squad check
--    (cron-safe version of club_matchday_checkin_ready).
-- 6. match_owner_guidance_reminders()           → hourly cron:
--      · home "propose kick-off" reminders: ≤5 days, ≤60h (just before the
--        ₿2.5m late fee) and once the late fee applies
--      · "reply deadline soon" (≤12h)
--      · saved squad not valid for an agreed kick-off in the next 48h
-- 7. Check-in open messages say the saved squad is checked at check-in.
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Inbox message types (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(v_def, '''([^'']+)''', 'g'))[1]
    UNION
    SELECT unnest(ARRAY[
      'match_arrangement_deadline_warning',
      'match_response_deadline_warning',
      'match_window_draw',
      'matchday_squad_warning'
    ])
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Inbox helper: 14-arg owner_inbox_send with 13-arg fallback
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_guidance_inbox(
  p_type text,
  p_title text,
  p_body text,
  p_club text,
  p_fixture_id bigint,
  p_href text,
  p_dedupe text,
  p_gpsl_month text,
  p_season_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  BEGIN
    v_id := public.owner_inbox_send(
      p_type, p_title, p_body, p_club, NULL::uuid, p_fixture_id,
      NULL::bigint, NULL::bigint, NULL::bigint,
      p_href, p_dedupe, p_gpsl_month, p_season_id, NULL::bigint
    );
  EXCEPTION WHEN undefined_function THEN
    v_id := public.owner_inbox_send(
      p_type, p_title, p_body, p_club, NULL::uuid, p_fixture_id,
      NULL::bigint, NULL::bigint, NULL::bigint,
      p_href, p_dedupe, p_gpsl_month, p_season_id
    );
  END;
  RETURN v_id;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'match guidance inbox (% → %) skipped: %', p_type, p_club, SQLERRM;
  RETURN NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Deadlines for one fixture
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_deadlines(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play_unlock timestamptz;
  v_play_lock timestamptz;
  v_play_sort int;
  v_grace int;
  v_final_lock timestamptz;
  v_final_month text;
  v_agreed boolean;
  v_home_proposed boolean := false;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  SELECT cal.unlock_at, cal.lock_at
  INTO v_play_unlock, v_play_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id
    AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_f.gpsl_month));

  v_play_sort := public.competition_gpsl_month_sort(v_f.gpsl_month);
  v_grace := public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month);

  SELECT cal.lock_at, cal.gpsl_month
  INTO v_final_lock, v_final_month
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id
    AND public.competition_gpsl_month_sort(cal.gpsl_month) <= v_play_sort + v_grace
  ORDER BY public.competition_gpsl_month_sort(cal.gpsl_month) DESC
  LIMIT 1;

  v_agreed := EXISTS (
    SELECT 1 FROM public.competition_fixture_schedule s
    WHERE s.fixture_id = p_fixture_id AND s.status = 'agreed'
  );

  BEGIN
    v_home_proposed := public.match_schedule_home_has_proposed(p_fixture_id, now());
  EXCEPTION WHEN OTHERS THEN
    v_home_proposed := EXISTS (
      SELECT 1 FROM public.competition_fixture_schedule_proposal p
      WHERE p.fixture_id = p_fixture_id
        AND p.proposed_by_club_short_name = v_f.home_club_short_name
    );
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'gpsl_month', v_f.gpsl_month,
    'propose_by', v_play_unlock,
    'late_fee_from', v_play_unlock - interval '48 hours',
    'play_month_lock', v_play_lock,
    'final_play_lock', v_final_lock,
    'final_play_month', v_final_month,
    'grace_months', v_grace,
    'home_has_proposed', v_home_proposed,
    'agreed', v_agreed
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_deadlines(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. My fixtures in upcoming GPSL months that still need arranging
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_upcoming_arrangements()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint;
  v_out jsonb := '[]'::jsonb;
  r record;
  v_side text;
  v_state text;
  v_home_proposed boolean;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'fixtures', '[]'::jsonb);
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'fixtures', '[]'::jsonb);
  END IF;

  FOR r IN
    SELECT
      f.id, f.gpsl_month, f.matchday, f.competition_type, f.cup_code, f.cup_round,
      f.home_club_short_name, f.away_club_short_name,
      cal.unlock_at,
      s.status AS sched_status,
      s.response_required_club_short_name AS reply_club,
      s.response_due_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '15 days'
      AND coalesce(s.status, 'unscheduled') <> 'agreed'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
    ORDER BY cal.unlock_at, f.competition_type DESC, f.matchday, f.cup_round, f.id
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    BEGIN
      v_home_proposed := public.match_schedule_home_has_proposed(r.id, now());
    EXCEPTION WHEN OTHERS THEN
      v_home_proposed := coalesce(r.sched_status, 'unscheduled') <> 'unscheduled';
    END;

    v_state := CASE
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating'
           AND upper(btrim(coalesce(r.reply_club, ''))) = v_club THEN 'reply'
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating' THEN 'waiting'
      WHEN v_side = 'home' AND NOT v_home_proposed THEN 'propose'
      ELSE 'waiting_home'
    END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'fixture_id', r.id,
      'side', v_side,
      'opponent_short_name', CASE WHEN v_side = 'home'
        THEN upper(btrim(r.away_club_short_name)) ELSE upper(btrim(r.home_club_short_name)) END,
      'gpsl_month', r.gpsl_month,
      'matchday', r.matchday,
      'competition_type', r.competition_type,
      'cup_code', r.cup_code,
      'cup_round', r.cup_round,
      'propose_by', r.unlock_at,
      'late_fee_from', r.unlock_at - interval '48 hours',
      'response_due_at', r.response_due_at,
      'state', v_state
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'club_short_name', v_club, 'fixtures', v_out);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_upcoming_arrangements() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Club-scoped squad check (same rules as club_matchday_checkin_ready)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.matchday_squad_issues_for_club(
  p_club text,
  p_fixture_id bigint
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_total int := 0;
  v_pitch int := 0;
  v_bench int := 0;
  v_reserve int := 0;
  v_gk int := 0;
  v_issues text[] := ARRAY[]::text[];
  v_unavailable text[] := ARRAY[]::text[];
  v_has_unavail_fn boolean :=
    to_regprocedure('public.competition_player_unavailable_for_fixture(bigint, text)') IS NOT NULL;
  v_detail text;
  r record;
BEGIN
  IF v_club IS NULL THEN
    RETURN ARRAY['No club'];
  END IF;

  FOR r IN
    SELECT sp.player_id, sp.slot_kind, p."Name" AS player_name,
           upper(btrim(coalesce(p."Position", ''))) AS pos
    FROM public.club_matchday_squad_player sp
    JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
    WHERE upper(btrim(sp.club_short_name)) = v_club
  LOOP
    v_total := v_total + 1;
    IF r.slot_kind = 'pitch' THEN v_pitch := v_pitch + 1;
    ELSIF r.slot_kind = 'bench' THEN v_bench := v_bench + 1;
    ELSE v_reserve := v_reserve + 1;
    END IF;
    IF r.pos IN ('GK', 'GOALKEEPER') THEN v_gk := v_gk + 1; END IF;

    IF v_has_unavail_fn THEN
      v_detail := public.competition_player_unavailable_for_fixture(p_fixture_id, r.player_id);
      IF v_detail IS NOT NULL AND btrim(v_detail) <> '' THEN
        v_unavailable := array_append(
          v_unavailable,
          coalesce(nullif(btrim(r.player_name), ''), r.player_id) || ' (' || v_detail || ')'
        );
      END IF;
    END IF;
  END LOOP;

  IF v_total = 0 THEN
    v_issues := array_append(v_issues, 'No matchday squad saved.');
  END IF;
  IF v_pitch <> 11 THEN
    v_issues := array_append(v_issues, format('%s/11 starters saved (exactly 11 needed).', v_pitch));
  END IF;
  IF v_bench > 12 THEN
    v_issues := array_append(v_issues, format('%s on the bench (max 12).', v_bench));
  END IF;
  IF v_reserve > 0 THEN
    v_issues := array_append(v_issues, 'Reserves are not allowed in the saved squad.');
  END IF;
  IF v_gk < 1 THEN
    v_issues := array_append(v_issues, 'No goalkeeper in the saved squad.');
  END IF;
  IF coalesce(array_length(v_unavailable, 1), 0) > 0 THEN
    v_issues := array_append(
      v_issues,
      'Unavailable for this match: ' || array_to_string(v_unavailable, ', ')
    );
  END IF;

  RETURN v_issues;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Is my saved squad valid for my next fixture?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.my_next_fixture_squad_check()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint;
  r record;
  v_issues text[];
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT
    f.id, f.gpsl_month, f.matchday, f.competition_type, f.cup_code, f.cup_round,
    f.home_club_short_name, f.away_club_short_name,
    s.agreed_kickoff_at
  INTO r
  FROM public.competition_fixtures f
  LEFT JOIN public.competition_fixture_schedule s
    ON s.fixture_id = f.id AND s.status = 'agreed'
  WHERE f.season_id = v_season
    AND f.status = 'scheduled'
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
    AND (s.agreed_kickoff_at IS NULL OR s.agreed_kickoff_at >= now() - interval '20 minutes')
    AND NOT public.competition_fixture_involves_vacant_club(f.id)
  ORDER BY
    (s.agreed_kickoff_at IS NULL),
    s.agreed_kickoff_at,
    public.competition_gpsl_month_sort(f.gpsl_month),
    f.matchday, f.cup_round, f.id
  LIMIT 1;

  IF r.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'has_fixture', false);
  END IF;

  v_issues := public.matchday_squad_issues_for_club(v_club, r.id);

  RETURN jsonb_build_object(
    'ok', true,
    'has_fixture', true,
    'fixture_id', r.id,
    'side', CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END,
    'opponent_short_name', CASE WHEN upper(btrim(r.home_club_short_name)) = v_club
      THEN upper(btrim(r.away_club_short_name)) ELSE upper(btrim(r.home_club_short_name)) END,
    'gpsl_month', r.gpsl_month,
    'matchday', r.matchday,
    'competition_type', r.competition_type,
    'cup_code', r.cup_code,
    'cup_round', r.cup_round,
    'kickoff_at', r.agreed_kickoff_at,
    'squad_ready', coalesce(array_length(v_issues, 1), 0) = 0,
    'issues', to_jsonb(v_issues)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.my_next_fixture_squad_check() TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Hourly reminders
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_owner_guidance_reminders()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  r record;
  v_hours numeric;
  v_stage text;
  v_title text;
  v_body text;
  v_prior text;
  v_deadline_txt text;
  v_label text;
  v_opp text;
  v_issues text[];
  v_club text;
  v_arr int := 0;
  v_reply int := 0;
  v_squad int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'no_season');
  END IF;

  -- Home has not proposed: ≤5 days / ≤60h / late-fee window
  FOR r IN
    SELECT
      f.id, f.gpsl_month, f.matchday, f.competition_type, f.cup_code, f.cup_round,
      f.home_club_short_name AS club, f.away_club_short_name AS opp,
      cal.unlock_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '5 days'
      AND NOT public.match_schedule_home_has_proposed(f.id, now())
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_schedule s
        WHERE s.fixture_id = f.id AND s.status = 'agreed'
      )
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
  LOOP
    SELECT c.gpsl_month INTO v_prior
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season
      AND public.competition_gpsl_month_sort(c.gpsl_month)
        = public.competition_gpsl_month_sort(r.gpsl_month) - 1
    LIMIT 1;

    IF v_prior IS NOT NULL
       AND public.match_schedule_club_on_holiday_for_month(v_season, r.club, v_prior)
    THEN
      CONTINUE;
    END IF;

    v_hours := extract(epoch FROM (r.unlock_at - now())) / 3600.0;
    v_stage := CASE
      WHEN v_hours > 60 THEN 'early'
      WHEN v_hours > 48 THEN 'final'
      ELSE 'late'
    END;

    v_label := CASE
      WHEN coalesce(r.competition_type, 'league') = 'cup'
        THEN coalesce(initcap(replace(r.cup_code, '_', ' ')), 'Cup') || ' R' || coalesce(r.cup_round::text, '?')
      ELSE 'MD' || coalesce(r.matchday::text, '?')
    END;
    v_opp := coalesce(public.club_display_name(r.opp), r.opp);
    v_deadline_txt := to_char(r.unlock_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';

    IF v_stage = 'early' THEN
      v_title := 'Arrange your next match';
      v_body := format(
        E'You are home in %s vs %s (GPSL %s).\n\nPropose a kick-off by %s. The ₿2.5m late fee starts 48 hours before that, and no proposal by then is a ₿5m fine.\n\nOpen Schedule, pick a slot from your availability and press Propose kick-off.',
        v_label, v_opp, public.competition_gpsl_month_label(r.gpsl_month), v_deadline_txt
      );
    ELSIF v_stage = 'final' THEN
      v_title := 'Propose kick-off now — late fee soon';
      v_body := format(
        E'You still need to propose a kick-off for %s vs %s (GPSL %s).\n\nThe ₿2.5m late fee starts in about %s hours. Deadline: %s (no proposal by then = ₿5m).',
        v_label, v_opp, public.competition_gpsl_month_label(r.gpsl_month),
        greatest(1, floor(v_hours - 48))::int, v_deadline_txt
      );
    ELSE
      v_title := 'Propose kick-off — late fee now applies';
      v_body := format(
        E'No kick-off proposed yet for %s vs %s (GPSL %s). Proposing now costs a ₿2.5m late fee.\n\nPropose before %s to avoid the ₿5m no-proposal fine (repeats at every month lock until you propose).',
        v_label, v_opp, public.competition_gpsl_month_label(r.gpsl_month), v_deadline_txt
      );
    END IF;

    IF public.match_guidance_inbox(
      'match_arrangement_deadline_warning', v_title, v_body, r.club, r.id,
      'fixture_schedule.html?fixture=' || r.id::text,
      format('sched_arr_rem:%s:%s:%s', v_stage, r.id, to_char(r.unlock_at, 'YYYYMMDD')),
      r.gpsl_month, v_season
    ) IS NOT NULL THEN
      v_arr := v_arr + 1;
    END IF;
  END LOOP;

  -- Reply owed within 12h (same dedupe key as the month-lock job)
  FOR r IN
    SELECT
      s.fixture_id AS id,
      s.response_required_club_short_name AS club,
      s.response_due_at,
      f.gpsl_month,
      f.matchday
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.response_due_at IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at > now()
      AND s.response_due_at <= now() + interval '12 hours'
  LOOP
    v_hours := extract(epoch FROM (r.response_due_at - now())) / 3600.0;
    IF public.match_guidance_inbox(
      'match_response_deadline_warning',
      'Reply deadline soon',
      format(
        E'Reply to the pending kick-off proposal for MD%s (GPSL %s) within about %s hours — accept it or counter-propose.\n\nIf you miss the deadline, a ₿2.5m missed-response fine is charged when the month locks (once per lock, not per hour). Negotiation continues either way.',
        r.matchday,
        public.competition_gpsl_month_label(r.gpsl_month),
        greatest(1, ceil(v_hours))::int
      ),
      r.club, r.id,
      'fixture_schedule.html?fixture=' || r.id::text,
      'sched_due_warn:' || r.id::text || ':' || to_char(r.response_due_at, 'YYYYMMDDHH24'),
      r.gpsl_month, v_season
    ) IS NOT NULL THEN
      v_reply := v_reply + 1;
    END IF;
  END LOOP;

  -- Saved squad not valid for an agreed kick-off in the next 48h
  FOR r IN
    SELECT
      f.id, f.gpsl_month, f.matchday, f.home_club_short_name, f.away_club_short_name,
      s.agreed_kickoff_at
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND s.status = 'agreed'
      AND s.agreed_kickoff_at > now()
      AND s.agreed_kickoff_at <= now() + interval '48 hours'
  LOOP
    FOREACH v_club IN ARRAY ARRAY[r.home_club_short_name, r.away_club_short_name]
    LOOP
      CONTINUE WHEN NOT EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c."ShortName" = v_club AND c.owner_id IS NOT NULL
      );
      CONTINUE WHEN EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin ci
        WHERE ci.fixture_id = r.id AND upper(btrim(ci.club_short_name)) = upper(btrim(v_club))
      );

      v_issues := public.matchday_squad_issues_for_club(v_club, r.id);
      CONTINUE WHEN coalesce(array_length(v_issues, 1), 0) = 0;

      v_opp := CASE WHEN v_club = r.home_club_short_name THEN r.away_club_short_name ELSE r.home_club_short_name END;
      v_opp := coalesce(public.club_display_name(v_opp), v_opp);

      IF public.match_guidance_inbox(
        'matchday_squad_warning',
        'Fix your Match Day squad before kick-off',
        format(
          E'Your saved Match Day squad is not ready for MD%s vs %s (kick-off %s UK).\n\n• %s\n\nCheck-in is refused until this is fixed, and missing check-in can become a 3–0 forfeit plus a ₿5m fine. Open Match Day, fix the squad and press Save default squad.',
          r.matchday, v_opp,
          to_char(r.agreed_kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI'),
          array_to_string(v_issues, E'\n• ')
        ),
        v_club, r.id,
        'matchday.html?fixture=' || r.id::text || '&fix_checkin_squad=1',
        format('md_squad_warn:%s:%s:%s', r.id, v_club, md5(array_to_string(v_issues, '|'))),
        r.gpsl_month, v_season
      ) IS NOT NULL THEN
        v_squad := v_squad + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'arrangement_reminders', v_arr,
    'reply_reminders', v_reply,
    'squad_warnings', v_squad
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_owner_guidance_reminders() TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-match-guidance') THEN
      PERFORM cron.unschedule('gpsl-match-guidance');
    END IF;
    PERFORM cron.schedule(
      'gpsl-match-guidance',
      '15 * * * *',
      $job$SELECT public.match_owner_guidance_reminders();$job$
    );
  ELSE
    RAISE WARNING 'pg_cron not installed — run SELECT public.match_owner_guidance_reminders(); hourly.';
  END IF;
END $cron$;

-- ---------------------------------------------------------------------------
-- 7. Check-in open messages mention the saved squad
-- ---------------------------------------------------------------------------
DO $checkin_text$
DECLARE
  r record;
  v_def text;
  v_old text := 'Both clubs must check in before Match Day unlocks.''';
  v_new text := 'Both clubs must check in before Match Day unlocks.\nYour saved Match Day squad is checked when you check in: exactly 11 starters, a goalkeeper, no injured or suspended players.''';
BEGIN
  FOR r IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosrc LIKE '%Both clubs must check in before Match Day unlocks.''%'
      AND p.prosrc NOT LIKE '%Your saved Match Day squad is checked when you check in%'
  LOOP
    v_def := pg_get_functiondef(r.oid);
    IF position(v_old IN v_def) > 0 THEN
      BEGIN
        EXECUTE replace(v_def, v_old, v_new);
        RAISE NOTICE 'Check-in text updated in %', r.oid::regprocedure;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Check-in text update skipped for %: %', r.oid::regprocedure, SQLERRM;
      END;
    END IF;
  END LOOP;
END;
$checkin_text$;

NOTIFY pgrst, 'reload schema';

-- Check:
-- SELECT public.match_owner_guidance_reminders();
-- SELECT public.match_schedule_fixture_deadlines(<fixture_id>);
