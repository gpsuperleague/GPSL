-- =============================================================================
-- Challenges: admin retrospective recheck (ignore closed window) + progress board
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Award one challenge (optional ignore window for admin catch-up)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.competition_award_challenge(bigint, text, int);

CREATE OR REPLACE FUNCTION public.competition_award_challenge(
  p_challenge_id bigint,
  p_club_short_name text,
  p_stat_value int,
  p_ignore_window boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_c public.competition_challenge_config;
  v_amount numeric;
BEGIN
  SELECT * INTO v_c
  FROM public.competition_challenge_config
  WHERE id = p_challenge_id
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_challenge_awarded
    WHERE challenge_id = p_challenge_id
      AND club_short_name = p_club_short_name
  ) THEN
    RETURN false;
  END IF;

  IF NOT coalesce(p_ignore_window, false)
     AND NOT public.competition_challenge_window_open(
       v_c.season_id, v_c.window_phase, v_c.gpsl_month_to
     ) THEN
    RETURN false;
  END IF;

  v_amount := v_c.prize_amount;

  PERFORM public.post_club_ledger(
    p_club_short_name,
    'prize_challenge',
    v_amount,
    format('Challenge — %s', v_c.title),
    jsonb_build_object(
      'challenge_id', v_c.id,
      'window_phase', v_c.window_phase,
      'stat_type', v_c.stat_type,
      'target_value', v_c.target_value,
      'stat_value', p_stat_value,
      'ignore_window', coalesce(p_ignore_window, false)
    ),
    v_c.season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.competition_challenge_awarded (
    season_id, challenge_id, club_short_name, amount, stat_value, metadata
  )
  VALUES (
    v_c.season_id,
    p_challenge_id,
    p_club_short_name,
    v_amount,
    p_stat_value,
    jsonb_build_object('title', v_c.title)
  );

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Period bonus (optional ignore window)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.competition_try_award_period_bonus(bigint, text, text);

CREATE OR REPLACE FUNCTION public.competition_try_award_period_bonus(
  p_season_id bigint,
  p_club_short_name text,
  p_window_phase text,
  p_ignore_window boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_total int;
  v_done int;
  v_deadline text;
  v_grant jsonb;
  v_cash numeric;
  v_fallback numeric;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.competition_challenge_period_bonus_awarded
    WHERE season_id = p_season_id
      AND window_phase = p_window_phase
  ) THEN
    RETURN false;
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.competition_challenge_config
  WHERE season_id = p_season_id
    AND window_phase = p_window_phase
    AND is_active = true;

  IF v_total = 0 THEN
    RETURN false;
  END IF;

  SELECT count(*)::int INTO v_done
  FROM public.competition_challenge_awarded a
  JOIN public.competition_challenge_config c ON c.id = a.challenge_id
  WHERE a.season_id = p_season_id
    AND a.club_short_name = p_club_short_name
    AND c.window_phase = p_window_phase
    AND c.is_active = true;

  IF v_done < v_total THEN
    RETURN false;
  END IF;

  SELECT max(c.gpsl_month_to) INTO v_deadline
  FROM public.competition_challenge_config c
  WHERE c.season_id = p_season_id
    AND c.window_phase = p_window_phase
    AND c.is_active = true;

  IF NOT coalesce(p_ignore_window, false)
     AND NOT public.competition_challenge_window_open(p_season_id, p_window_phase, v_deadline) THEN
    RETURN false;
  END IF;

  BEGIN
    v_grant := public.prize_grant_period_pack(p_club_short_name, p_window_phase, p_season_id);
  EXCEPTION WHEN undefined_function OR others THEN
    v_grant := '{}'::jsonb;
  END;

  v_cash := coalesce((v_grant->>'cash_amount')::numeric, 0);

  IF v_cash <= 0 AND jsonb_array_length(coalesce(v_grant->'granted', '[]'::jsonb)) = 0 THEN
    v_fallback := (SELECT challenge_period_bonus FROM public.global_settings WHERE id = 1);
    IF v_fallback IS NULL OR v_fallback <= 0 THEN
      RETURN false;
    END IF;
    v_cash := v_fallback;
  END IF;

  IF v_cash > 0 THEN
    PERFORM public.post_club_ledger(
      p_club_short_name,
      'prize_challenge',
      v_cash,
      format('Challenge bonus — first to complete all %s targets', p_window_phase),
      jsonb_build_object(
        'window_phase', p_window_phase,
        'bonus', true,
        'challenges_completed', v_done,
        'pack', v_grant->'pack',
        'ignore_window', coalesce(p_ignore_window, false)
      ),
      p_season_id,
      NULL,
      true,
      true
    );
  END IF;

  BEGIN
    INSERT INTO public.competition_challenge_period_bonus_awarded (
      season_id, window_phase, club_short_name, amount, pack_snapshot
    )
    VALUES (
      p_season_id,
      p_window_phase,
      p_club_short_name,
      coalesce(v_cash, 0),
      coalesce(v_grant, '{}'::jsonb)
    );
  EXCEPTION WHEN undefined_column THEN
    INSERT INTO public.competition_challenge_period_bonus_awarded (
      season_id, window_phase, club_short_name, amount
    )
    VALUES (
      p_season_id,
      p_window_phase,
      p_club_short_name,
      greatest(coalesce(v_cash, 0), 0.01)
    );
  END;

  BEGIN
    PERFORM public.owner_inbox_send(
      'challenge_period_bonus',
      format('Challenge period bonus — %s window', p_window_phase),
      format(
        'You were first to complete all %s challenges.%s%s',
        p_window_phase,
        CASE WHEN v_cash > 0 THEN format(E'\nCash: ₿%s', to_char(v_cash, 'FM999,999,999,999')) ELSE '' END,
        CASE
          WHEN jsonb_array_length(coalesce(v_grant->'granted', '[]'::jsonb)) > 0
          THEN E'\nPrize items were added to Club prizes.'
          ELSE ''
        END
      ),
      p_club_short_name,
      NULL, NULL, NULL, NULL, NULL,
      'club_prizes.html',
      format('challenge_period_bonus:%s:%s:%s', p_season_id, p_window_phase, p_club_short_name),
      NULL,
      p_season_id
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Try award all for one club (optional ignore window)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.competition_try_award_challenges(bigint, text);

CREATE OR REPLACE FUNCTION public.competition_try_award_challenges(
  p_season_id bigint,
  p_club_short_name text,
  p_ignore_window boolean DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.competition_challenge_config;
  v_val int;
  v_awarded int := 0;
BEGIN
  IF p_season_id IS NULL OR p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.competition_challenge_config
    WHERE season_id = p_season_id
      AND is_active = true
    ORDER BY sort_order, id
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_challenge_awarded
      WHERE challenge_id = v_row.id
        AND club_short_name = p_club_short_name
    ) THEN
      CONTINUE;
    END IF;

    IF NOT coalesce(p_ignore_window, false)
       AND NOT public.competition_challenge_window_open(
         p_season_id, v_row.window_phase, v_row.gpsl_month_to
       ) THEN
      CONTINUE;
    END IF;

    v_val := public.competition_challenge_stat_value(
      p_season_id,
      p_club_short_name,
      v_row.stat_type,
      v_row.gpsl_month_from,
      v_row.gpsl_month_to,
      v_row.include_league,
      v_row.include_cup,
      v_row.stat_param
    );

    IF v_val >= v_row.target_value THEN
      IF public.competition_award_challenge(
        v_row.id, p_club_short_name, v_val, coalesce(p_ignore_window, false)
      ) THEN
        v_awarded := v_awarded + 1;
        PERFORM public.competition_try_award_period_bonus(
          p_season_id,
          p_club_short_name,
          v_row.window_phase,
          coalesce(p_ignore_window, false)
        );
      END IF;
    END IF;
  END LOOP;

  RETURN v_awarded;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin recheck — defaults to ignore closed window (retrospective payout)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.competition_admin_recheck_challenges(bigint);

CREATE OR REPLACE FUNCTION public.competition_admin_recheck_challenges(
  p_season_id bigint DEFAULT NULL,
  p_ignore_window boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_club text;
  v_total int := 0;
  v_n int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season';
  END IF;

  FOR v_club IN
    SELECT ccs.club_short_name
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  LOOP
    v_n := public.competition_try_award_challenges(
      v_season_id, v_club, coalesce(p_ignore_window, true)
    );
    v_total := v_total + v_n;
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'challenges_awarded', v_total,
    'ignore_window', coalesce(p_ignore_window, true)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin progress board: who met / who was paid, per challenge
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_challenge_progress_board(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_challenges jsonb := '[]'::jsonb;
  v_row record;
  v_club text;
  v_club_name text;
  v_val int;
  v_awarded boolean;
  v_achievers jsonb;
  v_bonus jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('season_id', null, 'challenges', '[]'::jsonb, 'period_bonuses', '[]'::jsonb);
  END IF;

  FOR v_row IN
    SELECT c.*
    FROM public.competition_challenge_config c
    WHERE c.season_id = v_season_id
      AND c.is_active = true
    ORDER BY c.window_phase, c.sort_order, c.id
  LOOP
    v_achievers := '[]'::jsonb;

    FOR v_club, v_club_name IN
      SELECT ccs.club_short_name, coalesce(cl."Club", ccs.club_short_name)
      FROM public.competition_club_seasons ccs
      LEFT JOIN public."Clubs" cl ON cl."ShortName" = ccs.club_short_name
      WHERE ccs.season_id = v_season_id
        AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      ORDER BY coalesce(cl."Club", ccs.club_short_name)
    LOOP
      v_val := public.competition_challenge_stat_value(
        v_season_id,
        v_club,
        v_row.stat_type,
        v_row.gpsl_month_from,
        v_row.gpsl_month_to,
        v_row.include_league,
        v_row.include_cup,
        v_row.stat_param
      );

      SELECT EXISTS (
        SELECT 1 FROM public.competition_challenge_awarded a
        WHERE a.challenge_id = v_row.id AND a.club_short_name = v_club
      ) INTO v_awarded;

      IF v_val >= v_row.target_value OR v_awarded THEN
        v_achievers := v_achievers || jsonb_build_array(
          jsonb_build_object(
            'club_short_name', v_club,
            'club_name', v_club_name,
            'current_value', v_val,
            'target_value', v_row.target_value,
            'awarded', v_awarded,
            'met', v_val >= v_row.target_value
          )
        );
      END IF;
    END LOOP;

    v_challenges := v_challenges || jsonb_build_array(
      jsonb_build_object(
        'id', v_row.id,
        'title', v_row.title,
        'window_phase', v_row.window_phase,
        'stat_type', v_row.stat_type,
        'stat_param', v_row.stat_param,
        'target_value', v_row.target_value,
        'prize_amount', v_row.prize_amount,
        'achiever_count', jsonb_array_length(v_achievers),
        'achievers', v_achievers,
        'window_open', public.competition_challenge_window_open(
          v_season_id, v_row.window_phase, v_row.gpsl_month_to
        )
      )
    );
  END LOOP;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'window_phase', b.window_phase,
      'club_short_name', b.club_short_name,
      'club_name', coalesce(cl."Club", b.club_short_name),
      'amount', b.amount,
      'awarded_at', b.awarded_at
    )
    ORDER BY b.awarded_at
  ), '[]'::jsonb)
  INTO v_bonus
  FROM public.competition_challenge_period_bonus_awarded b
  LEFT JOIN public."Clubs" cl ON cl."ShortName" = b.club_short_name
  WHERE b.season_id = v_season_id;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'challenges', v_challenges,
    'period_bonuses', coalesce(v_bonus, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_award_challenge(bigint, text, int, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_try_award_challenges(bigint, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_try_award_period_bonus(bigint, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_recheck_challenges(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_challenge_progress_board(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
