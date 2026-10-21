-- =============================================================================
-- New-owner catch-up: keep unplayed fixtures in the play window longer
--
-- After appointment, fixtures involving that club stay playable through the join
-- GPSL month + 3 further months (league/cup normal grace still applies when
-- longer). Prevents window-expiry awards while a new owner is catching up.
--
-- Requires: new_owner_scheduling_fine_grace_20261021.sql (owner_assigned_at).
-- Safe re-run.
-- =============================================================================

-- Extra GPSL months after the appointment month (inclusive of join month in
-- the through_sort calc: join_sort + 3 ⇒ join month plus three more locks).
CREATE OR REPLACE FUNCTION public.club_new_owner_catchup_extra_months()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 3 $$;

CREATE OR REPLACE FUNCTION public.club_new_owner_catchup_through_sort(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_assigned timestamptz;
  v_join_sort int;
BEGIN
  IF v_club = '' OR p_season_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c.owner_assigned_at
  INTO v_assigned
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
     OR upper(c."ShortName") = v_club
  LIMIT 1;

  IF v_assigned IS NULL THEN
    RETURN NULL;
  END IF;

  -- GPSL month that was open when they were appointed
  SELECT public.competition_gpsl_month_sort(cal.gpsl_month)
  INTO v_join_sort
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = p_season_id
    AND cal.unlock_at IS NOT NULL
    AND cal.unlock_at <= v_assigned
  ORDER BY cal.unlock_at DESC
  LIMIT 1;

  IF v_join_sort IS NULL THEN
    SELECT public.competition_gpsl_month_sort(cal.gpsl_month)
    INTO v_join_sort
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = p_season_id
      AND cal.unlock_at IS NOT NULL
    ORDER BY cal.unlock_at ASC
    LIMIT 1;
  END IF;

  IF v_join_sort IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_join_sort + public.club_new_owner_catchup_extra_months();
END;
$function$;

REVOKE ALL ON FUNCTION public.club_new_owner_catchup_through_sort(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_new_owner_catchup_through_sort(bigint, text)
  TO authenticated, service_role, anon;

COMMENT ON FUNCTION public.club_new_owner_catchup_through_sort(bigint, text) IS
  'Last GPSL month sort order while a new owner''s club fixtures stay in the catch-up play window (join month + 3).';

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_new_owner_catchup_through_sort(
  p_fixture_id bigint
)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f record;
  v_home int;
  v_away int;
BEGIN
  SELECT f.season_id, f.home_club_short_name, f.away_club_short_name
  INTO v_f
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_home := public.club_new_owner_catchup_through_sort(
    v_f.season_id, v_f.home_club_short_name
  );
  v_away := public.club_new_owner_catchup_through_sort(
    v_f.season_id, v_f.away_club_short_name
  );

  IF v_home IS NULL THEN
    RETURN v_away;
  END IF;
  IF v_away IS NULL THEN
    RETURN v_home;
  END IF;
  RETURN greatest(v_home, v_away);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_new_owner_catchup_through_sort(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_new_owner_catchup_through_sort(bigint)
  TO authenticated, service_role, anon;

-- ---------------------------------------------------------------------------
-- Play window: normal grace OR new-owner catch-up floor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_within_play_window(
  p_fixture_id bigint,
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play_sort int;
  v_active text;
  v_active_sort int;
  v_grace int;
  v_owner_through int;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_play_sort := public.competition_gpsl_month_sort(v_f.gpsl_month);
  v_grace := public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month);
  v_active := public.competition_active_gpsl_month(v_f.season_id, p_at);

  IF v_active IS NULL THEN
    RETURN NOT public.match_schedule_fixture_play_month_closed(p_fixture_id);
  END IF;

  v_active_sort := public.competition_gpsl_month_sort(v_active);
  IF v_active_sort IS NULL OR v_play_sort IS NULL THEN
    RETURN true;
  END IF;

  IF v_active_sort <= v_play_sort + v_grace THEN
    RETURN true;
  END IF;

  v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
  IF v_owner_through IS NOT NULL AND v_active_sort <= v_owner_through THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Window expiry (month-lock awards): do not expire during new-owner catch-up
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_play_window_expired(
  p_fixture_id bigint,
  p_closed_gpsl_month text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play_sort int;
  v_closed_sort int;
  v_grace int;
  v_owner_through int;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN false;
  END IF;

  v_play_sort := public.competition_gpsl_month_sort(v_f.gpsl_month);
  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);
  v_grace := public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month);

  IF v_play_sort IS NULL OR v_closed_sort IS NULL THEN
    RETURN false;
  END IF;

  IF v_closed_sort < v_play_sort + v_grace THEN
    RETURN false;
  END IF;

  v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
  IF v_owner_through IS NOT NULL AND v_closed_sort <= v_owner_through THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

NOTIFY pgrst, 'reload schema';

-- Sample: ACM catch-up through sort vs current month
SELECT
  c."ShortName",
  c.owner,
  c.owner_assigned_at,
  public.club_new_owner_catchup_through_sort(s.id, c."ShortName") AS catchup_through_sort,
  public.competition_active_gpsl_month(s.id, now()) AS active_month
FROM public."Clubs" c
CROSS JOIN LATERAL (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
) s
WHERE c."ShortName" = 'ACM';
