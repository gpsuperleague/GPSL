-- =============================================================================
-- Match availability: home-only propose + owner-perpetual weekly slots
--
-- A) Propose/counter only requires the proposing club’s availability.
--    Accept no longer requires the opponent to have set overlapping slots.
--    Schedule UI uses my_window_slots (proposer’s calendar ∩ proposal window).
--    Mutual intersection kept for mutual-override “new time” only.
--
-- B) Weekly slots are canonical on gpsl_owner_registry_availability_slot
--    (owner_id, no season). Vanilla reset deletes seasons (CASCADE wipe of
--    club_owner_availability_slot) but registry slots survive. Lookups and
--    saves sync both stores; season activate rehydrates club-season copies.
--
-- Run after: holiday_early_play_preseason.sql, owner_onboarding_availability.sql,
--            owner_availability_persist_seasons.sql, manager_required_for_fixture_arrange.sql
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Weekly availability: prefer owner registry, fall back to club-season rows
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.match_schedule_club_available_at(
  p_season_id bigint,
  p_club_short_name text,
  p_kickoff timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_local timestamp;
  v_isodow smallint;
  v_slot_minute smallint;
  v_owner_id uuid;
  v_has_weekly boolean := false;
BEGIN
  IF p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN false;
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff) THEN
    RETURN false;
  END IF;

  v_local := p_kickoff AT TIME ZONE 'Europe/London';
  v_isodow := EXTRACT(ISODOW FROM v_local)::smallint;
  v_slot_minute := (
    EXTRACT(HOUR FROM v_local) * 60 + EXTRACT(MINUTE FROM v_local)
  )::smallint;

  SELECT c.owner_id
  INTO v_owner_id
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  IF v_owner_id IS NOT NULL
     AND to_regclass('public.gpsl_owner_registry_availability_slot') IS NOT NULL
  THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.gpsl_owner_registry_availability_slot s
      WHERE s.owner_id = v_owner_id
        AND s.iso_dow = v_isodow
        AND s.slot_minute = v_slot_minute
    )
    INTO v_has_weekly;
  END IF;

  -- Fallback: club-season copy (pre-registry / vacant tooling)
  IF NOT coalesce(v_has_weekly, false) THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.club_owner_availability_slot s
      WHERE s.season_id = p_season_id
        AND s.club_short_name = p_club_short_name
        AND s.iso_dow = v_isodow
        AND s.slot_minute = v_slot_minute
    )
    INTO v_has_weekly;
  END IF;

  IF NOT coalesce(v_has_weekly, false) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = p_season_id
      AND h.club_short_name = p_club_short_name
      AND p_kickoff >= h.starts_at
      AND p_kickoff < h.ends_at
  ) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_owner_availability_unavailable u
    WHERE u.season_id = p_season_id
      AND u.club_short_name = p_club_short_name
      AND p_kickoff >= u.starts_at
      AND p_kickoff < u.ends_at
  ) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

-- Proposer’s own slots in the proposal window (not mutual)
CREATE OR REPLACE FUNCTION public.match_schedule_club_window_slots(
  p_fixture_id bigint,
  p_club_short_name text
)
RETURNS TABLE (kickoff_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_cursor timestamptz;
  v_now timestamptz := now();
  v_club text := nullif(btrim(p_club_short_name), '');
BEGIN
  IF v_club IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL OR v_lock IS NULL THEN
    RETURN;
  END IF;

  v_cursor := public.match_schedule_align_kickoff_up(greatest(v_unlock, v_now));

  WHILE v_cursor IS NOT NULL
    AND v_cursor + interval '30 minutes' <= v_lock
  LOOP
    IF v_cursor > v_now
       AND public.match_schedule_kickoff_is_slot(v_cursor)
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_club, v_cursor
           )
    THEN
      kickoff_at := v_cursor;
      RETURN NEXT;
    END IF;
    v_cursor := v_cursor + interval '30 minutes';
  END LOOP;
END;
$function$;

