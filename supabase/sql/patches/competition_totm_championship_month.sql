-- Championship A+B combined Team of the Month (separate from Super League TOTM).
-- Run after competition_totm_tots_awards.sql

ALTER TABLE public.competition_season_award
  DROP CONSTRAINT IF EXISTS competition_season_award_award_type_check;

ALTER TABLE public.competition_season_award
  ADD CONSTRAINT competition_season_award_award_type_check CHECK (
    award_type IN (
      'ballon_dor',
      'golden_boot',
      'golden_playmaker',
      'golden_glove',
      'season_potm',
      'team_of_month',
      'championship_team_of_month',
      'team_of_season',
      'championship_player_of_season'
    )
  );

CREATE UNIQUE INDEX IF NOT EXISTS competition_season_award_championship_team_month_player_idx
  ON public.competition_season_award (season_id, gpsl_month, award_type, player_id)
  WHERE award_type = 'championship_team_of_month';

CREATE OR REPLACE FUNCTION public.competition_store_period_team(
  p_season_id bigint,
  p_season_label text,
  p_gpsl_month text,
  p_period_kind text,
  p_division_scope text,
  p_team jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_team_id bigint;
  v_member jsonb;
  v_award_type text;
BEGIN
  IF p_team IS NULL OR NOT (p_team ? 'lineup') THEN
    RETURN NULL;
  END IF;

  v_award_type := CASE
    WHEN p_period_kind = 'month' AND p_division_scope = 'superleague' THEN 'team_of_month'
    WHEN p_period_kind = 'month' AND p_division_scope = 'championship' THEN 'championship_team_of_month'
    WHEN p_period_kind = 'season' AND p_division_scope = 'superleague' THEN 'team_of_season'
    ELSE NULL
  END;

  DELETE FROM public.competition_period_team_member m
  USING public.competition_period_team t
  WHERE m.team_id = t.id
    AND t.season_id = p_season_id
    AND t.period_kind = p_period_kind
    AND t.division_scope = p_division_scope
    AND coalesce(t.gpsl_month, '') = coalesce(p_gpsl_month, '');

  DELETE FROM public.competition_period_team
  WHERE season_id = p_season_id
    AND period_kind = p_period_kind
    AND division_scope = p_division_scope
    AND coalesce(gpsl_month, '') = coalesce(p_gpsl_month, '');

  IF p_period_kind = 'month' AND p_division_scope = 'superleague' THEN
    DELETE FROM public.competition_season_award
    WHERE season_id = p_season_id
      AND award_type = 'team_of_month'
      AND gpsl_month = p_gpsl_month;
  ELSIF p_period_kind = 'month' AND p_division_scope = 'championship' THEN
    DELETE FROM public.competition_season_award
    WHERE season_id = p_season_id
      AND award_type = 'championship_team_of_month'
      AND gpsl_month = p_gpsl_month;
  ELSIF p_period_kind = 'season' AND p_division_scope = 'superleague' THEN
    DELETE FROM public.competition_season_award
    WHERE season_id = p_season_id
      AND award_type = 'team_of_season';
  END IF;

  INSERT INTO public.competition_period_team (
    season_id, season_label, gpsl_month, period_kind, division_scope, formation_id, detail
  )
  VALUES (
    p_season_id,
    p_season_label,
    p_gpsl_month,
    p_period_kind,
    p_division_scope,
    p_team ->> 'formation_id',
    jsonb_build_object(
      'formation_id', p_team ->> 'formation_id',
      'division_scope', p_division_scope
    )
  )
  RETURNING id INTO v_team_id;

  FOR v_member IN
    SELECT value FROM jsonb_array_elements(p_team -> 'lineup')
  LOOP
    INSERT INTO public.competition_period_team_member (
      team_id, pitch_slot, slot_label, player_id, club_short_name,
      selection_score, appearances, goals, assists, avg_rating, clean_sheets
    )
    VALUES (
      v_team_id,
      v_member ->> 'pitch_slot',
      v_member ->> 'slot_label',
      v_member ->> 'player_id',
      v_member ->> 'club_short_name',
      coalesce((v_member ->> 'selection_score')::numeric, 0),
      coalesce((v_member ->> 'appearances')::int, 0),
      coalesce((v_member ->> 'goals')::int, 0),
      coalesce((v_member ->> 'assists')::int, 0),
      nullif(v_member ->> 'avg_rating', '')::numeric,
      coalesce((v_member ->> 'clean_sheets')::int, 0)
    );

    IF v_award_type IS NOT NULL THEN
      INSERT INTO public.competition_season_award (
        season_id, season_label, award_type, player_id, club_short_name,
        stat_value, gpsl_month, detail
      )
      VALUES (
        p_season_id,
        p_season_label,
        v_award_type,
        v_member ->> 'player_id',
        v_member ->> 'club_short_name',
        coalesce((v_member ->> 'selection_score')::numeric, 0),
        p_gpsl_month,
        jsonb_build_object(
          'formation_id', p_team ->> 'formation_id',
          'pitch_slot', v_member ->> 'pitch_slot',
          'slot_label', v_member ->> 'slot_label',
          'gpsl_month', p_gpsl_month,
          'division_scope', p_division_scope
        )
      )
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  RETURN v_team_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_compute_team_of_month(
  p_season_id bigint,
  p_gpsl_month text,
  p_division_scope text DEFAULT 'superleague'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text;
  v_candidates jsonb;
  v_team jsonb;
  v_team_id bigint;
  v_scope text := lower(btrim(coalesce(p_division_scope, 'superleague')));
BEGIN
  IF v_scope NOT IN ('superleague', 'championship') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_division_scope');
  END IF;

  SELECT label INTO v_label FROM public.competition_seasons WHERE id = p_season_id;

  SELECT coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb)
  INTO v_candidates
  FROM public.competition_player_month_stats_public s
  WHERE s.season_id = p_season_id
    AND s.gpsl_month = p_gpsl_month
    AND s.appearances >= 2
    AND (
      (v_scope = 'superleague' AND s.division = 'superleague')
      OR (v_scope = 'championship' AND s.division IN ('championship_a', 'championship_b'))
    );

  v_team := public.competition_pick_period_team(v_candidates);
  IF v_team IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_valid_xi',
      'gpsl_month', p_gpsl_month,
      'division_scope', v_scope
    );
  END IF;

  v_team_id := public.competition_store_period_team(
    p_season_id, v_label, p_gpsl_month, 'month', v_scope, v_team
  );

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', p_gpsl_month,
    'division_scope', v_scope,
    'team_id', v_team_id,
    'formation_id', v_team ->> 'formation_id'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_process_month_team_awards(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_scope text;
  v_job_key text;
  v_results jsonb := '[]'::jsonb;
  v_res jsonb;
BEGIN
  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    FOREACH v_scope IN ARRAY ARRAY['superleague', 'championship']::text[]
    LOOP
      v_job_key := 'team_of_month:' || v_scope || ':' || v_cal.gpsl_month;

      IF v_scope = 'superleague' AND EXISTS (
        SELECT 1
        FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = p_season_id
          AND j.job_key IN (
            v_job_key,
            'team_of_month:' || v_cal.gpsl_month
          )
      ) THEN
        CONTINUE;
      ELSIF EXISTS (
        SELECT 1
        FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = p_season_id
          AND j.job_key = v_job_key
      ) THEN
        CONTINUE;
      END IF;

      v_res := public.competition_compute_team_of_month(
        p_season_id,
        v_cal.gpsl_month,
        v_scope
      );

      INSERT INTO public.competition_season_calendar_jobs (
        season_id, job_key, gpsl_month, result
      )
      VALUES (
        p_season_id,
        v_job_key,
        v_cal.gpsl_month,
        coalesce(v_res, '{}'::jsonb)
      )
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result,
            gpsl_month = excluded.gpsl_month,
            ran_at = now();

      v_results := v_results || jsonb_build_array(
        jsonb_build_object(
          'gpsl_month', v_cal.gpsl_month,
          'division_scope', v_scope,
          'result', v_res
        )
      );
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'processed', v_results);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_compute_team_of_month(bigint, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
