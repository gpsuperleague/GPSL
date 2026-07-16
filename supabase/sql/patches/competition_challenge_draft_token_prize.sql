-- =============================================================================
-- Challenge prize: draft_token
-- Winner can sign any uncontracted player at market value (central bank).
-- If squad is full (28), must release a squad player first at their market value.
--
-- Run after competition_challenge_prize_packs.sql (+ part2) and
-- competition_challenge_big_prize_announce.sql
-- Safe re-run.
-- =============================================================================

-- Widen inventory prize types
ALTER TABLE public.club_prize_inventory
  DROP CONSTRAINT IF EXISTS club_prize_inventory_prize_type_check;

ALTER TABLE public.club_prize_inventory
  ADD CONSTRAINT club_prize_inventory_prize_type_check
  CHECK (prize_type IN ('medical_token', 'fee_discount', 'appeal_card', 'draft_token'));

ALTER TABLE public.club_prize_inventory
  DROP CONSTRAINT IF EXISTS club_prize_inventory_param_check;

ALTER TABLE public.club_prize_inventory
  ADD CONSTRAINT club_prize_inventory_param_check
  CHECK (
    (prize_type = 'medical_token' AND param_int IN (2, 4, 6, 8, 10))
    OR (prize_type = 'fee_discount' AND param_int > 0 AND param_int <= 50)
    OR (prize_type = 'appeal_card' AND param_int IS NULL)
    OR (prize_type = 'draft_token' AND param_int IS NULL)
  );