-- Window / slot only — availability checked by propose (proposer) separately.
-- Accept can agree a time even if the respondent never set weekly availability.
CREATE OR REPLACE FUNCTION public.match_schedule_assert_kickoff_valid(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS public.competition_fixtures
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_window_month text;
  v_is_catch_up boolean;
  v_is_holiday_early boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for scheduling';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff) THEN
    RAISE EXCEPTION 'Kick-off must be on a 30-minute boundary (UK time)';
  END IF;

  IF p_kickoff <= now() THEN
    RAISE EXCEPTION 'That kick-off time has already passed';
  END IF;

  IF to_regprocedure('public.match_schedule_assert_holiday_early_squad_ready(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);
  END IF;

  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up, w.is_holiday_early
  INTO v_unlock, v_lock, v_window_month, v_is_catch_up, v_is_holiday_early
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
      RAISE EXCEPTION 'Catch-up scheduling opens when the current GPSL month is active';
    END IF;
    IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
       AND public.match_schedule_fixture_is_holiday_early(p_fixture_id)
    THEN
      RAISE EXCEPTION 'Holiday early play opens when the current GPSL month is active';
    END IF;
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF p_kickoff < v_unlock OR p_kickoff + interval '30 minutes' > v_lock THEN
    IF coalesce(v_is_catch_up, false) THEN
      RAISE EXCEPTION 'Catch-up kick-off must fall within GPSL % (% – % UK)',
        public.competition_gpsl_month_label(v_window_month),
        public.match_schedule_format_kickoff_uk(v_unlock),
        public.match_schedule_format_kickoff_uk(v_lock);
    END IF;
    IF coalesce(v_is_holiday_early, false) THEN
      RAISE EXCEPTION 'Holiday early kick-off must fall within GPSL % (% – % UK)',
        public.competition_gpsl_month_label(v_window_month),
        public.match_schedule_format_kickoff_uk(v_unlock),
        public.match_schedule_format_kickoff_uk(v_lock);
    END IF;
    RAISE EXCEPTION 'Kick-off must fall within the GPSL month window (% – % UK)',
      public.match_schedule_format_kickoff_uk(v_unlock),
      public.match_schedule_format_kickoff_uk(v_lock);
  END IF;

  RETURN v_fixture;
END;
$function$;

-- Propose / counter: proposer must be available at the chosen slot
CREATE OR REPLACE FUNCTION public.fixture_schedule_propose(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_opponent text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_proposal_id bigint;
  v_title text;
  v_body text;
  v_fmt text;
  v_is_counter boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  v_club_name := public.club_display_name(v_club);

  v_fixture := public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);

  IF NOT public.match_schedule_club_available_at(
       v_fixture.season_id, v_club, p_kickoff_at
     )
  THEN
    RAISE EXCEPTION 'You are not available at that time — set weekly availability on Owner Details first';
  END IF;

  v_schedule := public.match_schedule_ensure_row(p_fixture_id);
  v_is_counter := v_schedule.status <> 'unscheduled';

  IF v_schedule.status = 'agreed' THEN
    RAISE EXCEPTION 'Kick-off is already agreed for this fixture';
  END IF;

  IF v_schedule.status = 'unscheduled' THEN
    IF v_club <> v_fixture.home_club_short_name THEN
      RAISE EXCEPTION 'Home club must propose the first kick-off time';
    END IF;
  ELSE
    IF v_schedule.pending_proposal_id IS NULL THEN
      RAISE EXCEPTION 'No pending proposal to respond to';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.competition_fixture_schedule_proposal p
      WHERE p.id = v_schedule.pending_proposal_id
        AND p.proposed_by_club_short_name = v_club
    ) THEN
      RAISE EXCEPTION 'Wait for your opponent to respond to your proposal';
    END IF;
  END IF;

  IF v_schedule.pending_proposal_id IS NOT NULL THEN
    UPDATE public.competition_fixture_schedule_proposal
    SET status = 'superseded'
    WHERE id = v_schedule.pending_proposal_id
      AND status = 'pending';
  END IF;

  INSERT INTO public.competition_fixture_schedule_proposal (
    fixture_id, proposed_by_club_short_name, kickoff_at, status
  )
  VALUES (p_fixture_id, v_club, p_kickoff_at, 'pending')
  RETURNING id INTO v_proposal_id;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'negotiating',
    pending_proposal_id = v_proposal_id,
    home_proposal_count = home_proposal_count + CASE WHEN v_club = v_fixture.home_club_short_name THEN 1 ELSE 0 END,
    away_proposal_count = away_proposal_count + CASE WHEN v_club = v_fixture.away_club_short_name THEN 1 ELSE 0 END,
    discord_hint_shown = (
      (home_proposal_count + CASE WHEN v_club = v_fixture.home_club_short_name THEN 1 ELSE 0 END) >= 2
      AND (away_proposal_count + CASE WHEN v_club = v_fixture.away_club_short_name THEN 1 ELSE 0 END) >= 2
    ),
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  IF to_regprocedure('public.match_schedule_set_response_deadline(bigint, bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_set_response_deadline(p_fixture_id, v_proposal_id);
  END IF;

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);
  v_fmt := public.match_schedule_format_kickoff_uk(p_kickoff_at);
  v_title := CASE
    WHEN NOT v_is_counter THEN 'Match time proposed'
    ELSE 'Counter-proposal received'
  END;
  v_body := v_club_name || ' proposed ' || v_fmt || E'.\nOpen Schedule to accept or suggest another time.';

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    CASE WHEN NOT v_is_counter THEN 'match_time_proposed' ELSE 'match_time_countered' END,
    v_title,
    v_body,
    v_opponent,
    'prop:' || v_proposal_id::text || ':' || v_opponent,
    v_proposal_id
  );

  IF to_regprocedure(
       'public.match_schedule_notify_proposer_sent(public.competition_fixtures, text, text, timestamptz, bigint, boolean)'
     ) IS NOT NULL
  THEN
    PERFORM public.match_schedule_notify_proposer_sent(
      v_fixture,
      v_club,
      v_opponent,
      p_kickoff_at,
      v_proposal_id,
      v_is_counter
    );
  END IF;

  RETURN v_proposal_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Sync helpers: registry <-> club-season copy
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_availability_write_registry(
  p_owner_id uuid,
  p_slots jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_slot jsonb;
  v_isodow smallint;
  v_minute smallint;
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regclass('public.gpsl_owner_registry_availability_slot') IS NULL THEN
    RETURN;
  END IF;

  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'Slots must be a JSON array';
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, status_changed_at)
  VALUES (p_owner_id, 'active', now())
  ON CONFLICT (owner_id) DO NOTHING;

  DELETE FROM public.gpsl_owner_registry_availability_slot
  WHERE owner_id = p_owner_id;

  FOR v_slot IN SELECT * FROM jsonb_array_elements(p_slots)
  LOOP
    v_isodow := (v_slot->>'iso_dow')::smallint;
    v_minute := (
      COALESCE((v_slot->>'hour')::integer, 0) * 60
      + COALESCE((v_slot->>'minute')::integer, 0)
    )::smallint;

    IF v_isodow IS NULL OR v_isodow < 1 OR v_isodow > 7 THEN
      RAISE EXCEPTION 'Invalid iso_dow in slot';
    END IF;

    IF v_minute % 30 <> 0 OR v_minute < 0 OR v_minute > 1410 THEN
      RAISE EXCEPTION 'Invalid time in slot (30-minute blocks only)';
    END IF;

    INSERT INTO public.gpsl_owner_registry_availability_slot (
      owner_id, iso_dow, slot_minute
    )
    VALUES (p_owner_id, v_isodow, v_minute);
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_owner_availability_sync_from_registry(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_clubs int := 0;
  v_slots int := 0;
  v_row record;
  v_n int;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current = true AND s.status = 'active'
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regclass('public.gpsl_owner_registry_availability_slot') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_registry_table');
  END IF;

  FOR v_row IN
    SELECT c."ShortName" AS club, c.owner_id
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
  LOOP
    DELETE FROM public.club_owner_availability_slot
    WHERE season_id = v_season_id
      AND club_short_name = v_row.club;

    INSERT INTO public.club_owner_availability_slot (
      season_id, club_short_name, owner_id, iso_dow, slot_minute
    )
    SELECT
      v_season_id,
      v_row.club,
      v_row.owner_id,
      s.iso_dow,
      s.slot_minute
    FROM public.gpsl_owner_registry_availability_slot s
    WHERE s.owner_id = v_row.owner_id;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_slots := v_slots + v_n;
    v_clubs := v_clubs + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'clubs', v_clubs,
    'slots', v_slots
  );
