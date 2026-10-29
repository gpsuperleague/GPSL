-- =============================================================================
-- Scheduling audit fixes (2026-10-29)
--
-- 1) Deadline-warning / guidance inbox copy → soft fines ₿1m late / ₿2.5m none
-- 2) Mid-month new-owner arrange grace: block propose (+ context flag)
-- 3) Soft-fine tariffs reasserted (idempotent)
--
-- Safe re-run. UI also gates poke until poke_allowed is true and shows
-- play_now_block_reason (client patches).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Soft fine tariffs (source of truth after soft_fines_discord_lock)
-- ---------------------------------------------------------------------------
UPDATE public.competition_fine_tariff
SET
  amount = 2500000,
  label = 'Match Management Fine (no proposal)',
  is_active = true,
  updated_at = now()
WHERE code = 'match_mgmt_no_proposal'
  AND coalesce(amount, 0) <> 2500000;

UPDATE public.competition_fine_tariff
SET
  amount = 1000000,
  label = 'Late Arrangement Fee',
  is_active = true,
  updated_at = now()
WHERE code = 'match_late_arrangement'
  AND coalesce(amount, 0) <> 1000000;

UPDATE public.competition_fine_tariff
SET
  amount = 2500000,
  label = 'Missed scheduling response',
  is_active = true,
  updated_at = now()
WHERE code = 'match_response_deadline'
  AND coalesce(amount, 0) <> 2500000;

