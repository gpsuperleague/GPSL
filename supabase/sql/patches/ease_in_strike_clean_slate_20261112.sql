-- Nullify ease-in strikes so the November lock starts owners at zero.
-- Waived fine rows stay, so the same incidents are not charged again.
-- Compensation payments are left alone.
-- Safe re-run: only rows not yet voided are marked, and the count is set to 0.

ALTER TABLE public.competition_fixture_no_show_events
  ADD COLUMN IF NOT EXISTS ease_in_void boolean NOT NULL DEFAULT false;

DO $reply_col$
BEGIN
  IF to_regclass('public.competition_fixture_reply_strikes') IS NOT NULL THEN
    ALTER TABLE public.competition_fixture_reply_strikes
      ADD COLUMN IF NOT EXISTS ease_in_void boolean NOT NULL DEFAULT false;
  END IF;
END;
$reply_col$;

DO $prop_col$
BEGIN
  IF to_regclass('public.competition_fixture_proposal_strikes') IS NOT NULL THEN
    ALTER TABLE public.competition_fixture_proposal_strikes
      ADD COLUMN IF NOT EXISTS ease_in_void boolean NOT NULL DEFAULT false;
  END IF;
END;
$prop_col$;

UPDATE public.competition_fixture_no_show_events
SET ease_in_void = true
WHERE NOT ease_in_void;

DO $void_rest$
BEGIN
  IF to_regclass('public.competition_fixture_reply_strikes') IS NOT NULL THEN
    UPDATE public.competition_fixture_reply_strikes
    SET ease_in_void = true
    WHERE NOT ease_in_void;
  END IF;
  IF to_regclass('public.competition_fixture_proposal_strikes') IS NOT NULL THEN
    UPDATE public.competition_fixture_proposal_strikes
    SET ease_in_void = true
    WHERE NOT ease_in_void;
  END IF;
END;
$void_rest$;

UPDATE public.competition_owner_season_strikes
SET strike_count = 0,
    updated_at = now()
WHERE strike_count <> 0;

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_strike_count(
  p_fixture_id bigint,
  p_club text
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (
    coalesce((
      SELECT count(*)::int
      FROM public.competition_fixture_no_show_events e
      WHERE e.fixture_id = p_fixture_id
        AND e.club_short_name = p_club
        AND NOT coalesce(e.ease_in_void, false)
    ), 0)
    + coalesce((
      SELECT count(*)::int
      FROM public.competition_fixture_proposal_strikes s
      WHERE s.fixture_id = p_fixture_id
        AND s.club_short_name = p_club
        AND NOT coalesce(s.ease_in_void, false)
    ), 0)
    + CASE
        WHEN to_regclass('public.competition_fixture_reply_strikes') IS NULL THEN 0
        ELSE coalesce((
          SELECT count(*)::int
          FROM public.competition_fixture_reply_strikes r
          WHERE r.fixture_id = p_fixture_id
            AND r.club_short_name = p_club
            AND NOT coalesce(r.ease_in_void, false)
        ), 0)
      END
  );
$$;

SELECT
  (SELECT count(*) FROM public.competition_fixture_no_show_events WHERE NOT ease_in_void) AS noshows_still_counting,
  (SELECT coalesce(sum(strike_count), 0) FROM public.competition_owner_season_strikes) AS season_strikes_left,
  (SELECT count(*) FROM public.competition_fine_applied WHERE waived) AS waived_kept,
  (SELECT count(*) FROM public.competition_fine_applied WHERE NOT waived) AS charged_kept,
  public.gpsl_auto_fines_active() AS fines_active;
