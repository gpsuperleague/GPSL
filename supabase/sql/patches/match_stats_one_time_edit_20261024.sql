-- =============================================================================
-- One-time club match-stats edit while the GPSL month the result was posted
-- is still the active month.
--
-- Window = result_posted_gpsl_month (active month when fixture became played),
-- NOT necessarily fixture.gpsl_month (catch-up / early-play posted in Aug).
-- Each side gets one edit of their own stats. Score unchanged.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS result_posted_at timestamptz;

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS result_posted_gpsl_month text;

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS home_stats_edit_used_at timestamptz;

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS away_stats_edit_used_at timestamptz;

COMMENT ON COLUMN public.competition_fixtures.result_posted_gpsl_month IS
  'Active GPSL month when the fixture became played — one-time stats edit window.';

CREATE OR REPLACE FUNCTION public.trg_fixture_stamp_result_posted_month()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text;
BEGIN
  IF NEW.status = 'played'
     AND OLD.status IS DISTINCT FROM 'played' THEN
    IF NEW.result_posted_at IS NULL THEN
      NEW.result_posted_at := now();
    END IF;
    IF nullif(btrim(coalesce(NEW.result_posted_gpsl_month, '')), '') IS NULL THEN
      BEGIN
        v_month := public.competition_active_gpsl_month(NEW.season_id, now());
      EXCEPTION WHEN OTHERS THEN
        v_month := NULL;
      END;
      NEW.result_posted_gpsl_month := coalesce(
        nullif(btrim(lower(coalesce(v_month, ''))), ''),
        nullif(btrim(lower(coalesce(NEW.gpsl_month, ''))), '')
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_fixture_stamp_result_posted_month ON public.competition_fixtures;
CREATE TRIGGER trg_fixture_stamp_result_posted_month
  BEFORE UPDATE OF status ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_fixture_stamp_result_posted_month();

UPDATE public.competition_fixtures f
SET
  result_posted_at = coalesce(
    f.result_posted_at,
    (
      SELECT s.responded_at
      FROM public.competition_result_submissions s
      WHERE s.fixture_id = f.id AND s.status = 'confirmed'
      ORDER BY s.responded_at DESC NULLS LAST
      LIMIT 1
    ),
    now()
  ),
  result_posted_gpsl_month = coalesce(
    nullif(btrim(lower(f.result_posted_gpsl_month)), ''),
    nullif(btrim(lower(f.gpsl_month)), '')
  )
WHERE f.status = 'played'
  AND (
    f.result_posted_at IS NULL
    OR nullif(btrim(coalesce(f.result_posted_gpsl_month, '')), '') IS NULL
  );

CREATE OR REPLACE FUNCTION public.competition_match_stats_edit_info(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_f public.competition_fixtures;
  v_active text;
  v_side text;
  v_used timestamptz;
  v_can boolean := false;
  v_reason text := NULL;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'can_edit', false, 'reason', 'No club linked');
  END IF;

  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'can_edit', false, 'reason', 'Fixture not found');
  END IF;

  IF upper(v_f.home_club_short_name) = v_club THEN
    v_side := 'home';
    v_used := v_f.home_stats_edit_used_at;
  ELSIF upper(v_f.away_club_short_name) = v_club THEN
    v_side := 'away';
    v_used := v_f.away_stats_edit_used_at;
  ELSE
    RETURN jsonb_build_object('ok', false, 'can_edit', false, 'reason', 'Not your fixture');
  END IF;

  IF v_f.status IS DISTINCT FROM 'played' THEN
    RETURN jsonb_build_object(
      'ok', true, 'can_edit', false, 'side', v_side,
      'reason', 'Result not confirmed yet',
      'window_month', v_f.result_posted_gpsl_month,
      'edit_used', v_used IS NOT NULL
    );
  END IF;

  BEGIN
    v_active := lower(nullif(btrim(coalesce(
      public.competition_active_gpsl_month(v_f.season_id, now()), ''
    )), ''));
  EXCEPTION WHEN OTHERS THEN
    v_active := NULL;
  END;

  IF v_used IS NOT NULL THEN
    v_reason := 'You already used your one-time stats edit for this match';
  ELSIF nullif(btrim(coalesce(v_f.result_posted_gpsl_month, '')), '') IS NULL THEN
    v_reason := 'No edit window on this fixture';
  ELSIF v_active IS NULL THEN
    v_reason := 'No active GPSL month';
  ELSIF v_active <> lower(btrim(v_f.result_posted_gpsl_month)) THEN
    v_reason := format(
      'Edit window was GPSL %s (when the result was posted) — current month is %s',
      initcap(v_f.result_posted_gpsl_month),
      initcap(v_active)
    );
  ELSE
    v_can := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'can_edit', v_can,
    'side', v_side,
    'reason', v_reason,
    'window_month', lower(v_f.result_posted_gpsl_month),
    'active_month', v_active,
    'edit_used', v_used IS NOT NULL,
    'edit_used_at', v_used,
    'home_goals', v_f.home_goals,
    'away_goals', v_f.away_goals,
    'fixture_gpsl_month', lower(v_f.gpsl_month)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_match_stats_edit_info(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_match_stats_edit_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint;
  v_active text;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'fixtures', '[]'::jsonb);
  END IF;

  SELECT s.id,
         lower(nullif(btrim(coalesce(
           public.competition_active_gpsl_month(s.id, now()), ''
         )), ''))
  INTO v_season, v_active
  FROM public.competition_seasons s
  WHERE s.is_current
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL OR v_active IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'fixtures', '[]'::jsonb, 'active_month', v_active);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'active_month', v_active,
    'fixtures', coalesce((
      SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id DESC)
      FROM (
        SELECT
          f.id,
          f.matchday,
          f.gpsl_month,
          f.division,
          f.competition_type,
          f.cup_code,
          f.cup_round,
          f.home_club_short_name,
          f.away_club_short_name,
          ch."Club" AS home_club_name,
          ca."Club" AS away_club_name,
          f.home_goals,
          f.away_goals,
          f.result_posted_gpsl_month,
          CASE
            WHEN upper(f.home_club_short_name) = v_club THEN 'home'
            ELSE 'away'
          END AS side
        FROM public.competition_fixtures f
        LEFT JOIN public."Clubs" ch ON ch."ShortName" = f.home_club_short_name
        LEFT JOIN public."Clubs" ca ON ca."ShortName" = f.away_club_short_name
        WHERE f.season_id = v_season
          AND f.status = 'played'
          AND (
            upper(f.home_club_short_name) = v_club
            OR upper(f.away_club_short_name) = v_club
          )
          AND lower(btrim(coalesce(f.result_posted_gpsl_month, ''))) = v_active
          AND (
            (upper(f.home_club_short_name) = v_club AND f.home_stats_edit_used_at IS NULL)
            OR (upper(f.away_club_short_name) = v_club AND f.away_stats_edit_used_at IS NULL)
          )
      ) x
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_match_stats_edit_list() TO authenticated;

-- Apply edit: reuse stats apply; skip discipline re-issue (cards update on rows only)
CREATE OR REPLACE FUNCTION public.competition_edit_club_match_stats(
  p_fixture_id bigint,
  p_player_stats jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_info jsonb;
  v_f public.competition_fixtures;
  v_expected int;
  v_side text;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_info := public.competition_match_stats_edit_info(p_fixture_id);
  IF coalesce((v_info->>'can_edit')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION '%', coalesce(v_info->>'reason', 'Cannot edit match stats');
  END IF;

  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  v_side := v_info->>'side';

  IF v_side = 'home' THEN
    v_expected := coalesce(v_f.home_goals, 0);
  ELSE
    v_expected := coalesce(v_f.away_goals, 0);
  END IF;

  -- Claim the one-time edit first (race-safe), then rewrite stats.
  IF v_side = 'home' THEN
    UPDATE public.competition_fixtures
    SET home_stats_edit_used_at = now()
    WHERE id = p_fixture_id
      AND home_stats_edit_used_at IS NULL;
  ELSE
    UPDATE public.competition_fixtures
    SET away_stats_edit_used_at = now()
    WHERE id = p_fixture_id
      AND away_stats_edit_used_at IS NULL;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edit already used (race)';
  END IF;

  BEGIN
    PERFORM public.competition_apply_club_player_stats(
      v_f.id,
      v_f.season_id,
      v_club,
      p_player_stats,
      v_expected
    );
  EXCEPTION WHEN OTHERS THEN
    IF v_side = 'home' THEN
      UPDATE public.competition_fixtures
      SET home_stats_edit_used_at = NULL
      WHERE id = p_fixture_id;
    ELSE
      UPDATE public.competition_fixtures
      SET away_stats_edit_used_at = NULL
      WHERE id = p_fixture_id;
    END IF;
    RAISE;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'club', v_club,
    'side', v_side
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_edit_club_match_stats(bigint, jsonb)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  count(*) FILTER (WHERE f.status = 'played' AND f.result_posted_gpsl_month IS NOT NULL) AS stamped_played,
  count(*) FILTER (WHERE f.status = 'played') AS played_total
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current;
