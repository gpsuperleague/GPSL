-- Match effect: admin decides at confirm time whether the fixture is replayed.

ALTER TABLE public.competition_fine_tariff
  DROP CONSTRAINT IF EXISTS competition_fine_tariff_match_effect_check;

ALTER TABLE public.competition_fine_tariff
  ADD CONSTRAINT competition_fine_tariff_match_effect_check
  CHECK (match_effect IN ('none', 'replay_if_won_or_drew', 'admin_decides'));

DROP FUNCTION IF EXISTS public.match_video_confirm_tariff_outcome(text, text, numeric, text, bigint, bigint, int);

CREATE OR REPLACE FUNCTION public.match_video_confirm_tariff_outcome(
  p_club text,
  p_code text,
  p_amount_override numeric,
  p_note text,
  p_fixture_id bigint,
  p_season_id bigint,
  p_instances int DEFAULT NULL,
  p_replay boolean DEFAULT NULL
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
  v_replay_now boolean := false;
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
  v_replay_now := (v_t.match_effect = 'replay_if_won_or_drew' AND v_won)
    OR (v_t.match_effect = 'admin_decides' AND p_replay IS TRUE);

  IF v_charge THEN
    v_apply := public.competition_apply_club_fine_tariff(
      p_club, p_code, p_amount_override, p_note, p_fixture_id, p_season_id
    );
  ELSE
    v_apply := jsonb_build_object('ok', true, 'skipped', true, 'reason', 'result_stands');
  END IF;

  IF v_replay_now
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
    'admin_replay', p_replay,
    'points_adjustment_id', v_points_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_confirm_tariff_outcome(text, text, numeric, text, bigint, bigint, int, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_confirm_tariff_outcome(text, text, numeric, text, bigint, bigint, int, boolean)
  TO service_role;

DO $wire$
DECLARE
  v_def text;
  v_old_sig text := 'p_amount_override numeric DEFAULT NULL::numeric)';
  v_new_sig text := 'p_amount_override numeric DEFAULT NULL::numeric, p_replay boolean DEFAULT NULL)';
  v_old_call text := $old$        v_r.season_id,
        nullif(v_item->>'instances', '')::int
      );$old$;
  v_new_call text := $new$        v_r.season_id,
        nullif(v_item->>'instances', '')::int,
        p_replay
      );$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric)'::regprocedure),
    E'\r\n',
    E'\n'
  );
  v_old_call := replace(v_old_call, E'\r\n', E'\n');
  v_new_call := replace(v_new_call, E'\r\n', E'\n');
  IF position(v_old_sig IN v_def) = 0 THEN
    RAISE EXCEPTION 'resolve signature not found';
  END IF;
  IF position(v_old_call IN v_def) = 0 THEN
    RAISE EXCEPTION 'resolve outcome call not found';
  END IF;
  v_def := replace(v_def, v_old_sig, v_new_sig);
  v_def := replace(v_def, v_old_call, v_new_call);
  EXECUTE v_def;
END;
$wire$;

DROP FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric);

GRANT EXECUTE ON FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric, boolean)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT
  (
    SELECT pg_get_constraintdef(oid)
    FROM pg_constraint
    WHERE conname = 'competition_fine_tariff_match_effect_check'
  ) AS match_check,
  to_regprocedure(
    'public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'
  ) IS NOT NULL AS approve_has_replay,
  to_regprocedure(
    'public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric)'
  ) IS NOT NULL AS approve_old,
  position(
    'p_replay'
    IN pg_get_functiondef(
      'public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'::regprocedure
    )
  ) > 0 AS approve_passes_replay;
