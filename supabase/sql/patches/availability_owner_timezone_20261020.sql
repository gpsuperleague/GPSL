-- =============================================================================
-- Availability in each owner's timezone + compatible mutual slots
--
-- Before: weekly grid was UK wall-clock; timezone was display-only.
-- After:  weekly grid is the owner's local wall-clock (Clubs.owner_timezone /
--         registry). Kick-off matching converts the absolute timestamptz into
--         that zone. Propose/counter also requires the opponent free.
-- Schedule UI should prefer intersection_slots.
--
-- One-time migration: existing non-UK slots were entered as UK time — convert
-- them into each owner's local (dow, minute) using a representative week.
-- Safe re-run (migration flagged in gpsl_availability_tz_migration).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_availability_tz_migration (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  migrated_at timestamptz NOT NULL DEFAULT now(),
  note text
);

-- ---------------------------------------------------------------------------
-- Resolve club timezone (Clubs → registry → Europe/London)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_club_timezone(p_club text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club), '');
  v_tz text;
  v_owner uuid;
BEGIN
  IF v_club IS NULL THEN
    RETURN 'Europe/London';
  END IF;

  SELECT nullif(btrim(c.owner_timezone), ''), c.owner_id
  INTO v_tz, v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  LIMIT 1;

  IF v_tz IS NOT NULL THEN
    RETURN v_tz;
  END IF;

  IF v_owner IS NOT NULL THEN
    SELECT nullif(btrim(r.owner_timezone), '')
    INTO v_tz
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = v_owner
    LIMIT 1;
    IF v_tz IS NOT NULL THEN
      RETURN v_tz;
    END IF;
  END IF;

  RETURN 'Europe/London';
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_club_timezone(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Available-at: interpret weekly slots in the club owner's timezone
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
  v_tz text;
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

  v_tz := public.match_schedule_club_timezone(p_club_short_name);
  BEGIN
    v_local := p_kickoff AT TIME ZONE v_tz;
  EXCEPTION
    WHEN others THEN
      v_local := p_kickoff AT TIME ZONE 'Europe/London';
  END;

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

GRANT EXECUTE ON FUNCTION public.match_schedule_club_available_at(bigint, text, timestamptz)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Inject: propose also requires opponent free (compatible world time)
-- (Same logic as availability_owner_tz_propose_inject_20261020.sql)
-- ---------------------------------------------------------------------------
DO $inject_propose$
DECLARE
  v_oid oid;
  v_def text;
  v_marker text :=
    E'\n  PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff_at);';
  v_block text := $n$
  IF (to_regprocedure('public.competition_club_is_vacant(text)') IS NULL
      OR NOT public.competition_club_is_vacant(
           CASE
             WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
             ELSE v_fixture.home_club_short_name
           END
         ))
     AND NOT public.match_schedule_club_available_at(
           v_fixture.season_id,
           CASE
             WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
             ELSE v_fixture.home_club_short_name
           END,
           p_kickoff_at
         )
  THEN
    RAISE EXCEPTION
      'That time is not free for both clubs — pick a compatible slot from times that overlap both owners'' local availability';
  END IF;
$n$;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'fixture_schedule_propose'
  ORDER BY p.oid
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE WARNING 'fixture_schedule_propose missing — skip opponent availability inject';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('not free for both clubs' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture_schedule_propose already requires mutual availability';
    RETURN;
  END IF;

  IF position(v_marker IN v_def) = 0 THEN
    RAISE WARNING 'fixture_schedule_propose: double-book marker missing — skip inject';
    RETURN;
  END IF;

  v_def := overlay(
    v_def
    placing (E'\n' || v_block || v_marker)
    from position(v_marker IN v_def)
    for length(v_marker)
  );
  EXECUTE v_def;
  RAISE NOTICE 'fixture_schedule_propose: mutual availability guard injected';
END;
$inject_propose$;

-- ---------------------------------------------------------------------------
-- Convert one UK weekly slot → owner-local (dow, minute)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.availability_slot_uk_to_owner_local(
  p_iso_dow smallint,
  p_slot_minute smallint,
  p_owner_tz text,
  p_ref_uk_date date DEFAULT ((now() AT TIME ZONE 'Europe/London')::date)
)
RETURNS TABLE (iso_dow smallint, slot_minute smallint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tz text := coalesce(nullif(btrim(p_owner_tz), ''), 'Europe/London');
  v_uk_ts timestamp;
  v_utc timestamptz;
  v_local timestamp;
  v_days_ahead int;
  v_ref_dow smallint;
BEGIN
  IF v_tz = 'Europe/London' THEN
    iso_dow := p_iso_dow;
    slot_minute := p_slot_minute;
    RETURN NEXT;
    RETURN;
  END IF;

  v_ref_dow := EXTRACT(ISODOW FROM p_ref_uk_date)::smallint;
  v_days_ahead := ((p_iso_dow - v_ref_dow + 7) % 7);
  v_uk_ts := (p_ref_uk_date + v_days_ahead)
    + make_interval(mins => p_slot_minute);
  v_utc := v_uk_ts AT TIME ZONE 'Europe/London';
  BEGIN
    v_local := v_utc AT TIME ZONE v_tz;
  EXCEPTION
    WHEN others THEN
      iso_dow := p_iso_dow;
      slot_minute := p_slot_minute;
      RETURN NEXT;
      RETURN;
  END;

  iso_dow := EXTRACT(ISODOW FROM v_local)::smallint;
  slot_minute := (
    EXTRACT(HOUR FROM v_local) * 60 + EXTRACT(MINUTE FROM v_local)
  )::smallint;
  RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------------
-- One-time migration: non-UK owners' slots UK wall-clock → owner-local
-- ---------------------------------------------------------------------------
DO $migrate$
DECLARE
  v_done boolean := false;
  v_owner uuid;
  v_tz text;
  v_club_row record;
BEGIN
  SELECT true INTO v_done FROM public.gpsl_availability_tz_migration WHERE id = true;
  IF coalesce(v_done, false) THEN
    RAISE NOTICE 'availability timezone migration already applied — skip';
    RETURN;
  END IF;

  IF to_regclass('public.gpsl_owner_registry_availability_slot') IS NOT NULL THEN
    FOR v_owner, v_tz IN
      SELECT DISTINCT
        s.owner_id,
        coalesce(
          nullif(btrim(reg.owner_timezone), ''),
          (
            SELECT nullif(btrim(c.owner_timezone), '')
            FROM public."Clubs" c
            WHERE c.owner_id = s.owner_id
            LIMIT 1
          ),
          'Europe/London'
        )
      FROM public.gpsl_owner_registry_availability_slot s
      LEFT JOIN public.gpsl_owner_registry reg ON reg.owner_id = s.owner_id
    LOOP
      IF v_tz IS NULL OR v_tz = 'Europe/London' THEN
        CONTINUE;
      END IF;

      CREATE TEMP TABLE IF NOT EXISTS tmp_owner_slot_mig (
        iso_dow smallint,
        slot_minute smallint
      ) ON COMMIT DROP;
      DELETE FROM tmp_owner_slot_mig;

      INSERT INTO tmp_owner_slot_mig (iso_dow, slot_minute)
      SELECT loc.iso_dow, loc.slot_minute
      FROM public.gpsl_owner_registry_availability_slot s
      CROSS JOIN LATERAL public.availability_slot_uk_to_owner_local(
        s.iso_dow, s.slot_minute, v_tz
      ) loc
      WHERE s.owner_id = v_owner;

      DELETE FROM public.gpsl_owner_registry_availability_slot
      WHERE owner_id = v_owner;

      INSERT INTO public.gpsl_owner_registry_availability_slot (
        owner_id, iso_dow, slot_minute
      )
      SELECT DISTINCT v_owner, iso_dow, slot_minute
      FROM tmp_owner_slot_mig
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;

  IF to_regclass('public.club_owner_availability_slot') IS NOT NULL THEN
    FOR v_club_row IN
      SELECT DISTINCT
        s.season_id,
        s.club_short_name,
        s.owner_id,
        public.match_schedule_club_timezone(s.club_short_name) AS tz
      FROM public.club_owner_availability_slot s
    LOOP
      IF v_club_row.tz IS NULL OR v_club_row.tz = 'Europe/London' THEN
        CONTINUE;
      END IF;

      CREATE TEMP TABLE IF NOT EXISTS tmp_club_slot_mig (
        iso_dow smallint,
        slot_minute smallint
      ) ON COMMIT DROP;
      DELETE FROM tmp_club_slot_mig;

      INSERT INTO tmp_club_slot_mig (iso_dow, slot_minute)
      SELECT loc.iso_dow, loc.slot_minute
      FROM public.club_owner_availability_slot s
      CROSS JOIN LATERAL public.availability_slot_uk_to_owner_local(
        s.iso_dow, s.slot_minute, v_club_row.tz
      ) loc
      WHERE s.season_id = v_club_row.season_id
        AND s.club_short_name = v_club_row.club_short_name;

      DELETE FROM public.club_owner_availability_slot
      WHERE season_id = v_club_row.season_id
        AND club_short_name = v_club_row.club_short_name;

      INSERT INTO public.club_owner_availability_slot (
        season_id, club_short_name, owner_id, iso_dow, slot_minute
      )
      SELECT DISTINCT
        v_club_row.season_id,
        v_club_row.club_short_name,
        v_club_row.owner_id,
        iso_dow,
        slot_minute
      FROM tmp_club_slot_mig
      WHERE v_club_row.owner_id IS NOT NULL
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;

  INSERT INTO public.gpsl_availability_tz_migration (id, note)
  VALUES (
    true,
    'Converted non-UK owner weekly slots from UK wall-clock to owner-local'
  )
  ON CONFLICT (id) DO NOTHING;
END;
$migrate$;
