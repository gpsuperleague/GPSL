-- Tariff outcomes for a confirmed video report.
-- fine_when: always | won_or_drew
-- match_effect: none | replay_if_won_or_drew
-- points_when: never | always | won_or_drew | instances
-- Existing tariffs stay "charge the amount, leave the result, no points".

ALTER TABLE public.competition_fine_tariff
  ADD COLUMN IF NOT EXISTS fine_when text NOT NULL DEFAULT 'always',
  ADD COLUMN IF NOT EXISTS match_effect text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS points_delta smallint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS points_when text NOT NULL DEFAULT 'never',
  ADD COLUMN IF NOT EXISTS points_min_instances smallint NOT NULL DEFAULT 2;

ALTER TABLE public.competition_fine_tariff
  DROP CONSTRAINT IF EXISTS competition_fine_tariff_fine_when_check;
ALTER TABLE public.competition_fine_tariff
  ADD CONSTRAINT competition_fine_tariff_fine_when_check
  CHECK (fine_when IN ('always', 'won_or_drew'));

ALTER TABLE public.competition_fine_tariff
  DROP CONSTRAINT IF EXISTS competition_fine_tariff_match_effect_check;
ALTER TABLE public.competition_fine_tariff
  ADD CONSTRAINT competition_fine_tariff_match_effect_check
  CHECK (match_effect IN ('none', 'replay_if_won_or_drew'));

ALTER TABLE public.competition_fine_tariff
  DROP CONSTRAINT IF EXISTS competition_fine_tariff_points_when_check;
ALTER TABLE public.competition_fine_tariff
  ADD CONSTRAINT competition_fine_tariff_points_when_check
  CHECK (points_when IN ('never', 'always', 'won_or_drew', 'instances'));

ALTER TABLE public.competition_fine_tariff
  DROP CONSTRAINT IF EXISTS competition_fine_tariff_points_min_check;
ALTER TABLE public.competition_fine_tariff
  ADD CONSTRAINT competition_fine_tariff_points_min_check
  CHECK (points_min_instances BETWEEN 1 AND 20);

