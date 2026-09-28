-- =============================================================================
-- Challenges: owner credits in big prize pack + "first to complete N of up to M"
--
--   • Admin can set up to challenge_max_per_window (default 10) active
--     challenges per window (Start / Mid). Enforced by trigger.
--   • Big prize goes to the first club to complete challenge_big_prize_required
--     (default 5) of that window's challenges. If fewer are set, all are needed.
--   • New pack item: owner_credits (₿) — paid into the club owner's personal
--     wallet (Building Society / owner_finance_ledger, type 'challenge_prize').
--
-- Run after competition_challenge_pack_names.sql and
-- competition_challenge_draft_token_prize.sql. Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS challenge_big_prize_required smallint NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS challenge_max_per_window smallint NOT NULL DEFAULT 10;

ALTER TABLE public.global_settings
  DROP CONSTRAINT IF EXISTS global_settings_challenge_big_prize_required_check;
ALTER TABLE public.global_settings
  ADD CONSTRAINT global_settings_challenge_big_prize_required_check
  CHECK (challenge_big_prize_required BETWEEN 1 AND 50);

ALTER TABLE public.global_settings
  DROP CONSTRAINT IF EXISTS global_settings_challenge_max_per_window_check;
ALTER TABLE public.global_settings
  ADD CONSTRAINT global_settings_challenge_max_per_window_check
  CHECK (challenge_max_per_window BETWEEN 1 AND 50);