-- Grant helper: allow draft_token (null param)
CREATE OR REPLACE FUNCTION public.prize_grant_inventory_item(
  p_club text,
  p_prize_type text,
  p_param_int int,
  p_source text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_window_phase text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_club text := btrim(p_club);
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF p_prize_type NOT IN ('medical_token', 'fee_discount', 'appeal_card', 'draft_token') THEN
    RAISE EXCEPTION 'Invalid prize type %', p_prize_type;
  END IF;

  INSERT INTO public.club_prize_inventory (
    club_short_name, prize_type, param_int, source, season_id, window_phase, metadata
  )
  VALUES (
    v_club,
    p_prize_type,
    CASE
      WHEN p_prize_type IN ('appeal_card', 'draft_token') THEN NULL
      ELSE p_param_int
    END,
    p_source,
    p_season_id,
    p_window_phase,
    coalesce(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Period pack grant includes draft_tokens count
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

  RETURN jsonb_build_object(
    'cash_amount', coalesce(v_pack.cash_amount, 0),
    'pack', v_pack.pack,
    'granted', v_granted
  );
END;
$function$;

-- Pack summary text includes draft tokens
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

-- Preview before spending a draft token
CREATE OR REPLACE FUNCTION public.prize_draft_token_preview(
  p_sign_player_id text,
  p_release_player_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_sign public."Players"%rowtype;
  v_rel public."Players"%rowtype;
  v_sign_id text := btrim(coalesce(p_sign_player_id, ''));
  v_rel_id text := nullif(btrim(coalesce(p_release_player_id, '')), '');
  v_squad int;
  v_max int := public.squad_max_size();
  v_bal numeric;
  v_sign_mv numeric;
  v_rel_mv numeric := 0;
  v_tokens int;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked';
  END IF;

  SELECT count(*)::int INTO v_tokens
  FROM public.club_prize_inventory
  WHERE club_short_name = v_club
    AND prize_type = 'draft_token'
    AND status = 'available';

  SELECT * INTO v_sign
  FROM public."Players"
  WHERE "Konami_ID"::text = v_sign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sign target player not found';
  END IF;

  v_sign_mv := greatest(coalesce(nullif(btrim(v_sign.market_value::text), '')::numeric, 0), 0);
  v_squad := public.club_squad_player_count(v_club);

  SELECT coalesce(balance, 0) INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  IF v_rel_id IS NOT NULL THEN
    SELECT * INTO v_rel
    FROM public."Players"
    WHERE "Konami_ID"::text = v_rel_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Release player not found';
    END IF;
    IF btrim(coalesce(v_rel."Contracted_Team"::text, '')) IS DISTINCT FROM v_club THEN
      RAISE EXCEPTION 'Release player is not at your club';
    END IF;
    v_rel_mv := greatest(coalesce(nullif(btrim(v_rel.market_value::text), '')::numeric, 0), 0);
  END IF;

  RETURN jsonb_build_object(
    'club', v_club,
    'draft_tokens_available', v_tokens,
    'squad_count', v_squad,
    'squad_max', v_max,
    'needs_release', v_squad >= v_max,
    'balance', coalesce(v_bal, 0),
    'sign_player_id', v_sign_id,
    'sign_player_name', v_sign."Name",
    'sign_market_value', v_sign_mv,
    'sign_is_free_agent', nullif(btrim(coalesce(v_sign."Contracted_Team"::text, '')), '') IS NULL,
    'release_player_id', v_rel_id,
    'release_player_name', v_rel."Name",
    'release_market_value', v_rel_mv,
    'net_cash_needed', greatest(v_sign_mv - v_rel_mv, 0),
    'can_afford', coalesce(v_bal, 0) >= greatest(v_sign_mv - v_rel_mv, 0)
  );
END;
$function$;

-- Spend draft token: optional release at MV, then sign free agent at MV
CREATE OR REPLACE FUNCTION public.prize_use_draft_token(
  p_inventory_id bigint,
  p_sign_player_id text,
  p_release_player_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_inv public.club_prize_inventory%rowtype;
  v_sign public."Players"%rowtype;
  v_rel public."Players"%rowtype;
  v_sign_id text := btrim(coalesce(p_sign_player_id, ''));
  v_rel_id text := nullif(btrim(coalesce(p_release_player_id, '')), '');
  v_squad int;
  v_max int := public.squad_max_size();
  v_bal numeric;
  v_sign_mv numeric;
  v_rel_mv numeric := 0;
  v_hist_rel bigint;
  v_hist_sign bigint;
  v_net numeric;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked';
  END IF;
  IF v_sign_id = '' THEN
    RAISE EXCEPTION 'Player to sign is required';
  END IF;

  SELECT * INTO v_inv
  FROM public.club_prize_inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Draft token not found';
  END IF;
  IF v_inv.club_short_name IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not your draft token';
  END IF;
  IF v_inv.prize_type <> 'draft_token' OR v_inv.status <> 'available' THEN
    RAISE EXCEPTION 'Draft token is not available';
  END IF;

  SELECT * INTO v_sign
  FROM public."Players"
  WHERE "Konami_ID"::text = v_sign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player to sign not found';
  END IF;

  IF nullif(btrim(coalesce(v_sign."Contracted_Team"::text, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'Player is already contracted to %', v_sign."Contracted_Team";
  END IF;

  PERFORM public.assert_player_available_for_signing(v_sign_id);

  v_sign_mv := greatest(coalesce(nullif(btrim(v_sign.market_value::text), '')::numeric, 0), 0);
  IF v_sign_mv <= 0 THEN
    RAISE EXCEPTION 'Player has no market value';
  END IF;

  v_squad := public.club_squad_player_count(v_club);

  IF v_squad >= v_max THEN
    IF v_rel_id IS NULL THEN
      RAISE EXCEPTION 'Squad is full (%). Choose a player to release at market value first.', v_max;
    END IF;
  ELSIF v_rel_id IS NOT NULL AND v_squad + 1 > v_max THEN
    NULL; -- still allow optional release
  END IF;

  SELECT coalesce(balance, 0) INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found';
  END IF;

  -- Optional / required release at MV (no overflow fine, no paid-up lock)
  IF v_rel_id IS NOT NULL THEN
    IF v_rel_id = v_sign_id THEN
      RAISE EXCEPTION 'Cannot release and sign the same player';
    END IF;

    SELECT * INTO v_rel
    FROM public."Players"
    WHERE "Konami_ID"::text = v_rel_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Release player not found';
    END IF;
    IF btrim(coalesce(v_rel."Contracted_Team"::text, '')) IS DISTINCT FROM v_club THEN
      RAISE EXCEPTION 'Release player is not at your club';
    END IF;

    v_rel_mv := greatest(coalesce(nullif(btrim(v_rel.market_value::text), '')::numeric, 0), 0);

    UPDATE public."Player_Transfer_Listings" l
    SET status = 'Closed',
        transfer_completed = false
    WHERE l.player_id::text = v_rel_id
      AND l.seller_club_id = v_club
      AND l.status IN ('Active', 'Review');

    PERFORM public.player_release_from_club(v_rel_id);

    INSERT INTO public."Transfer_History" (
      player_id, seller_club_id, buyer_club_id, fee, agent_fee,
      transfer_time, listing_id, foreign_buyer_name, transfer_sale_note
    )
    VALUES (
      v_rel_id, v_club, 'FOREIGN', v_rel_mv, 0,
      now(), NULL, 'Draft token release (market value)', 'draft_token_release'
    )
    RETURNING id INTO v_hist_rel;

    PERFORM public.post_transfer_ledger_for_history(v_hist_rel, true);

    SELECT coalesce(balance, 0) INTO v_bal
    FROM public."Club_Finances"
    WHERE club_name = v_club;
  ELSIF v_squad >= v_max THEN
    RAISE EXCEPTION 'Squad is full (%). Choose a player to release at market value first.', v_max;
  END IF;

  v_net := v_sign_mv;
  IF v_bal < v_net THEN
    RAISE EXCEPTION 'Insufficient balance (need ₿%, have ₿%)',
      to_char(v_net, 'FM999,999,999,999'),
      to_char(v_bal, 'FM999,999,999,999');
  END IF;

  -- Close any open draft listing for the free agent (token bypasses auction)
  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id::text = v_sign_id
    AND l.listing_type = 'draft'
    AND l.status IN ('Active', 'Review');

  PERFORM public.player_assign_to_club(v_sign_id, v_club, NULL::numeric, false);

  INSERT INTO public."Transfer_History" (
    player_id, seller_club_id, buyer_club_id, fee, agent_fee,
    transfer_time, listing_id, transfer_sale_note
  )
  VALUES (
    v_sign_id, NULL, v_club, v_sign_mv, 0,
    now(), NULL, 'draft_token_sign'
  )
  RETURNING id INTO v_hist_sign;

  PERFORM public.post_transfer_ledger_for_history(v_hist_sign, true);

  UPDATE public.club_prize_inventory
  SET status = 'consumed',
      consumed_at = now(),
      updated_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'signed_player_id', v_sign_id,
        'signed_player_name', v_sign."Name",
        'sign_fee', v_sign_mv,
        'released_player_id', v_rel_id,
        'release_fee', v_rel_mv,
        'used_at', now()
      )
  WHERE id = v_inv.id;

  BEGIN
    PERFORM public.owner_inbox_send(
      'transfer_signed',
      format('Draft token used — signed %s', coalesce(v_sign."Name", v_sign_id)),
      format(
        E'You used a challenge draft token.\nSigned: %s for ₿%s.%s\nSquad is now %s/%s.',
        coalesce(v_sign."Name", v_sign_id),
        to_char(v_sign_mv, 'FM999,999,999,999'),
        CASE
          WHEN v_rel_id IS NOT NULL THEN format(
            E'\nReleased: %s for ₿%s (market value).',
            coalesce(v_rel."Name", v_rel_id),
            to_char(v_rel_mv, 'FM999,999,999,999')
          )
          ELSE ''
        END,
        public.club_squad_player_count(v_club),
        v_max
      ),
      v_club,
      NULL, NULL, NULL, v_hist_sign, NULL,
      'club_prizes.html',
      format('draft_token_used:%s:%s', v_inv.id, v_sign_id),
      NULL,
      NULL
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'inventory_id', v_inv.id,
    'signed_player_id', v_sign_id,
    'signed_player_name', v_sign."Name",
    'sign_fee', v_sign_mv,
    'released_player_id', v_rel_id,
    'released_player_name', v_rel."Name",
    'release_fee', v_rel_mv,
    'squad_count', public.club_squad_player_count(v_club),
    'squad_max', v_max
  );
END;
$function$;

-- Squad list helper for release picker
CREATE OR REPLACE FUNCTION public.prize_draft_token_squad_options()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'player_id', p."Konami_ID"::text,
        'name', p."Name",
        'rating', p."Rating",
        'market_value', greatest(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0), 0),
        'position', p."Position"
      )
      ORDER BY public.player_rating_as_numeric(p."Rating") DESC, p."Name"
    )
    FROM public."Players" p
    WHERE p."Contracted_Team" = v_club
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.prize_draft_token_preview(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.prize_use_draft_token(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.prize_draft_token_squad_options() TO authenticated;

NOTIFY pgrst, 'reload schema';
