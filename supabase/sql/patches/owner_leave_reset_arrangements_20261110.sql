-- An arranged kick-off belongs to the two owners who agreed it.
-- When either of them leaves that club (club goes vacant, or a different owner
-- takes over), every unplayed arrangement for that club in the current season
-- is cleared. No fine, no reply miss, and no no-show for the reset.
-- A later owner arranges again from their own availability.
-- The cleared match stays unfined through the GPSL month it belongs to.
-- After that month has locked, a match that is still not arranged can be fined
-- under the normal rules.
-- Already played, forfeited, or void results are left as they are.
-- Fines already charged before the owner left are left as they are.

ALTER TABLE public.competition_fixture_schedule
  ADD COLUMN IF NOT EXISTS owner_change_reset_at timestamptz;

COMMENT ON COLUMN public.competition_fixture_schedule.owner_change_reset_at IS
  'Set when an agreed or in-progress kick-off was cleared because an owner left. Shields scheduling fines while the fixture stays unscheduled, until its play month has locked.';

CREATE OR REPLACE FUNCTION public.competition_clear_arranged_fixtures_for_club(
  p_club text,
  p_agreed_before timestamptz DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_season bigint;
  v_ids bigint[];
  v_id bigint;
  v_home text;
  v_away text;
  v_month text;
  v_other text;
  v_label text;
BEGIN
  IF v_club = '' THEN
    RETURN 0;
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT coalesce(array_agg(f.id), ARRAY[]::bigint[])
  INTO v_ids
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.status = 'scheduled'
    AND (v_season IS NULL OR f.season_id = v_season)
    AND (
      upper(btrim(f.home_club_short_name)) = v_club
      OR upper(btrim(f.away_club_short_name)) = v_club
    )
    AND (
      s.status IN ('agreed', 'negotiating')
      OR s.agreed_kickoff_at IS NOT NULL
      OR s.pending_proposal_id IS NOT NULL
    )
    AND (
      p_agreed_before IS NULL
      OR p_agreed_before > coalesce(
        greatest(
          (
            SELECT max(p.created_at)
            FROM public.competition_fixture_schedule_proposal p
            WHERE p.fixture_id = f.id
              AND p.status = 'accepted'
          ),
          (
            SELECT max(o.applied_at)
            FROM public.competition_fixture_mutual_override o
            WHERE o.fixture_id = f.id
              AND o.status = 'applied'
          )
        ),
        s.updated_at
      )
    );

  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  UPDATE public.competition_fixture_schedule s
  SET
    pending_proposal_id = NULL,
    status = 'unscheduled',
    agreed_kickoff_at = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    home_proposal_count = 0,
    away_proposal_count = 0,
    discord_hint_shown = false,
    mutual_override_used = false,
    play_attempt_count = 0,
    open_play_active = false,
    open_play_started_at = NULL,
    open_play_deadline_gpsl_month = NULL,
    owner_change_reset_at = now(),
    updated_at = now()
  WHERE s.fixture_id = ANY (v_ids);

  UPDATE public.competition_fixture_schedule_proposal p
  SET status = 'withdrawn'
  WHERE p.fixture_id = ANY (v_ids)
    AND p.status = 'pending';

  IF to_regclass('public.competition_fixture_mutual_override') IS NOT NULL THEN
    UPDATE public.competition_fixture_mutual_override o
    SET status = 'cancelled'
    WHERE o.fixture_id = ANY (v_ids)
      AND o.status = 'pending';
  END IF;

  IF to_regclass('public.competition_fixture_checkin') IS NOT NULL THEN
    DELETE FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = ANY (v_ids);
  END IF;

  IF to_regclass('public.competition_fixture_play_now_session') IS NOT NULL THEN
    DELETE FROM public.competition_fixture_play_now_session n
    WHERE n.fixture_id = ANY (v_ids);
  END IF;

  SELECT coalesce(nullif(btrim(c."Club"), ''), c."ShortName", v_club)
  INTO v_label
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = v_club
  LIMIT 1;
  v_label := coalesce(v_label, v_club);

  FOREACH v_id IN ARRAY v_ids LOOP
      SELECT
        upper(btrim(f.home_club_short_name)),
        upper(btrim(f.away_club_short_name)),
        f.gpsl_month
      INTO v_home, v_away, v_month
      FROM public.competition_fixtures f
      WHERE f.id = v_id;

      FOREACH v_other IN ARRAY ARRAY[v_home, v_away] LOOP
        IF v_other IS NULL THEN
          CONTINUE;
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM public."Clubs" c
          WHERE upper(btrim(c."ShortName")) = v_other
            AND c.owner_id IS NOT NULL
        ) THEN
          CONTINUE;
        END IF;

        BEGIN
          PERFORM public.owner_inbox_send(
            'match_rescheduled',
            'Kick-off cleared',
            v_label || ' changed owner, so the arranged time for this match has been cleared. Agree a new time from the current owners'' availability. No fine for this reset.',
            v_other,
            NULL,
            v_id,
            NULL, NULL, NULL,
            'fixture_schedule.html?fixture=' || v_id::text,
            'owner_left_reset:' || v_id::text || ':' || floor(extract(epoch FROM clock_timestamp()))::text,
            v_month,
            v_season,
            NULL
          );
        EXCEPTION WHEN OTHERS THEN
          RAISE NOTICE 'owner leave reset inbox skipped for fixture %: %', v_id, SQLERRM;
        END;
      END LOOP;
    END LOOP;

  RETURN coalesce(array_length(v_ids, 1), 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_clear_arranged_fixtures_for_club(text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_clear_arranged_fixtures_for_club(text, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.trg_clubs_owner_leave_reset_arrangements()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF OLD.owner_id IS NULL OR NEW.owner_id IS NOT DISTINCT FROM OLD.owner_id THEN
    RETURN NEW;
  END IF;

  PERFORM public.competition_clear_arranged_fixtures_for_club(NEW."ShortName");
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_owner_leave_reset_arrangements ON public."Clubs";
CREATE TRIGGER clubs_owner_leave_reset_arrangements
  AFTER UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clubs_owner_leave_reset_arrangements();

-- Scheduling fines stay off for a cleared match until its GPSL month has locked.
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(
  p_fixture_id bigint,
  p_club text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_home text;
  v_away text;
  v_season bigint;
  v_play_month text;
  v_opp text;
  v_assigned timestamptz;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_reset timestamptz;
  v_sched text;
  v_next timestamptz;
BEGIN
  IF v_club = '' OR p_fixture_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT
    upper(btrim(f.home_club_short_name)),
    upper(btrim(f.away_club_short_name)),
    f.season_id,
    f.gpsl_month
  INTO v_home, v_away, v_season, v_play_month
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF v_home IS NULL THEN
    RETURN false;
  END IF;

  IF v_club = v_home THEN
    v_opp := v_away;
  ELSIF v_club = v_away THEN
    v_opp := v_home;
  ELSE
    RETURN false;
  END IF;

  SELECT s.owner_change_reset_at, s.status
  INTO v_reset, v_sched
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  IF v_reset IS NOT NULL AND v_sched = 'unscheduled' THEN
    SELECT cal.lock_at
    INTO v_lock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season
      AND lower(btrim(cal.gpsl_month)) = lower(btrim(coalesce(v_play_month, '')))
    LIMIT 1;

    IF v_lock IS NULL OR v_reset < v_lock THEN
      IF v_lock IS NULL OR now() < v_lock + interval '36 hours' THEN
        RETURN true;
      END IF;
    ELSE
      SELECT min(cal2.lock_at)
      INTO v_next
      FROM public.competition_season_calendar cal2
      WHERE cal2.season_id = v_season
        AND cal2.lock_at > v_reset;

      IF v_next IS NULL OR now() < v_next + interval '36 hours' THEN
        RETURN true;
      END IF;
    END IF;
  END IF;

  IF to_regprocedure('public.competition_club_is_fixture_inactive(text,bigint)') IS NOT NULL THEN
    IF public.competition_club_is_fixture_inactive(v_opp, v_season) THEN
      RETURN true;
    END IF;
  ELSIF to_regprocedure('public.competition_club_is_vacant(text)') IS NOT NULL THEN
    IF public.competition_club_is_vacant(v_opp) THEN
      RETURN true;
    END IF;
  END IF;

  SELECT c.owner_assigned_at
  INTO v_assigned
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = v_opp
  LIMIT 1;

  IF v_assigned IS NULL OR nullif(btrim(coalesce(v_play_month, '')), '') IS NULL OR v_season IS NULL THEN
    RETURN false;
  END IF;

  SELECT cal.unlock_at, cal.lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_season
    AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_play_month))
  LIMIT 1;

  IF v_unlock IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_assigned >= v_unlock
    AND (v_lock IS NULL OR v_assigned <= v_lock);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_deadlines_suppressed_for_club(bigint, text) TO service_role;

-- Clubs already vacant: clear every current arrangement.
-- Clubs whose current owner arrived after the kick-off was agreed: clear that
-- kick-off only. A time agreed after the current owner arrived stays.
DO $already$
DECLARE
  r record;
  v_n integer;
  v_total integer := 0;
BEGIN
  FOR r IN
    SELECT c."ShortName", NULL::timestamptz AS agreed_before
    FROM public."Clubs" c
    WHERE c.owner_id IS NULL
    UNION ALL
    SELECT c."ShortName", c.owner_assigned_at
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND c.owner_assigned_at IS NOT NULL
    ORDER BY 1
  LOOP
    v_n := public.competition_clear_arranged_fixtures_for_club(r."ShortName", r.agreed_before);
    v_total := v_total + coalesce(v_n, 0);
  END LOOP;
  RAISE NOTICE 'Cleared % arranged fixture(s) left behind by an owner who has already gone.', v_total;
END;
$already$;

SELECT c."ShortName" AS vacant_club, f.id AS fixture_id, s.status, s.agreed_kickoff_at
FROM public."Clubs" c
JOIN public.competition_fixtures f
  ON (
    upper(btrim(f.home_club_short_name)) = upper(btrim(c."ShortName"))
    OR upper(btrim(f.away_club_short_name)) = upper(btrim(c."ShortName"))
  )
JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE c.owner_id IS NULL
  AND f.status = 'scheduled'
  AND (
    s.status IN ('agreed', 'negotiating')
    OR s.agreed_kickoff_at IS NOT NULL
  )
ORDER BY c."ShortName", f.id;