END;
$function$;

-- Backfill registry from latest club-season rows where registry is empty
DO $$
DECLARE
  v_owner uuid;
  v_season bigint;
BEGIN
  IF to_regclass('public.gpsl_owner_registry_availability_slot') IS NULL THEN
    RETURN;
  END IF;

  FOR v_owner IN
    SELECT DISTINCT coalesce(c.owner_id, s.owner_id)
    FROM public.club_owner_availability_slot s
    JOIN public."Clubs" c ON c."ShortName" = s.club_short_name
    WHERE coalesce(c.owner_id, s.owner_id) IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.gpsl_owner_registry_availability_slot r
        WHERE r.owner_id = coalesce(c.owner_id, s.owner_id)
      )
  LOOP
    SELECT max(s.season_id) INTO v_season
    FROM public.club_owner_availability_slot s
    JOIN public."Clubs" c ON c."ShortName" = s.club_short_name
    WHERE coalesce(c.owner_id, s.owner_id) = v_owner;

    INSERT INTO public.gpsl_owner_registry (owner_id, status, status_changed_at)
    VALUES (v_owner, 'active', now())
    ON CONFLICT (owner_id) DO NOTHING;

    INSERT INTO public.gpsl_owner_registry_availability_slot (
      owner_id, iso_dow, slot_minute
    )
    SELECT DISTINCT v_owner, s.iso_dow, s.slot_minute
    FROM public.club_owner_availability_slot s
    JOIN public."Clubs" c ON c."ShortName" = s.club_short_name
    WHERE s.season_id = v_season
      AND coalesce(c.owner_id, s.owner_id) = v_owner
    ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.club_availability_save_weekly(p_slots jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_slot jsonb;
  v_isodow smallint;
  v_minute smallint;
  v_owner uuid := auth.uid();
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'Slots must be a JSON array';
  END IF;

  -- Canonical owner store (survives vanilla reset)
  PERFORM public.owner_availability_write_registry(v_owner, p_slots);

  DELETE FROM public.club_owner_availability_slot
  WHERE season_id = v_season_id
    AND club_short_name = v_club;

  FOR v_slot IN SELECT * FROM jsonb_array_elements(p_slots)
  LOOP
    v_isodow := (v_slot->>'iso_dow')::smallint;
    v_minute := (
      COALESCE((v_slot->>'hour')::integer, 0) * 60
      + COALESCE((v_slot->>'minute')::integer, 0)
    )::smallint;

    IF v_isodow IS NULL OR v_isodow < 1 OR v_isodow > 7 THEN
      RAISE EXCEPTION 'Invalid iso_dow in slot';
    END IF;

    IF v_minute % 30 <> 0 OR v_minute < 0 OR v_minute > 1410 THEN
      RAISE EXCEPTION 'Invalid time in slot (30-minute blocks only)';
    END IF;

    INSERT INTO public.club_owner_availability_slot (
      season_id, club_short_name, owner_id, iso_dow, slot_minute
    )
    VALUES (v_season_id, v_club, v_owner, v_isodow, v_minute);
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_availability_save_weekly(
  p_club_short_name text,
  p_slots jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_owner_id uuid;
  v_slot jsonb;
  v_isodow smallint;
  v_minute smallint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_club := nullif(btrim(p_club_short_name), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  SELECT c.owner_id INTO v_owner_id
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  IF v_owner_id IS NULL THEN
    v_owner_id := auth.uid();
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'Slots must be a JSON array';
  END IF;

  PERFORM public.owner_availability_write_registry(v_owner_id, p_slots);

  DELETE FROM public.club_owner_availability_slot
  WHERE season_id = v_season_id
    AND club_short_name = v_club;

  FOR v_slot IN SELECT * FROM jsonb_array_elements(p_slots)
  LOOP
    v_isodow := (v_slot->>'iso_dow')::smallint;
    v_minute := (
      COALESCE((v_slot->>'hour')::integer, 0) * 60
      + COALESCE((v_slot->>'minute')::integer, 0)
    )::smallint;

    IF v_isodow IS NULL OR v_isodow < 1 OR v_isodow > 7 THEN
      RAISE EXCEPTION 'Invalid iso_dow in slot';
    END IF;

    IF v_minute % 30 <> 0 OR v_minute < 0 OR v_minute > 1410 THEN
      RAISE EXCEPTION 'Invalid time in slot (30-minute blocks only)';
    END IF;

    INSERT INTO public.club_owner_availability_slot (
      season_id, club_short_name, owner_id, iso_dow, slot_minute
    )
    VALUES (v_season_id, v_club, v_owner_id, v_isodow, v_minute);
  END LOOP;
END;
$function$;

-- Prefer registry when loading weekly slots for context UI
CREATE OR REPLACE FUNCTION public.match_schedule_club_weekly_slots_json(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid;
  v_json jsonb;
BEGIN
  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  IF v_owner IS NOT NULL
     AND to_regclass('public.gpsl_owner_registry_availability_slot') IS NOT NULL
  THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'iso_dow', s.iso_dow,
        'hour', s.slot_minute / 60,
        'minute', s.slot_minute % 60
      )
      ORDER BY s.iso_dow, s.slot_minute
    ), '[]'::jsonb)
    INTO v_json
    FROM public.gpsl_owner_registry_availability_slot s
    WHERE s.owner_id = v_owner;

    IF v_json IS NOT NULL AND jsonb_array_length(v_json) > 0 THEN
      RETURN v_json;
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'iso_dow', s.iso_dow,
      'hour', s.slot_minute / 60,
      'minute', s.slot_minute % 60
    )
    ORDER BY s.iso_dow, s.slot_minute
  ), '[]'::jsonb)
  INTO v_json
  FROM public.club_owner_availability_slot s
  WHERE s.season_id = p_season_id
    AND s.club_short_name = p_club_short_name;

  RETURN coalesce(v_json, '[]'::jsonb);
