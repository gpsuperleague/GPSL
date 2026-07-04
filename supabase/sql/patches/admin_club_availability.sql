-- =============================================================================
-- Admin — set any club's match availability & timezone (Testing menu)
-- Run after match_scheduling_phase1.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_club_availability_context(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_tz text;
  v_owner_id uuid;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_club := nullif(btrim(p_club_short_name), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  LIMIT 1;

  v_tz := public.match_schedule_club_timezone(v_club);

  SELECT c.owner_id INTO v_owner_id FROM public."Clubs" c WHERE c."ShortName" = v_club;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'season_id', v_season_id,
    'timezone', v_tz,
    'owner_id', v_owner_id,
    'weekly_slots', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'iso_dow', s.iso_dow,
          'hour', s.slot_minute / 60,
          'minute', s.slot_minute % 60
        )
        ORDER BY s.iso_dow, s.slot_minute
      ), '[]'::jsonb)
      FROM public.club_owner_availability_slot s
      WHERE s.season_id = v_season_id AND s.club_short_name = v_club
    ),
    'slot_count', (
      SELECT count(*)::integer
      FROM public.club_owner_availability_slot s
      WHERE s.season_id = v_season_id AND s.club_short_name = v_club
    ),
    'holidays', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id', h.id,
          'starts_at', h.starts_at,
          'ends_at', h.ends_at,
          'day_count', h.day_count
        )
        ORDER BY h.starts_at
      ), '[]'::jsonb)
      FROM public.club_owner_holidays h
      WHERE h.season_id = v_season_id AND h.club_short_name = v_club
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_owner_timezone_set(
  p_club_short_name text,
  p_timezone text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_club := nullif(btrim(p_club_short_name), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  IF p_timezone IS NULL OR btrim(p_timezone) = '' THEN
    RAISE EXCEPTION 'Timezone is required';
  END IF;

  UPDATE public."Clubs"
  SET owner_timezone = btrim(p_timezone)
  WHERE "ShortName" = v_club;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not found';
  END IF;
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

GRANT EXECUTE ON FUNCTION public.admin_club_availability_context(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_owner_timezone_set(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_availability_save_weekly(text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