-- How many completions win the big prize for a season/window
CREATE OR REPLACE FUNCTION public.competition_challenge_required_to_win(
  p_season_id bigint,
  p_window_phase text
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH s AS (
    SELECT coalesce((SELECT challenge_big_prize_required FROM public.global_settings WHERE id = 1), 5)::int AS req
  ), n AS (
    SELECT count(*)::int AS total
    FROM public.competition_challenge_config c
    WHERE c.season_id = p_season_id
      AND c.window_phase = p_window_phase
      AND c.is_active = true
  )
  SELECT CASE WHEN n.total = 0 THEN s.req ELSE least(s.req, n.total) END
  FROM s, n;
$$;

-- ---------------------------------------------------------------------------
-- Max active challenges per window
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_challenge_config_enforce_max()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int;
  v_n int;
BEGIN
  IF NEW.is_active IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(challenge_max_per_window, 10) INTO v_max
  FROM public.global_settings WHERE id = 1;
  v_max := coalesce(v_max, 10);

  SELECT count(*)::int INTO v_n
  FROM public.competition_challenge_config c
  WHERE c.season_id = NEW.season_id
    AND c.window_phase = NEW.window_phase
    AND c.is_active = true
    AND c.id IS DISTINCT FROM NEW.id;

  IF v_n >= v_max THEN
    RAISE EXCEPTION 'Maximum % active challenges per window — % already set for the % window. Delete or deactivate one first.',
      v_max, v_n, NEW.window_phase;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_competition_challenge_config_enforce_max ON public.competition_challenge_config;
CREATE TRIGGER trg_competition_challenge_config_enforce_max
  BEFORE INSERT OR UPDATE OF is_active, window_phase, season_id
  ON public.competition_challenge_config
  FOR EACH ROW
  EXECUTE FUNCTION public.competition_challenge_config_enforce_max();

-- ---------------------------------------------------------------------------
-- Admin settings (adds required / max; keeps packs passthrough)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_update_challenge_settings(p_settings jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_req int := nullif(p_settings->>'challenge_big_prize_required', '')::int;
  v_max int := nullif(p_settings->>'challenge_max_per_window', '')::int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_max IS NOT NULL AND (v_max < 1 OR v_max > 50) THEN
    RAISE EXCEPTION 'Max challenges per window must be 1–50';
  END IF;
  IF v_req IS NOT NULL AND (v_req < 1 OR v_req > coalesce(v_max, 50)) THEN
    RAISE EXCEPTION 'Challenges needed to win must be between 1 and the max per window';
  END IF;

  UPDATE public.global_settings
  SET
    challenge_default_prize = coalesce(
      (p_settings->>'challenge_default_prize')::numeric,
      challenge_default_prize
    ),
    challenge_period_bonus = coalesce(
      (p_settings->>'challenge_period_bonus')::numeric,
      challenge_period_bonus
    ),
    challenge_big_prize_required = coalesce(v_req, challenge_big_prize_required),
    challenge_max_per_window = coalesce(v_max, challenge_max_per_window),
    updated_at = now()
  WHERE id = 1;

  IF p_settings ? 'packs' THEN
    PERFORM public.admin_update_challenge_period_packs(p_settings->'packs');
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Pack grant: + owner_credits → owner wallet
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prize_grant_period_pack(
  p_club text,
  p_window_phase text,
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pack public.competition_challenge_period_pack%rowtype;
  v_med int;
  v_disc int;
  v_appeals int := 0;
  v_drafts int := 0;
  v_credits numeric := 0;
  v_owner uuid;
  v_granted jsonb := '[]'::jsonb;
  v_id bigint;
  v_i int;
BEGIN
  SELECT * INTO v_pack
  FROM public.competition_challenge_period_pack
  WHERE window_phase = p_window_phase;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('granted', '[]'::jsonb, 'cash_amount', 0);
  END IF;

  FOR v_med IN
    SELECT jsonb_array_elements_text(coalesce(v_pack.pack->'medical_tokens', '[]'::jsonb))::int
  LOOP
    IF v_med IN (2, 4, 6, 8, 10) THEN
      v_id := public.prize_grant_inventory_item(
        p_club, 'medical_token', v_med,
        'challenge_period_bonus', p_season_id, p_window_phase,
        jsonb_build_object('matches_removed', v_med)
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('id', v_id, 'type', 'medical_token', 'param', v_med)
      );
    END IF;
  END LOOP;

  FOR v_disc IN
    SELECT jsonb_array_elements_text(coalesce(v_pack.pack->'fee_discounts', '[]'::jsonb))::int
  LOOP
    IF v_disc > 0 AND v_disc <= 50 THEN
      v_id := public.prize_grant_inventory_item(
        p_club, 'fee_discount', v_disc,
        'challenge_period_bonus', p_season_id, p_window_phase,
        jsonb_build_object('discount_pct', v_disc)
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('id', v_id, 'type', 'fee_discount', 'param', v_disc)
      );
    END IF;
  END LOOP;

  v_appeals := coalesce((v_pack.pack->>'appeal_cards')::int, 0);
  FOR v_i IN 1..greatest(v_appeals, 0) LOOP
    v_id := public.prize_grant_inventory_item(
      p_club, 'appeal_card', NULL,
      'challenge_period_bonus', p_season_id, p_window_phase,
      '{}'::jsonb
    );
    v_granted := v_granted || jsonb_build_array(
      jsonb_build_object('id', v_id, 'type', 'appeal_card', 'param', NULL)
    );
  END LOOP;

  v_drafts := coalesce((v_pack.pack->>'draft_tokens')::int, 0);
  FOR v_i IN 1..greatest(v_drafts, 0) LOOP
    v_id := public.prize_grant_inventory_item(
      p_club, 'draft_token', NULL,
      'challenge_period_bonus', p_season_id, p_window_phase,
      jsonb_build_object('kind', 'draft_market_sign')
    );
    v_granted := v_granted || jsonb_build_array(
      jsonb_build_object('id', v_id, 'type', 'draft_token', 'param', NULL)
    );
  END LOOP;

  v_credits := round(greatest(coalesce(nullif(v_pack.pack->>'owner_credits', '')::numeric, 0), 0), 2);
  IF v_credits > 0 THEN
    SELECT c.owner_id INTO v_owner
    FROM public."Clubs" c
    WHERE c."ShortName" = btrim(p_club);

    IF v_owner IS NOT NULL THEN
      v_id := public._post_owner_ledger_internal(
        v_owner,
        'challenge_prize',
        v_credits,
        format(
          'Challenge big prize — %s',
          public.competition_challenge_pack_display_name(p_window_phase, v_pack.pack_name)
        ),
        jsonb_build_object(
          'source', 'challenge_period_bonus',
          'club', btrim(p_club),
          'window_phase', p_window_phase
        ),
        p_season_id,
        true
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('id', v_id, 'type', 'owner_credits', 'param', v_credits)
      );
    ELSE
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('id', NULL, 'type', 'owner_credits', 'param', v_credits,
                           'skipped', 'club has no owner')
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'cash_amount', coalesce(v_pack.cash_amount, 0),
    'pack', v_pack.pack,
    'granted', v_granted
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Pack summary: + owner credits
-- ---------------------------------------------------------------------------
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
  v_drafts int;
  v_credits numeric;
BEGIN
  IF coalesce(p_cash, 0) > 0 THEN
    v_parts := v_parts || format('Cash ₿%s', to_char(p_cash, 'FM999,999,999,999'));
  END IF;

  v_credits := coalesce(nullif(p_pack->>'owner_credits', '')::numeric, 0);
  IF v_credits > 0 THEN
    v_parts := v_parts || format('Owner credits ₿%s (Building Society)', to_char(v_credits, 'FM999,999,999,999'));
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

  v_drafts := coalesce((p_pack->>'draft_tokens')::int, 0);
  IF v_drafts > 0 THEN
    v_parts := v_parts || format(
      '%s draft token(s) (sign uncontracted player at MV)',
      v_drafts
    );
  END IF;

  IF coalesce(array_length(v_parts, 1), 0) = 0 THEN
    RETURN 'No pack items configured';
  END IF;
  RETURN array_to_string(v_parts, ' · ');
END;
$function$;

-- Public packs view: + required_to_win / active count for current season
CREATE OR REPLACE VIEW public.competition_challenge_period_packs_public
WITH (security_invoker = false)
AS
SELECT
  pk.window_phase,
  pk.cash_amount,
  pk.pack,
  public.competition_challenge_pack_summary(pk.pack, pk.cash_amount) AS pack_summary,
  public.competition_challenge_pack_display_name(pk.window_phase, pk.pack_name) AS pack_name,
  public.competition_challenge_required_to_win(cur.id, pk.window_phase) AS required_to_win,
  (
    SELECT count(*)::int
    FROM public.competition_challenge_config c
    WHERE c.season_id = cur.id
      AND c.window_phase = pk.window_phase
      AND c.is_active = true
  ) AS active_challenges
FROM public.competition_challenge_period_pack pk
LEFT JOIN LATERAL (
  SELECT s.id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1
) cur ON true;

GRANT SELECT ON public.competition_challenge_period_packs_public TO authenticated;
GRANT SELECT ON public.competition_challenge_period_packs_public TO anon;

-- ---------------------------------------------------------------------------
-- Big prize award: first to complete N (not all)
-- ---------------------------------------------------------------------------
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

  v_has_credits := EXISTS (
    SELECT 1 FROM jsonb_array_elements(coalesce(v_grant->'granted', '[]'::jsonb)) g
    WHERE g->>'type' = 'owner_credits' AND g->>'skipped' IS NULL
  );

  v_winner_body := format(
    E'You won %s — first to complete %s of the %s %s challenges.\n\nPrize awarded:\n%s\n\nOpen Club prizes to use medical tokens, transfer discounts, draft tokens, and appeal cards.%s',
    v_pack_name,
    v_required,
    v_total,
    p_window_phase,
    v_summary,
    CASE WHEN v_has_credits THEN E'\nOwner credits have been added to your Building Society wallet.' ELSE '' END
  );

  v_league_body := format(
    E'%s have won %s — first club to complete %s of the %s %s challenges.\n\nPrize: %s',
    coalesce(v_club_name, p_club_short_name),
    v_pack_name,
    v_required,
    v_total,
    p_window_phase,
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

GRANT EXECUTE ON FUNCTION public.competition_challenge_required_to_win(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_challenge_settings(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_try_award_period_bonus(bigint, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_pack_summary(jsonb, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