END;
$function$;

-- Hook carry-forward: rehydrate from registry after season activate
CREATE OR REPLACE FUNCTION public.club_owner_availability_carry_forward(
  p_to_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from bigint;
  v_copy jsonb;
  v_sync jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_to_season_id IS NULL THEN
    RAISE EXCEPTION 'to season id required';
  END IF;

  -- Owner-canonical rehydrate (works after vanilla reset)
  v_sync := public.club_owner_availability_sync_from_registry(p_to_season_id);

  SELECT s.season_id
  INTO v_from
  FROM public.club_owner_availability_slot s
  WHERE s.season_id <> p_to_season_id
  GROUP BY s.season_id
  ORDER BY s.season_id DESC
  LIMIT 1;

  IF v_from IS NOT NULL
     AND to_regprocedure('public.club_owner_availability_copy_season(bigint, bigint)') IS NOT NULL
  THEN
    v_copy := public.club_owner_availability_copy_season(v_from, p_to_season_id);
  ELSE
    v_copy := jsonb_build_object('ok', true, 'slots_copied', 0, 'skipped', 'no_prior_season');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'registry_sync', v_sync,
    'season_copy', v_copy
  );
END;
$function$;

-- Fixture context: add my_window_slots; weekly from registry
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_context(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  IF v_fixture.status = 'scheduled' AND v_status = 'agreed' AND v_agreed IS NOT NULL AND NOT v_mutual_used AND v_override.id IS NULL THEN
    BEGIN
      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      v_can_play_now := true;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := false; v_play_now_kickoff := NULL;
    END;
    v_can_mutual_new_time := now() < v_agreed;
  END IF;
  IF v_override.id IS NOT NULL AND v_club IS NOT NULL THEN
    IF v_club = v_home THEN v_my_override_confirmed := v_override.home_confirmed_at IS NOT NULL;
    ELSE v_my_override_confirmed := v_override.away_confirmed_at IS NOT NULL; END IF;
    v_can_confirm_override := NOT v_my_override_confirmed AND v_override.requested_by_club <> v_club;
    v_can_cancel_override := v_my_override_confirmed OR v_override.requested_by_club = v_club;
  END IF;
  RETURN jsonb_build_object(
    'fixture', jsonb_build_object('id', v_fixture.id, 'gpsl_month', v_fixture.gpsl_month, 'division', v_fixture.division, 'cup_code', v_fixture.cup_code, 'home_club_short_name', v_home, 'away_club_short_name', v_away, 'status', v_fixture.status, 'competition_type', v_fixture.competition_type, 'is_forfeit', v_fixture.is_forfeit, 'is_catch_up', v_is_catch_up, 'is_holiday_early', v_is_holiday_early),
    'schedule', jsonb_build_object('status', v_status, 'agreed_kickoff_at', v_agreed, 'home_proposal_count', v_home_count, 'away_proposal_count', v_away_count, 'discord_hint_shown', v_discord_hint, 'mutual_override_used', v_mutual_used, 'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END, 'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END, 'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END),
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
    'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating' AND v_has_mgr),
    'response_deadline', public.match_schedule_response_deadline_json(p_fixture_id, v_club),
    'mutual_override_options', jsonb_build_object('can_request_play_now', v_can_play_now, 'play_now_kickoff_at', v_play_now_kickoff, 'can_request_new_time', v_can_mutual_new_time),
    'checkin', jsonb_build_object('home_checked_in', v_home_in, 'away_checked_in', v_away_in, 'my_checked_in', v_my_in, 'window_opens_at', v_kickoff, 'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END, 'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END, 'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in AND v_has_mgr), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval)),
    'allowances', jsonb_build_object('emergency_drops_used', v_emergency_used, 'emergency_drops_remaining', greatest(0, 2 - v_emergency_used), 'reschedule_used_this_month', v_reschedule_used, 'can_voluntary_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() <= v_kickoff - interval '24 hours' AND NOT v_reschedule_used AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_emergency_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() < v_kickoff AND now() > v_kickoff - interval '24 hours' AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_catch_up_reset', v_can_catch_up_reset, 'can_replay_reset', v_can_replay_reset)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_club_window_slots(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_club_weekly_slots_json(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_owner_availability_sync_from_registry(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_availability_write_registry(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_schedule_propose(bigint, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_context(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- After deploy: owners who already set availability are backfilled into registry.
-- After next vanilla reset + season activate, carry_forward rehydrates club copies from registry.
