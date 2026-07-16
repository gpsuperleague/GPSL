-- =============================================================================
-- Challenge BIG PRIZE — first club to complete ALL window challenges
-- Awards cash + medical tokens + transfer fee discounts + red-card appeal cards,
-- then announces to winner inbox + all club inboxes (+ Discord feed if present).
--
-- Requires: competition_challenges.sql, competition_challenge_prize_packs.sql (+ part2)
-- Safe re-run.
-- =============================================================================

-- Ensure pack table / defaults exist
CREATE TABLE IF NOT EXISTS public.competition_challenge_period_pack (
  window_phase text PRIMARY KEY CHECK (window_phase IN ('start', 'mid')),
  cash_amount numeric(14, 2) NOT NULL DEFAULT 0 CHECK (cash_amount >= 0),
  pack jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.competition_challenge_period_pack (window_phase, cash_amount, pack)
VALUES
  ('start', 5000000, '{"medical_tokens":[4,6],"fee_discounts":[10],"appeal_cards":1}'::jsonb),
  ('mid', 5000000, '{"medical_tokens":[2,4],"fee_discounts":[5],"appeal_cards":1}'::jsonb)
ON CONFLICT (window_phase) DO NOTHING;

ALTER TABLE public.competition_challenge_period_bonus_awarded
  ADD COLUMN IF NOT EXISTS pack_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $amt$
BEGIN
  ALTER TABLE public.competition_challenge_period_bonus_awarded
    DROP CONSTRAINT IF EXISTS competition_challenge_period_bonus_awarded_amount_check;
  ALTER TABLE public.competition_challenge_period_bonus_awarded
    ADD CONSTRAINT competition_challenge_period_bonus_awarded_amount_check
    CHECK (amount >= 0);
EXCEPTION WHEN others THEN
  NULL;
END;
$amt$;

-- Ensure inbox type includes challenge_period_bonus
DO $inbox_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY['challenge_period_bonus', 'prize_appeal_submitted', 'prize_appeal_resolved'])
  ) s;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'Inbox type widen skipped: %', SQLERRM;
END;
$inbox_types$;

CREATE OR REPLACE FUNCTION public.competition_challenge_pack_summary(p_pack jsonb, p_cash numeric)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_parts text[] := ARRAY[]::text[];
  v_med text;
  v_disc text;
  v_appeals int;
BEGIN
  IF coalesce(p_cash, 0) > 0 THEN
    v_parts := v_parts || format('Cash ₿%s', to_char(p_cash, 'FM999,999,999,999'));
  END IF;

  SELECT string_agg(x || '-match medical', ', ' ORDER BY x::int)
  INTO v_med
  FROM jsonb_array_elements_text(coalesce(p_pack->'medical_tokens', '[]'::jsonb)) x;
  IF v_med IS NOT NULL AND v_med <> '' THEN
    v_parts := v_parts || ('Medical: ' || v_med);
  END IF;

  SELECT string_agg(x || '% transfer discount', ', ' ORDER BY x::int)
  INTO v_disc
  FROM jsonb_array_elements_text(coalesce(p_pack->'fee_discounts', '[]'::jsonb)) x;
  IF v_disc IS NOT NULL AND v_disc <> '' THEN
    v_parts := v_parts || ('Discounts: ' || v_disc);
  END IF;

  v_appeals := coalesce((p_pack->>'appeal_cards')::int, 0);
  IF v_appeals > 0 THEN
    v_parts := v_parts || format('%s red-card appeal card(s)', v_appeals);
  END IF;

  IF coalesce(array_length(v_parts, 1), 0) = 0 THEN
    RETURN 'No pack items configured';
  END IF;
  RETURN array_to_string(v_parts, ' · ');
END;
$function$;

-- Public read of big-prize packs for challenges page
CREATE OR REPLACE VIEW public.competition_challenge_period_packs_public
WITH (security_invoker = false)
AS
SELECT
  window_phase,
  cash_amount,
  pack,
  public.competition_challenge_pack_summary(pack, cash_amount) AS pack_summary
FROM public.competition_challenge_period_pack;

GRANT SELECT ON public.competition_challenge_period_packs_public TO authenticated;
GRANT SELECT ON public.competition_challenge_period_packs_public TO anon;

DROP FUNCTION IF EXISTS public.competition_try_award_period_bonus(bigint, text, text);
DROP FUNCTION IF EXISTS public.competition_try_award_period_bonus(bigint, text, text, boolean);

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
  v_phase_label text;
  v_summary text;
  v_winner_body text;
  v_league_body text;
BEGIN
  IF p_window_phase NOT IN ('start', 'mid') THEN
    RETURN false;
  END IF;

  -- Only one big prize per window per season
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

  -- First club across the line = completed EVERY active challenge in the window
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

  -- Grant inventory items from configured pack
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
      format('Challenge big prize — first to complete all %s targets', p_window_phase),
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

  v_phase_label := CASE p_window_phase
    WHEN 'start' THEN 'Start (Jun–Dec)'
    WHEN 'mid' THEN 'Mid (Jan–May)'
    ELSE p_window_phase
  END;

  v_summary := public.competition_challenge_pack_summary(
    coalesce(v_grant->'pack', '{}'::jsonb),
    v_cash
  );

  v_winner_body := format(
    E'You were first to complete all %s season challenges (%s/%s).\n\nBig prize awarded:\n%s\n\nOpen Club prizes to use medical tokens, transfer discounts, and appeal cards.',
    v_phase_label,
    v_done,
    v_total,
    v_summary
  );

  v_league_body := format(
    E'%s have won the %s challenge big prize — first club to complete all %s targets.\n\nPrize: %s',
    coalesce(v_club_name, p_club_short_name),
    v_phase_label,
    v_total,
    v_summary
  );

  -- Winner inbox
  BEGIN
    PERFORM public.owner_inbox_send(
      'challenge_period_bonus',
      format('Challenge big prize — %s', v_phase_label),
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

  -- League-wide announcement
  BEGIN
    PERFORM public.owner_inbox_notify_all_clubs(
      'challenge_period_bonus',
      format('Challenge big prize claimed — %s', v_phase_label),
      v_league_body,
      'challenges.html',
      format('challenge_big_prize_league:%s:%s', p_season_id, p_window_phase),
      p_season_id
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  -- Discord news (optional)
  BEGIN
    PERFORM public.gpsl_discord_feed_enqueue(
      'title',
      format('🏆 CHALLENGE BIG PRIZE — %s', v_phase_label),
      v_league_body,
      16766720,
      format('challenge_big_prize:%s:%s', p_season_id, p_window_phase),
      jsonb_build_object(
        'club', p_club_short_name,
        'window_phase', p_window_phase,
        'pack_summary', v_summary
      )
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN true;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_try_award_period_bonus(bigint, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_pack_summary(jsonb, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