-- ---------------------------------------------------------------------------
-- Deadline warnings (month-lock job) — soft fine copy
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_notify_scheduling_deadline_warnings(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_sent int := 0;
  v_hours numeric;
  v_prior text;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.response_required_club_short_name AS club,
      s.response_due_at,
      f.gpsl_month,
      f.matchday
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.response_due_at IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at > now()
      AND s.response_due_at <= now() + interval '12 hours'
  LOOP
    v_hours := extract(epoch FROM (v_row.response_due_at - now())) / 3600.0;
    IF public.owner_inbox_send(
      'match_response_deadline_warning',
      'Reply deadline soon',
      format(
        'Reply to the pending match time for MD%s (%s) within about %s hours. First overdue month lock is a warning only; later locks while still overdue charge ₿2.5m. Negotiation continues if you miss.',
        v_row.matchday,
        public.competition_gpsl_month_label(v_row.gpsl_month),
        greatest(1, ceil(v_hours))::int
      ),
      v_row.club, NULL, v_row.fixture_id,
      NULL, NULL, NULL,
      'fixture_schedule.html?fixture=' || v_row.fixture_id::text,
      'sched_due_warn:' || v_row.fixture_id::text || ':' || to_char(v_row.response_due_at, 'YYYYMMDDHH24'),
      v_row.gpsl_month, p_season_id, NULL
    ) IS NOT NULL THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  FOR v_row IN
    SELECT
      f.id AS fixture_id,
      f.home_club_short_name AS club,
      f.gpsl_month,
      f.matchday,
      cal.unlock_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id AND cal.gpsl_month = f.gpsl_month
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '48 hours'
      AND NOT public.match_schedule_home_has_proposed(f.id, cal.unlock_at)
      AND EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c."ShortName" = f.home_club_short_name AND c.owner_id IS NOT NULL
      )
  LOOP
    SELECT c.gpsl_month INTO v_prior
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND public.competition_gpsl_month_sort(c.gpsl_month)
        = public.competition_gpsl_month_sort(v_row.gpsl_month) - 1
    LIMIT 1;

    IF v_prior IS NOT NULL
       AND public.match_schedule_club_on_holiday_for_month(p_season_id, v_row.club, v_prior)
    THEN
      CONTINUE;
    END IF;

    IF public.owner_inbox_send(
      'match_arrangement_deadline_warning',
      'Propose match time soon',
      format(
        'As home for MD%s (%s), propose a kick-off before the play month opens. Last 48h = ₿1m late fee; no proposal by lock = ₿2.5m (repeats each lock until you propose).',
        v_row.matchday,
        public.competition_gpsl_month_label(v_row.gpsl_month)
      ),
      v_row.club, NULL, v_row.fixture_id,
      NULL, NULL, NULL,
      'fixture_schedule.html?fixture=' || v_row.fixture_id::text,
      'sched_arr_warn:' || v_row.fixture_id::text || ':' || to_char(v_row.unlock_at, 'YYYYMMDD'),
      v_row.gpsl_month, p_season_id, NULL
    ) IS NOT NULL THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'sent', v_sent);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_notify_scheduling_deadline_warnings(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_notify_scheduling_deadline_warnings(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Owner guidance reminders — soft fine copy (string replace, idempotent)
-- ---------------------------------------------------------------------------
DO $guidance$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure('public.match_owner_guidance_reminders()');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'match_owner_guidance_reminders missing — skip copy fix';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  -- Early stage
  v_def := replace(
    v_def,
    'The ₿2.5m late fee starts 48 hours before that, and no proposal by then is a ₿5m fine.',
    'The ₿1m late fee starts 48 hours before that, and no proposal by then is a ₿2.5m fine.'
  );
  -- Final stage
  v_def := replace(
    v_def,
    'The ₿2.5m late fee starts in about %s hours. Deadline: %s (no proposal by then = ₿5m).',
    'The ₿1m late fee starts in about %s hours. Deadline: %s (no proposal by then = ₿2.5m).'
  );
  -- Late stage
  v_def := replace(
    v_def,
    'Proposing now costs a ₿2.5m late fee.\n\nPropose before %s to avoid the ₿5m no-proposal fine (repeats at every month lock until you propose).',
    'Proposing now costs a ₿1m late fee.\n\nPropose before %s to avoid the ₿2.5m no-proposal fine (repeats at every month lock until you propose).'
  );

  EXECUTE v_def;
  RAISE NOTICE 'match_owner_guidance_reminders: soft fine copy applied';
END;
$guidance$;

-- ---------------------------------------------------------------------------
-- Mid-month new-owner arrange grace (mirrors client fixtureNewOwnerArrangeGrace)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_new_owner_arrange_grace(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_play text;
  v_short text;
  v_assigned timestamptz;
  v_next text;
  v_months text[] := ARRAY[
    'august','september','october','november','december',
    'january','february','march','april','may'
  ];
  v_idx int;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND OR v_f.status = 'played' THEN
    RETURN NULL;
  END IF;

  v_play := lower(btrim(coalesce(v_f.gpsl_month, '')));
  IF v_play = '' THEN
    RETURN NULL;
  END IF;

  SELECT cal.unlock_at, cal.lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id
    AND lower(btrim(cal.gpsl_month)) = v_play
  LIMIT 1;

  IF v_unlock IS NULL THEN
    RETURN NULL;
  END IF;

  -- Grace only while the fixture play month is still open
  IF v_lock IS NOT NULL AND now() > v_lock THEN
    RETURN NULL;
  END IF;

  FOREACH v_short IN ARRAY ARRAY[
    v_f.home_club_short_name,
    v_f.away_club_short_name
  ]
  LOOP
    SELECT c.owner_assigned_at
    INTO v_assigned
    FROM public."Clubs" c
    WHERE c."ShortName" = v_short
       OR upper(c."ShortName") = upper(btrim(v_short))
    LIMIT 1;

    IF v_assigned IS NULL THEN
      CONTINUE;
    END IF;

    IF v_assigned >= v_unlock
       AND (v_lock IS NULL OR v_assigned <= v_lock)
    THEN
      v_idx := array_position(v_months, v_play);
      IF v_idx IS NOT NULL AND v_idx < cardinality(v_months) THEN
        v_next := v_months[v_idx + 1];
      ELSE
        v_next := NULL;
      END IF;

      RETURN jsonb_build_object(
        'club_short', upper(btrim(v_short)),
        'play_month', v_play,
        'play_month_label', public.competition_gpsl_month_label(v_play),
        'arrange_from_month', v_next,
        'arrange_from_label', CASE
          WHEN v_next IS NOT NULL THEN public.competition_gpsl_month_label(v_next)
          ELSE 'the following GPSL month'
        END,
        'grace_until', v_lock
      );
    END IF;
  END LOOP;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_new_owner_arrange_grace(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_new_owner_arrange_grace(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_fixture_new_owner_arrange_grace(bigint) IS
  'When either club got a new owner mid play-month, arrangement is deferred until the next GPSL month.';

-- Propose: refuse while arrange grace is active
DO $propose_grace$
DECLARE
  v_oid oid;
  v_def text;
  v_insert text :=
    E'IF public.match_schedule_fixture_new_owner_arrange_grace(p_fixture_id) IS NOT NULL THEN\n'
    || E'    RAISE EXCEPTION ''New owner mid-month grace — arrange from the following GPSL month'';\n'
    || E'  END IF;\n\n  ';
  v_anchor text;
BEGIN
  v_oid := to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'fixture_schedule_propose missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('match_schedule_fixture_new_owner_arrange_grace' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture_schedule_propose already grace-gated';
    RETURN;
  END IF;

  -- Prefer insert after fixture-not-found guard
  v_anchor := E'RAISE EXCEPTION ''Fixture not found'';\n  END IF;\n';
  IF position(v_anchor IN v_def) > 0 THEN
    v_def := replace(v_def, v_anchor, v_anchor || E'\n  ' || v_insert);
  ELSIF position(
          E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
          || E'     AND NOT public.match_schedule_club_available_at('
          IN v_def
        ) > 0
  THEN
    v_def := replace(
      v_def,
      E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
        || E'     AND NOT public.match_schedule_club_available_at(',
      v_insert
        || E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
        || E'     AND NOT public.match_schedule_club_available_at('
    );
  ELSIF position(
          E'IF NOT public.match_schedule_club_available_at(\n'
          || E'       v_fixture.season_id, v_club, p_kickoff_at\n'
          || E'     )'
          IN v_def
        ) > 0
  THEN
    v_def := replace(
      v_def,
      E'IF NOT public.match_schedule_club_available_at(\n'
        || E'       v_fixture.season_id, v_club, p_kickoff_at\n'
        || E'     )',
      v_insert
        || E'IF NOT public.match_schedule_club_available_at(\n'
        || E'       v_fixture.season_id, v_club, p_kickoff_at\n'
        || E'     )'
    );
  ELSE
    RAISE EXCEPTION 'Could not find insert point for new-owner arrange grace in propose';
  END IF;

  IF position('match_schedule_fixture_new_owner_arrange_grace' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Propose grace gate did not land';
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'fixture_schedule_propose: new-owner arrange grace gated';
END;
$propose_grace$;

-- Context: expose new_owner_arrange_grace (UI + loadScheduleContext clear propose flags)
DO $ctx_grace$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_schedule_fixture_context missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('''new_owner_arrange_grace''' IN v_def) > 0 THEN
    RAISE NOTICE 'context already has new_owner_arrange_grace';
    RETURN;
  END IF;

  IF position('''poke_allowed''' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'''poke_allowed'', public.match_schedule_allow_free_propose(p_fixture_id),',
      E'''poke_allowed'', public.match_schedule_allow_free_propose(p_fixture_id),\n'
        || E'    ''new_owner_arrange_grace'', public.match_schedule_fixture_new_owner_arrange_grace(p_fixture_id),'
    );
  ELSIF position('''my_window_slots''' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'''my_window_slots'',',
      E'''new_owner_arrange_grace'', public.match_schedule_fixture_new_owner_arrange_grace(p_fixture_id),\n'
        || E'    ''my_window_slots'','
    );
  ELSIF position('''intersection_slots''' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'''intersection_slots'',',
      E'''new_owner_arrange_grace'', public.match_schedule_fixture_new_owner_arrange_grace(p_fixture_id),\n'
        || E'    ''intersection_slots'','
    );
  ELSE
    RAISE EXCEPTION 'Could not inject new_owner_arrange_grace into context return';
  END IF;

  IF position('''new_owner_arrange_grace''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'Context grace field patch failed';
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'match_schedule_fixture_context: new_owner_arrange_grace';
END;
$ctx_grace$;

NOTIFY pgrst, 'reload schema';

SELECT
  (SELECT amount FROM public.competition_fine_tariff WHERE code = 'match_late_arrangement') AS late_fee,
  (SELECT amount FROM public.competition_fine_tariff WHERE code = 'match_mgmt_no_proposal') AS no_prop,
  (position('₿1m late fee' IN pg_get_functiondef(
    'public.competition_notify_scheduling_deadline_warnings(bigint)'::regprocedure
  )) > 0) AS deadline_warn_soft_copy,
  (to_regprocedure('public.match_schedule_fixture_new_owner_arrange_grace(bigint)') IS NOT NULL)
    AS grace_helper_ok;
