-- =============================================================================
-- Nameable challenge big prize packs + clearer winner readout
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_challenge_period_pack
  ADD COLUMN IF NOT EXISTS pack_name text;

UPDATE public.competition_challenge_period_pack
SET pack_name = CASE window_phase
  WHEN 'start' THEN coalesce(nullif(btrim(pack_name), ''), 'Start of Season Challenge Prize')
  WHEN 'mid' THEN coalesce(nullif(btrim(pack_name), ''), 'Mid-Season Challenge Prize')
  ELSE pack_name
END
WHERE pack_name IS NULL OR btrim(pack_name) = '';

CREATE OR REPLACE FUNCTION public.competition_challenge_pack_display_name(
  p_window_phase text,
  p_pack_name text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    nullif(btrim(p_pack_name), ''),
    CASE lower(btrim(coalesce(p_window_phase, '')))
      WHEN 'start' THEN 'Start of Season Challenge Prize'
      WHEN 'mid' THEN 'Mid-Season Challenge Prize'
      ELSE 'Challenge big prize'
    END
  );
$$;

DROP VIEW IF EXISTS public.competition_challenge_period_packs_public;

CREATE VIEW public.competition_challenge_period_packs_public
WITH (security_invoker = false)
AS
SELECT
  window_phase,
  cash_amount,
  pack,
  public.competition_challenge_pack_summary(pack, cash_amount) AS pack_summary,
  public.competition_challenge_pack_display_name(window_phase, pack_name) AS pack_name
FROM public.competition_challenge_period_pack;

GRANT SELECT ON public.competition_challenge_period_packs_public TO authenticated;
GRANT SELECT ON public.competition_challenge_period_packs_public TO anon;

CREATE OR REPLACE FUNCTION public.admin_update_challenge_period_packs(p_packs jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_phase text;
  v_name text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_packs IS NULL OR jsonb_typeof(p_packs) <> 'array' THEN
    RAISE EXCEPTION 'packs must be a JSON array';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_packs)
  LOOP
    v_phase := v_row->>'window_phase';
    IF v_phase NOT IN ('start', 'mid') THEN
      RAISE EXCEPTION 'Invalid window_phase';
    END IF;

    v_name := nullif(btrim(coalesce(v_row->>'pack_name', '')), '');

    INSERT INTO public.competition_challenge_period_pack (
      window_phase, cash_amount, pack, pack_name, updated_at
    )
    VALUES (
      v_phase,
      coalesce((v_row->>'cash_amount')::numeric, 0),
      coalesce(v_row->'pack', '{}'::jsonb),
      coalesce(
        v_name,
        public.competition_challenge_pack_display_name(v_phase, NULL)
      ),
      now()
    )
    ON CONFLICT (window_phase) DO UPDATE
    SET
      cash_amount = excluded.cash_amount,
      pack = excluded.pack,
      pack_name = coalesce(excluded.pack_name, competition_challenge_period_pack.pack_name),
      updated_at = now();
  END LOOP;
END;
$function$;

-- Progress board: always include named big-prize winner status
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
  v_big jsonb := '[]'::jsonb;
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
    RETURN jsonb_build_object(
      'season_id', null,
      'challenges', '[]'::jsonb,
      'period_bonuses', '[]'::jsonb,
      'big_prizes', '[]'::jsonb
    );
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
      'pack_name', public.competition_challenge_pack_display_name(b.window_phase, pk.pack_name),
      'club_short_name', b.club_short_name,
      'club_name', coalesce(cl."Club", b.club_short_name),
      'amount', b.amount,
      'awarded_at', b.awarded_at,
      'pack_snapshot', b.pack_snapshot
    )
    ORDER BY b.window_phase, b.awarded_at
  ), '[]'::jsonb)
  INTO v_bonus
  FROM public.competition_challenge_period_bonus_awarded b
  LEFT JOIN public."Clubs" cl ON cl."ShortName" = b.club_short_name
  LEFT JOIN public.competition_challenge_period_pack pk ON pk.window_phase = b.window_phase
  WHERE b.season_id = v_season_id;

  -- Always list Start + Mid status (claimed or still open)
  SELECT coalesce(jsonb_agg(x.obj ORDER BY x.ord), '[]'::jsonb)
  INTO v_big
  FROM (
    SELECT
      CASE ph.phase WHEN 'start' THEN 1 ELSE 2 END AS ord,
      jsonb_build_object(
        'window_phase', ph.phase,
        'pack_name', public.competition_challenge_pack_display_name(ph.phase, pk.pack_name),
        'pack_summary', public.competition_challenge_pack_summary(
          coalesce(pk.pack, '{}'::jsonb),
          coalesce(pk.cash_amount, 0)
        ),
        'claimed', b.club_short_name IS NOT NULL,
        'club_short_name', b.club_short_name,
        'club_name', coalesce(cl."Club", b.club_short_name),
        'amount', b.amount,
        'awarded_at', b.awarded_at
      ) AS obj
    FROM (VALUES ('start'), ('mid')) AS ph(phase)
    LEFT JOIN public.competition_challenge_period_pack pk ON pk.window_phase = ph.phase
    LEFT JOIN public.competition_challenge_period_bonus_awarded b
      ON b.season_id = v_season_id AND b.window_phase = ph.phase
    LEFT JOIN public."Clubs" cl ON cl."ShortName" = b.club_short_name
  ) x;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'challenges', v_challenges,
    'period_bonuses', coalesce(v_bonus, '[]'::jsonb),
    'big_prizes', coalesce(v_big, '[]'::jsonb)
  );
END;
$function$;

-- Use pack name in big-prize inbox / Discord announce
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
  v_grant jsonb := '{}'::jsonb;
  v_cash numeric := 0;
  v_fallback numeric;
  v_club_name text;
  v_pack_name text;
  v_summary text;
  v_winner_body text;
  v_league_body text;
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

  v_winner_body := format(
    E'You won %s — first to complete all %s challenges (%s/%s).\n\nPrize awarded:\n%s\n\nOpen Club prizes to use medical tokens, transfer discounts, draft tokens, and appeal cards.',
    v_pack_name,
    p_window_phase,
    v_done,
    v_total,
    v_summary
  );

  v_league_body := format(
    E'%s have won %s — first club to complete all %s targets.\n\nPrize: %s',
    coalesce(v_club_name, p_club_short_name),
    v_pack_name,
    v_total,
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
        'pack_summary', v_summary
      )
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN true;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_update_challenge_period_packs(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_challenge_progress_board(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_try_award_period_bonus(bigint, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_pack_display_name(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