CREATE OR REPLACE FUNCTION public.competition_admin_save_fine_tariff(p_tariff jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_tariff IS NULL OR jsonb_typeof(p_tariff) <> 'object' THEN
    RAISE EXCEPTION 'tariff must be a JSON object';
  END IF;

  IF btrim(coalesce(p_tariff->>'code', '')) = '' OR btrim(coalesce(p_tariff->>'label', '')) = '' THEN
    RAISE EXCEPTION 'Code and label required';
  END IF;

  INSERT INTO public.competition_fine_tariff (
    code, label, category, direction, amount, amount_mode, is_active, sort_order, on_video_report,
    fine_when, match_effect, points_delta, points_when, points_min_instances
  )
  VALUES (
    btrim(p_tariff->>'code'),
    btrim(p_tariff->>'label'),
    coalesce(p_tariff->>'category', 'matchday'),
    coalesce(p_tariff->>'direction', 'fine'),
    nullif(p_tariff->>'amount', '')::numeric,
    coalesce(p_tariff->>'amount_mode', 'fixed'),
    coalesce((p_tariff->>'is_active')::boolean, true),
    coalesce((p_tariff->>'sort_order')::smallint, 0),
    coalesce((p_tariff->>'on_video_report')::boolean, false),
    coalesce(p_tariff->>'fine_when', 'always'),
    coalesce(p_tariff->>'match_effect', 'none'),
    coalesce((p_tariff->>'points_delta')::smallint, 0),
    coalesce(p_tariff->>'points_when', 'never'),
    coalesce((p_tariff->>'points_min_instances')::smallint, 2)
  )
  ON CONFLICT (code) DO UPDATE
  SET
    label = excluded.label,
    category = excluded.category,
    direction = excluded.direction,
    amount = excluded.amount,
    amount_mode = excluded.amount_mode,
    is_active = excluded.is_active,
    sort_order = excluded.sort_order,
    on_video_report = CASE
      WHEN p_tariff ? 'on_video_report'
        THEN coalesce((p_tariff->>'on_video_report')::boolean, false)
      ELSE public.competition_fine_tariff.on_video_report
    END,
    fine_when = CASE
      WHEN p_tariff ? 'fine_when' THEN coalesce(p_tariff->>'fine_when', 'always')
      ELSE public.competition_fine_tariff.fine_when
    END,
    match_effect = CASE
      WHEN p_tariff ? 'match_effect' THEN coalesce(p_tariff->>'match_effect', 'none')
      ELSE public.competition_fine_tariff.match_effect
    END,
    points_delta = CASE
      WHEN p_tariff ? 'points_delta' THEN coalesce((p_tariff->>'points_delta')::smallint, 0)
      ELSE public.competition_fine_tariff.points_delta
    END,
    points_when = CASE
      WHEN p_tariff ? 'points_when' THEN coalesce(p_tariff->>'points_when', 'never')
      ELSE public.competition_fine_tariff.points_when
    END,
    points_min_instances = CASE
      WHEN p_tariff ? 'points_min_instances' THEN coalesce((p_tariff->>'points_min_instances')::smallint, 2)
      ELSE public.competition_fine_tariff.points_min_instances
    END,
    updated_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_confirm_tariff_outcome(
  p_club text,
  p_code text,
  p_amount_override numeric,
  p_note text,
  p_fixture_id bigint,
  p_season_id bigint,
  p_instances int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_t public.competition_fine_tariff%ROWTYPE;
  v_f public.competition_fixtures%ROWTYPE;
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_won boolean := false;
  v_pen text;
  v_charge boolean := true;
  v_points boolean := false;
  v_apply jsonb;
  v_replay jsonb;
  v_points_id bigint;
  v_instances int := greatest(coalesce(p_instances, 1), 1);
BEGIN
  SELECT * INTO v_t
  FROM public.competition_fine_tariff
  WHERE code = btrim(coalesce(p_code, ''));

  IF NOT FOUND THEN
    RETURN public.competition_apply_club_fine_tariff(
      p_club, p_code, p_amount_override, p_note, p_fixture_id, p_season_id
    );
  END IF;

  IF p_fixture_id IS NOT NULL THEN
    SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  END IF;

  IF v_f.id IS NOT NULL AND v_f.home_goals IS NOT NULL AND v_f.away_goals IS NOT NULL THEN
    v_pen := upper(btrim(coalesce(v_f.cup_pen_winner_club_short_name, '')));
    IF v_f.home_goals = v_f.away_goals THEN
      v_won := CASE WHEN v_pen = '' THEN true ELSE v_pen = v_club END;
    ELSIF v_f.home_goals > v_f.away_goals THEN
      v_won := v_club = upper(btrim(v_f.home_club_short_name));
    ELSE
      v_won := v_club = upper(btrim(v_f.away_club_short_name));
    END IF;
  END IF;

  v_charge := v_t.fine_when IS DISTINCT FROM 'won_or_drew' OR v_won;
  v_points := CASE v_t.points_when
    WHEN 'always' THEN v_t.points_delta <> 0
    WHEN 'won_or_drew' THEN v_won AND v_t.points_delta <> 0
    WHEN 'instances' THEN v_instances >= v_t.points_min_instances AND v_t.points_delta <> 0
    ELSE false
  END;

  IF v_charge THEN
    v_apply := public.competition_apply_club_fine_tariff(
      p_club, p_code, p_amount_override, p_note, p_fixture_id, p_season_id
    );
  ELSE
    v_apply := jsonb_build_object('ok', true, 'skipped', true, 'reason', 'result_stands');
  END IF;

  IF v_t.match_effect = 'replay_if_won_or_drew' AND v_won
     AND to_regprocedure('public.admin_fixture_reset_for_replay(bigint,text,text)') IS NOT NULL THEN
    BEGIN
      v_replay := public.admin_fixture_reset_for_replay(
        p_fixture_id,
        coalesce(v_t.label, p_code),
        'RESET FIXTURE REPLAY'
      );
    EXCEPTION WHEN OTHERS THEN
      v_replay := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  IF v_points
     AND to_regprocedure('public.match_video_apply_league_points(text,smallint,text,bigint)') IS NOT NULL THEN
    BEGIN
      v_points_id := public.match_video_apply_league_points(
        v_club,
        v_t.points_delta,
        coalesce(nullif(btrim(coalesce(p_note, '')), ''), v_t.label, p_code),
        p_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      v_points_id := NULL;
      v_apply := v_apply || jsonb_build_object('points_error', SQLERRM);
    END;
  END IF;

  RETURN coalesce(v_apply, '{}'::jsonb) || jsonb_build_object(
    'won_or_drew', v_won,
    'charged', v_charge,
    'replay', v_replay,
    'points_adjustment_id', v_points_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_confirm_tariff_outcome(text, text, numeric, text, bigint, bigint, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_confirm_tariff_outcome(text, text, numeric, text, bigint, bigint, int)
  TO service_role;

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric)'::regprocedure),
    E'\r\n',
    E'\n'
  );
  v_old := replace($old$
      v_apply := public.competition_apply_club_fine_tariff(
        v_r.accused_club_short_name,
        v_code,
        p_amount_override,
        coalesce(
          nullif(v_note, ''),
          format('Match video breach report #%s', p_report_id)
        ),
        v_r.fixture_id,
        v_r.season_id
      );$old$, E'\r\n', E'\n');
  v_new := replace($new$
      v_apply := public.match_video_confirm_tariff_outcome(
        v_r.accused_club_short_name,
        v_code,
        p_amount_override,
        coalesce(
          nullif(v_note, ''),
          format('Match video breach report #%s', p_report_id)
        ),
        v_r.fixture_id,
        v_r.season_id,
        nullif(v_item->>'instances', '')::int
      );$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'video report approve fine call not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$wire$;

NOTIFY pgrst, 'reload schema';

SELECT
  (SELECT fine_when FROM public.competition_fine_tariff WHERE code = 'non_display_player_instructions') AS instructions_when,
  position(
    'match_video_confirm_tariff_outcome'
    IN pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric)'::regprocedure)
  ) > 0 AS approve_uses_outcome;
