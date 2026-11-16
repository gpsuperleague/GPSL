-- A scheduled match with no result yet is not an injury absence when it was
-- already underway before the injury was known (the direct aftermath), or when
-- it sits before the injury match. The absence is laid on the matches either side.

CREATE OR REPLACE FUNCTION public.competition_injury_skip_played_unentered(
  p_fixture_id bigint,
  p_known_at timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.competition_result_submissions s
      WHERE s.fixture_id = p_fixture_id
    )
    OR (
      (
        SELECT count(DISTINCT c.club_short_name)
        FROM public.competition_fixture_checkin c
        JOIN public.competition_fixtures fx ON fx.id = c.fixture_id
        WHERE c.fixture_id = p_fixture_id
          AND c.club_short_name IN (fx.home_club_short_name, fx.away_club_short_name)
      ) >= 2
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule sch
        WHERE sch.fixture_id = p_fixture_id
          AND sch.agreed_kickoff_at > coalesce(p_known_at, now())
      )
    );
$function$;

REVOKE ALL ON FUNCTION public.competition_injury_skip_played_unentered(bigint, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_injury_skip_played_unentered(bigint, timestamptz)
  TO service_role;

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_injury_assign_fixtures(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('competition_injury_skip_played_unentered' IN v_def) > 0 THEN
    RETURN;
  END IF;
  v_old := replace($old$          WHERE src.id = v_inj.source_fixture_id
        )
      )
    ORDER BY$old$, E'\r\n', E'\n');
  v_new := replace($new$          WHERE src.id = v_inj.source_fixture_id
        )
      )
      -- Still-scheduled matches before the injury match are already excluded above.
      -- Skip one that was already kicked off, checked in, or had a result typed
      -- before this injury was known, and continue on the matches either side.
      AND NOT public.competition_injury_skip_played_unentered(
        f.id, v_inj.created_at
      )
    ORDER BY$new$, E'\r\n', E'\n');
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'injury assign aftermath needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$wire$;

SELECT public.competition_injury_assign_fixtures(897);

SELECT jsonb_build_object(
  'wired', position(
    'competition_injury_skip_played_unentered'
    IN pg_get_functiondef('public.competition_injury_assign_fixtures(bigint)'::regprocedure)
  ) > 0,
  'besiktas_still_on_injury', EXISTS (
    SELECT 1
    FROM public.competition_player_injury_fixtures iff
    WHERE iff.injury_id = 897
      AND iff.fixture_id = 9456
  ),
  'out_left', (SELECT i.matches_out_remaining FROM public.competition_player_injuries i WHERE i.id = 897),
  'rec_left', (SELECT i.recovery_remaining FROM public.competition_player_injuries i WHERE i.id = 897),
  'absences', (
    SELECT coalesce(string_agg(
      iff.phase || ' ' ||
      CASE
        WHEN f.competition_type = 'cup' THEN coalesce(f.cup_code, 'cup') || ' R' || coalesce(f.cup_round::text, '?')
        ELSE 'MD' || coalesce(f.matchday::text, '?')
      END
      || ' ' || f.home_club_short_name || ' vs ' || f.away_club_short_name,
      ' | ' ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    ), '')
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_fixtures f ON f.id = iff.fixture_id
    WHERE iff.injury_id = 897
      AND iff.served = false
  )
);
