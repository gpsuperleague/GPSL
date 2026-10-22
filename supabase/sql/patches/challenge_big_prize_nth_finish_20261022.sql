-- =============================================================================
-- Challenge big prize: winner = earliest Nth challenge completion (2026-10-22)
-- =============================================================================
-- When several clubs have already hit the required count (e.g. admin recheck),
-- award only the club whose Nth awarded_at is earliest (then club name tie-break).
-- Stores finished_at on pack_snapshot for the Season challenges UI.
-- Requires challenge_owner_credits_and_best_of_20260928.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_challenge_nth_finish_at(
  p_season_id bigint,
  p_window_phase text,
  p_club_short_name text,
  p_required int
)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT x.awarded_at
  FROM (
    SELECT
      a.awarded_at,
      row_number() OVER (ORDER BY a.awarded_at ASC, a.id ASC) AS rn
    FROM public.competition_challenge_awarded a
    JOIN public.competition_challenge_config c ON c.id = a.challenge_id
    WHERE a.season_id = p_season_id
      AND a.club_short_name = p_club_short_name
      AND c.window_phase = p_window_phase
      AND c.is_active = true
  ) x
  WHERE x.rn = greatest(p_required, 1)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.competition_challenge_earliest_finisher(
  p_season_id bigint,
  p_window_phase text,
  p_required int
)
RETURNS TABLE (club_short_name text, finished_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ranked AS (
    SELECT
      a.club_short_name,
      a.awarded_at,
      row_number() OVER (
        PARTITION BY a.club_short_name
        ORDER BY a.awarded_at ASC, a.id ASC
      ) AS rn
    FROM public.competition_challenge_awarded a
    JOIN public.competition_challenge_config c ON c.id = a.challenge_id
    WHERE a.season_id = p_season_id
      AND c.window_phase = p_window_phase
      AND c.is_active = true
  ),
  finishers AS (
    SELECT r.club_short_name, r.awarded_at AS finished_at
    FROM ranked r
    WHERE r.rn = greatest(p_required, 1)
  )
  SELECT f.club_short_name, f.finished_at
  FROM finishers f
  ORDER BY f.finished_at ASC, f.club_short_name ASC
  LIMIT 1;
$$;

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
  v_required int;
  v_done int;
  v_deadline text;
  v_grant jsonb := '{}'::jsonb;
  v_cash numeric := 0;
  v_fallback numeric;
  v_club_name text;
  v_pack_name text;
  v_summary text;
  v_winner_body text;
  v_league_body text;
  v_has_credits boolean;
  v_finish_at timestamptz;
  v_earliest_club text;
  v_earliest_at timestamptz;
  v_snapshot jsonb;
BEGIN
  IF p_window_phase NOT IN ('start', 'mid') THEN
    RETURN false;
  END IF;

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

  v_required := public.competition_challenge_required_to_win(p_season_id, p_window_phase);

  SELECT count(*)::int INTO v_done
  FROM public.competition_challenge_awarded a
  JOIN public.competition_challenge_config c ON c.id = a.challenge_id
  WHERE a.season_id = p_season_id
    AND a.club_short_name = p_club_short_name
    AND c.window_phase = p_window_phase
    AND c.is_active = true;

  IF v_done < v_required THEN
    RETURN false;
  END IF;

  -- True first-to-N: earliest timestamp of each club's Nth awarded challenge
  SELECT e.club_short_name, e.finished_at
  INTO v_earliest_club, v_earliest_at
  FROM public.competition_challenge_earliest_finisher(
    p_season_id, p_window_phase, v_required
  ) e;

  IF v_earliest_club IS NULL
     OR upper(btrim(v_earliest_club)) IS DISTINCT FROM upper(btrim(p_club_short_name)) THEN
    RETURN false;
  END IF;

  v_finish_at := coalesce(
    v_earliest_at,
    public.competition_challenge_nth_finish_at(
      p_season_id, p_window_phase, p_club_short_name, v_required
    ),
    now()
  );

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
    IF coalesce(v_fallback, 0) <= 0 THEN
      RETURN false;
    END IF;
    v_cash := v_fallback;
  END IF;

  IF v_cash > 0 THEN
    PERFORM public.post_club_ledger(
      p_club_short_name,
      'prize_challenge',
      v_cash,
      format(
        'Challenge big prize — %s',
        public.competition_challenge_pack_display_name(
          p_window_phase,
          (SELECT pack_name FROM public.competition_challenge_period_pack WHERE window_phase = p_window_phase)
        )
      ),
      jsonb_build_object(
        'window_phase', p_window_phase,
        'bonus', true,
        'big_prize', true,
        'challenges_completed', v_done,
        'challenges_required', v_required,
        'challenges_total', v_total,
        'finished_at', v_finish_at,
        'pack', v_grant->'pack',
        'ignore_window', coalesce(p_ignore_window, false)
      ),
      p_season_id,
      NULL,
      true,
      true
    );
  END IF;

  v_snapshot := coalesce(v_grant, '{}'::jsonb)
    || jsonb_build_object(
      'finished_at', v_finish_at,
      'nth_completed_at', v_finish_at,
      'challenges_required', v_required,
      'challenges_completed', v_done
    );

  BEGIN
    INSERT INTO public.competition_challenge_period_bonus_awarded (
      season_id, window_phase, club_short_name, amount, pack_snapshot
    )
    VALUES (
      p_season_id,
      p_window_phase,
      p_club_short_name,
      coalesce(v_cash, 0),
      v_snapshot
    );
  EXCEPTION WHEN undefined_column THEN
    INSERT INTO public.competition_challenge_period_bonus_awarded (
      season_id, window_phase, club_short_name, amount
    )
    VALUES (
      p_season_id,
      p_window_phase,
      p_club_short_name,
      greatest(coalesce(v_cash, 0), 0)
    );
  END;

  SELECT coalesce(cl."Club", p_club_short_name) INTO v_club_name
  FROM public."Clubs" cl
  WHERE cl."ShortName" = p_club_short_name;

  SELECT public.competition_challenge_pack_display_name(p_window_phase, pk.pack_name)
  INTO v_pack_name
  FROM public.competition_challenge_period_pack pk
  WHERE pk.window_phase = p_window_phase;

  v_pack_name := coalesce(
    v_pack_name,
    public.competition_challenge_pack_display_name(p_window_phase, NULL)
  );

  v_summary := public.competition_challenge_pack_summary(
    coalesce(v_grant->'pack', '{}'::jsonb),
    v_cash
  );

  v_has_credits := EXISTS (
    SELECT 1 FROM jsonb_array_elements(coalesce(v_grant->'granted', '[]'::jsonb)) g
    WHERE g->>'type' = 'owner_credits' AND g->>'skipped' IS NULL
  );

  v_winner_body := format(
    E'You won %s — first to complete %s of the %s %s challenges (set finished %s UK).\n\nPrize awarded:\n%s\n\nOpen Club prizes to use medical tokens, transfer discounts, draft tokens, and appeal cards.%s',
    v_pack_name,
    v_required,
    v_total,
    p_window_phase,
    to_char(v_finish_at AT TIME ZONE 'Europe/London', 'DD Mon YYYY HH24:MI'),
    v_summary,
    CASE WHEN v_has_credits THEN E'\nOwner credits have been added to your Building Society wallet.' ELSE '' END
  );

  v_league_body := format(
    E'%s have won %s — first club to complete %s of the %s %s challenges (finished %s UK).\n\nPrize: %s',
    coalesce(v_club_name, p_club_short_name),
    v_pack_name,
    v_required,
    v_total,
    p_window_phase,
    to_char(v_finish_at AT TIME ZONE 'Europe/London', 'DD Mon YYYY HH24:MI'),
    v_summary
  );

  BEGIN
    PERFORM public.owner_inbox_send(
      'challenge_period_bonus',
      format('You won — %s', v_pack_name),
      v_winner_body,
      p_club_short_name,
      NULL, NULL, NULL, NULL, NULL,
      'club_prizes.html',
      format('challenge_big_prize_winner:%s:%s:%s', p_season_id, p_window_phase, p_club_short_name),
      NULL,
      p_season_id
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  BEGIN
    PERFORM public.owner_inbox_notify_all_clubs(
      'challenge_period_bonus',
      format('%s claimed', v_pack_name),
      v_league_body,
      'challenges.html',
      format('challenge_big_prize_league:%s:%s', p_season_id, p_window_phase),
      p_season_id
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  BEGIN
    PERFORM public.gpsl_discord_feed_enqueue(
      'title',
      format('🏆 %s', v_pack_name),
      v_league_body,
      16766720,
      format('challenge_big_prize:%s:%s', p_season_id, p_window_phase),
      jsonb_build_object(
        'club', p_club_short_name,
        'window_phase', p_window_phase,
        'pack_name', v_pack_name,
        'pack_summary', v_summary,
        'finished_at', v_finish_at
      )
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN true;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_challenge_nth_finish_at(bigint, text, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_earliest_finisher(bigint, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_try_award_period_bonus(bigint, text, text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
