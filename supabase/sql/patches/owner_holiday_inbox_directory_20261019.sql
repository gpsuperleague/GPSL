-- =============================================================================
-- Owner holidays: league inbox alerts + public directory (UH / OH status)
--
-- When a holiday is booked / amended / cancelled:
--   every club gets an Inbox message (club name + owner tag only — never email).
--
-- Directory RPC for Owners → Info → Owner Holidays:
--   upcoming / on-holiday owners, plus scheduled fixtures to arrange early.
--
-- Status map for owner-tag badges:
--   UH = upcoming holiday, OH = on holiday, none when ended / back.
--
-- Safe re-run. Depends on club_owner_holidays + owner_inbox_notify_all_clubs.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Shared: club display name + Discord owner tag (no email / password)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_holiday_public_identity(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_name text;
  v_tag text;
  v_owner_id uuid;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('club_short_name', '', 'club_name', '', 'owner_tag', '', 'owner_id', null);
  END IF;

  SELECT c."Club", nullif(btrim(c.owner), ''), c.owner_id
  INTO v_name, v_tag, v_owner_id
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = v_club
  LIMIT 1;

  IF v_tag IS NULL AND v_owner_id IS NOT NULL THEN
    SELECT nullif(btrim(r.owner_tag), '')
    INTO v_tag
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = v_owner_id
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'club_name', coalesce(v_name, v_club),
    'owner_tag', coalesce(v_tag, ''),
    'owner_id', v_owner_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_holiday_public_identity(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_holiday_public_identity(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Inbox blast helper (all owned clubs)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_holiday_inbox_announce(
  p_action text,
  p_holiday_id bigint,
  p_club text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_day_count int,
  p_season_id bigint
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id jsonb;
  v_club_name text;
  v_tag text;
  v_start_label text;
  v_end_label text;
  v_title text;
  v_body text;
  v_action text := lower(btrim(coalesce(p_action, 'booked')));
  v_dedupe text;
  v_count int := 0;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_notify_all_clubs(text,text,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN 0;
  END IF;

  v_id := public.club_holiday_public_identity(p_club);
  v_club_name := coalesce(v_id->>'club_name', p_club);
  v_tag := nullif(btrim(coalesce(v_id->>'owner_tag', '')), '');

  v_start_label := to_char(
    (p_starts_at AT TIME ZONE 'Europe/London')::date, 'DD Mon YYYY'
  );
  v_end_label := to_char(
    ((p_ends_at - interval '1 microsecond') AT TIME ZONE 'Europe/London')::date,
    'DD Mon YYYY'
  );

  IF v_action = 'cancelled' THEN
    v_title := format('Holiday cancelled — %s', v_club_name);
    v_body := format(
      E'%s%s has cancelled their holiday (%s – %s, %s day%s).\n\nFixtures that were unlocked for early play no longer need holiday priority. See Owner Holidays for the current list.',
      v_club_name,
      CASE WHEN v_tag IS NULL THEN '' ELSE ' (' || v_tag || ')' END,
      v_start_label,
      v_end_label,
      coalesce(p_day_count, 0),
      CASE WHEN coalesce(p_day_count, 0) = 1 THEN '' ELSE 's' END
    );
    v_dedupe := format('holiday_cancel_%s_%s', p_holiday_id, extract(epoch FROM now())::bigint);
  ELSIF v_action = 'amended' THEN
    v_title := format('Holiday updated — %s', v_club_name);
    v_body := format(
      E'%s%s has updated their holiday to %s – %s (%s day%s).\n\nPlease arrange / play overlapping fixtures early where possible. Open Owner Holidays for fixtures and status.',
      v_club_name,
      CASE WHEN v_tag IS NULL THEN '' ELSE ' (' || v_tag || ')' END,
      v_start_label,
      v_end_label,
      coalesce(p_day_count, 0),
      CASE WHEN coalesce(p_day_count, 0) = 1 THEN '' ELSE 's' END
    );
    v_dedupe := format('holiday_amend_%s_%s', p_holiday_id, extract(epoch FROM now())::bigint);
  ELSE
    v_title := format('Holiday booked — %s', v_club_name);
    v_body := format(
      E'%s%s has booked holiday %s – %s (%s day%s).\n\nPlease arrange / play overlapping fixtures early where possible. Open Owner Holidays for fixtures and UH/OH status.',
      v_club_name,
      CASE WHEN v_tag IS NULL THEN '' ELSE ' (' || v_tag || ')' END,
      v_start_label,
      v_end_label,
      coalesce(p_day_count, 0),
      CASE WHEN coalesce(p_day_count, 0) = 1 THEN '' ELSE 's' END
    );
    v_dedupe := format('holiday_book_%s', p_holiday_id);
  END IF;

  v_count := public.owner_inbox_notify_all_clubs(
    'owner_holiday',
    v_title,
    v_body,
    'owner_holidays_board.html',
    v_dedupe,
    p_season_id
  );

  RETURN coalesce(v_count, 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.club_holiday_inbox_announce(text, bigint, text, timestamptz, timestamptz, int, bigint)
  FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.trg_club_owner_holidays_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.club_holiday_inbox_announce(
      'booked',
      NEW.id,
      NEW.club_short_name,
      NEW.starts_at,
      NEW.ends_at,
      NEW.day_count,
      NEW.season_id
    );
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.starts_at IS DISTINCT FROM OLD.starts_at
       OR NEW.ends_at IS DISTINCT FROM OLD.ends_at
       OR NEW.day_count IS DISTINCT FROM OLD.day_count THEN
      PERFORM public.club_holiday_inbox_announce(
        'amended',
        NEW.id,
        NEW.club_short_name,
        NEW.starts_at,
        NEW.ends_at,
        NEW.day_count,
        NEW.season_id
      );
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.club_holiday_inbox_announce(
      'cancelled',
      OLD.id,
      OLD.club_short_name,
      OLD.starts_at,
      OLD.ends_at,
      OLD.day_count,
      OLD.season_id
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS club_owner_holidays_inbox_trg ON public.club_owner_holidays;
CREATE TRIGGER club_owner_holidays_inbox_trg
  AFTER INSERT OR UPDATE OR DELETE ON public.club_owner_holidays
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_club_owner_holidays_inbox();

-- ---------------------------------------------------------------------------
-- Badge status map: club_short_name → UH / OH (ended = omitted)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_holiday_status_map()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_map jsonb := '{}'::jsonb;
  v_row record;
  v_code text;
  v_status text;
  v_existing text;
BEGIN
  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  FOR v_row IN
    SELECT
      h.club_short_name,
      h.starts_at,
      h.ends_at,
      CASE
        WHEN now() >= h.starts_at AND now() < h.ends_at THEN 'active'
        WHEN now() < h.starts_at THEN 'upcoming'
        ELSE 'ended'
      END AS status
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season
      AND h.ends_at > now()
    ORDER BY h.starts_at
  LOOP
    IF v_row.status = 'active' THEN
      v_code := 'OH';
      v_status := 'active';
    ELSIF v_row.status = 'upcoming' THEN
      v_code := 'UH';
      v_status := 'upcoming';
    ELSE
      CONTINUE;
    END IF;

    v_existing := v_map #>> ARRAY[v_row.club_short_name, 'code'];
    -- Active (OH) wins over upcoming (UH) if both present
    IF v_existing = 'OH' AND v_code = 'UH' THEN
      CONTINUE;
    END IF;

    v_map := v_map || jsonb_build_object(
      v_row.club_short_name,
      jsonb_build_object(
        'code', v_code,
        'status', v_status,
        'starts_at', v_row.starts_at,
        'ends_at', v_row.ends_at
      )
    );
  END LOOP;

  RETURN v_map;
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_holiday_status_map() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_holiday_status_map() TO authenticated;

-- ---------------------------------------------------------------------------
-- Directory: holidays + early-play fixtures (public identity only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_holidays_directory()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_holidays jsonb := '[]'::jsonb;
  v_h record;
  v_id jsonb;
  v_fixtures jsonb;
  v_status text;
  v_code text;
BEGIN
  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object(
      'season_id', null,
      'holidays', '[]'::jsonb,
      'generated_at', now()
    );
  END IF;

  FOR v_h IN
    SELECT h.*
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season
      AND h.ends_at > now()
    ORDER BY
      CASE WHEN now() >= h.starts_at AND now() < h.ends_at THEN 0 ELSE 1 END,
      h.starts_at
  LOOP
    IF now() >= v_h.starts_at AND now() < v_h.ends_at THEN
      v_status := 'active';
      v_code := 'OH';
    ELSE
      v_status := 'upcoming';
      v_code := 'UH';
    END IF;

    v_id := public.club_holiday_public_identity(v_h.club_short_name);

    SELECT coalesce(jsonb_agg(x ORDER BY x.gpsl_month, x.home_club, x.away_club), '[]'::jsonb)
    INTO v_fixtures
    FROM (
      SELECT
        f.id AS fixture_id,
        f.competition,
        f.gpsl_month,
        f.home_club_short_name AS home_club,
        f.away_club_short_name AS away_club,
        f.status,
        cal.unlock_at,
        cal.lock_at
      FROM public.competition_fixtures f
      JOIN public.competition_season_calendar cal
        ON cal.season_id = f.season_id
       AND cal.gpsl_month = f.gpsl_month
      WHERE f.season_id = v_season
        AND f.status = 'scheduled'
        AND v_h.club_short_name IN (f.home_club_short_name, f.away_club_short_name)
        AND cal.unlock_at < v_h.ends_at
        AND cal.lock_at > v_h.starts_at
        AND now() < cal.lock_at
    ) x;

    v_holidays := v_holidays || jsonb_build_array(
      jsonb_build_object(
        'holiday_id', v_h.id,
        'club_short_name', v_h.club_short_name,
        'club_name', v_id->>'club_name',
        'owner_tag', v_id->>'owner_tag',
        'owner_id', nullif(v_id->>'owner_id', ''),
        'starts_at', v_h.starts_at,
        'ends_at', v_h.ends_at,
        'day_count', v_h.day_count,
        'status', v_status,
        'status_code', v_code,
        'fixtures', coalesce(v_fixtures, '[]'::jsonb)
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season,
    'holidays', v_holidays,
    'generated_at', now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_holidays_directory() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_holidays_directory() TO authenticated;

COMMENT ON FUNCTION public.owner_holidays_directory() IS
  'Public holiday board: UH/OH owners + early-play fixtures. Club name + owner tag only (no email).';

NOTIFY pgrst, 'reload schema';
