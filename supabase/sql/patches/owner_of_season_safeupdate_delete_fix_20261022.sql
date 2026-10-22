-- Fix: competition_compute_owner_of_season fails under pg_safeupdate
-- ("DELETE requires a WHERE clause") when clearing the temp candidate table.
-- Re-apply the season compute function from owner_of_month_season_prizes_20261022.sql
-- OR run this file (same function body, DELETE ... WHERE true).

CREATE OR REPLACE FUNCTION public.competition_compute_owner_of_season(
  p_season_id bigint,
  p_division_scope text DEFAULT 'superleague'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_scope text := lower(nullif(btrim(coalesce(p_division_scope, '')), ''));
  v_season_label text;
  v_best record;
  v_owner_tag text;
  v_award_id bigint;
  v_prize numeric(14, 2);
  v_ledger bigint;
  v_scope_label text;
  v_metrics jsonb;
  r record;
  v_exp int;
  v_act int;
  v_over int;
  v_gap numeric;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_args');
  END IF;

  IF v_scope IS DISTINCT FROM 'superleague' AND v_scope IS DISTINCT FROM 'championship' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_scope');
  END IF;

  SELECT s.label INTO v_season_label
  FROM public.competition_seasons s
  WHERE s.id = p_season_id;

  IF v_season_label IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  v_prize := CASE v_scope
    WHEN 'championship' THEN 7500::numeric
    ELSE 10000::numeric
  END;
  v_scope_label := CASE v_scope
    WHEN 'championship' THEN 'Championship'
    ELSE 'Super League'
  END;

  CREATE TEMP TABLE IF NOT EXISTS _oot_season_cands (
    club_short_name text PRIMARY KEY,
    owner_id uuid NOT NULL,
    expected_position int NOT NULL,
    actual_position int NOT NULL,
    position_overachievement int NOT NULL,
    performance_gap numeric,
    division text
  ) ON COMMIT DROP;
  DELETE FROM _oot_season_cands WHERE true;

  FOR r IN
    SELECT
      s.club_short_name,
      s.division,
      c.owner_id
    FROM public.competition_club_seasons s
    INNER JOIN public."Clubs" c ON c."ShortName" = s.club_short_name
    WHERE s.season_id = p_season_id
      AND c.owner_id IS NOT NULL
      AND (
        (v_scope = 'superleague' AND s.division = 'superleague')
        OR (
          v_scope = 'championship'
          AND s.division IN ('championship_a', 'championship_b')
        )
      )
  LOOP
    BEGIN
      v_metrics := public.competition_stadium_season_metrics(
        r.club_short_name, p_season_id, r.division
      );
    EXCEPTION WHEN OTHERS THEN
      v_metrics := NULL;
    END;

    IF v_metrics IS NULL OR (v_metrics ? 'error') THEN
      CONTINUE;
    END IF;

    IF NOT (
      (v_metrics ->> 'expected_position') ~ '^-?\d+$'
      AND (v_metrics ->> 'actual_position') ~ '^-?\d+$'
    ) THEN
      CONTINUE;
    END IF;

    v_exp := (v_metrics ->> 'expected_position')::int;
    v_act := (v_metrics ->> 'actual_position')::int;
    v_over := v_exp - v_act;
    IF v_over <= 0 THEN
      CONTINUE;
    END IF;

    v_gap := CASE
      WHEN (v_metrics ->> 'performance_gap') ~ '^-?\d+(\.\d+)?$'
        THEN (v_metrics ->> 'performance_gap')::numeric
      ELSE NULL
    END;

    INSERT INTO _oot_season_cands (
      club_short_name, owner_id, expected_position, actual_position,
      position_overachievement, performance_gap, division
    )
    VALUES (
      r.club_short_name, r.owner_id, v_exp, v_act, v_over, v_gap, r.division
    )
    ON CONFLICT (club_short_name) DO NOTHING;
  END LOOP;

  SELECT
    c.club_short_name,
    c.owner_id,
    c.expected_position,
    c.actual_position,
    c.position_overachievement,
    c.performance_gap,
    c.division
  INTO v_best
  FROM _oot_season_cands c
  ORDER BY
    c.position_overachievement DESC,
    coalesce(c.performance_gap, -999999) DESC,
    c.actual_position ASC,
    c.club_short_name
  LIMIT 1;

  IF v_best.club_short_name IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_overachiever',
      'division_scope', v_scope,
      'season_id', p_season_id
    );
  END IF;

  v_owner_tag := coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(v_best.owner_id)), ''),
    'Owner'
  );

  INSERT INTO public.competition_owner_season_award (
    season_id, season_label, division_scope,
    owner_id, owner_tag, club_short_name,
    expected_position, actual_position, position_overachievement,
    performance_gap, prize_amount, detail
  )
  VALUES (
    p_season_id,
    coalesce(v_season_label, 'Season'),
    v_scope,
    v_best.owner_id,
    v_owner_tag,
    v_best.club_short_name,
    v_best.expected_position,
    v_best.actual_position,
    v_best.position_overachievement,
    v_best.performance_gap,
    v_prize,
    jsonb_build_object(
      'division', v_best.division,
      'metric', 'expected_minus_actual_position'
    )
  )
  ON CONFLICT (season_id, division_scope) DO UPDATE SET
    owner_id = EXCLUDED.owner_id,
    owner_tag = EXCLUDED.owner_tag,
    club_short_name = EXCLUDED.club_short_name,
    expected_position = EXCLUDED.expected_position,
    actual_position = EXCLUDED.actual_position,
    position_overachievement = EXCLUDED.position_overachievement,
    performance_gap = EXCLUDED.performance_gap,
    prize_amount = EXCLUDED.prize_amount,
    detail = EXCLUDED.detail,
    season_label = EXCLUDED.season_label
  RETURNING id INTO v_award_id;

  v_ledger := public.competition_pay_owner_award_credits(
    v_best.owner_id,
    v_prize,
    'owner_of_season_prize',
    format(
      'Owner of the Season — %s %s (₿%s)',
      v_scope_label,
      coalesce(v_season_label, 'Season'),
      to_char(v_prize, 'FM999,999,999')
    ),
    format('oots_prize:%s:%s', p_season_id, v_scope),
    p_season_id,
    jsonb_build_object(
      'award', 'owner_of_the_season',
      'award_id', v_award_id,
      'season_id', p_season_id,
      'division_scope', v_scope,
      'club_short_name', v_best.club_short_name,
      'expected_position', v_best.expected_position,
      'actual_position', v_best.actual_position,
      'position_overachievement', v_best.position_overachievement
    )
  );

  IF v_ledger IS NOT NULL THEN
    UPDATE public.competition_owner_season_award
    SET detail = coalesce(detail, '{}'::jsonb) || jsonb_build_object(
      'prize_ledger_id', v_ledger
    )
    WHERE id = v_award_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'division_scope', v_scope,
    'owner_id', v_best.owner_id,
    'owner_tag', v_owner_tag,
    'club_short_name', v_best.club_short_name,
    'expected_position', v_best.expected_position,
    'actual_position', v_best.actual_position,
    'position_overachievement', v_best.position_overachievement,
    'performance_gap', v_best.performance_gap,
    'prize_amount', v_prize,
    'prize_ledger_id', v_ledger
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_compute_owner_of_season(bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
