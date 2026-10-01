-- =============================================================================
-- Supporters' monthly lottery (2026-10-01)
--
-- • 1st of each real-world month (Europe/London): one current Ko-fi supporter
--   (gpsl_owner_registry.is_supporter = true) is drawn at random. Same owner
--   can win in consecutive months.
-- • The prize is also drawn at random (weighted) from supporter_lottery_prizes:
--     owner_credits  ₿500 into the owner's personal wallet
--     medical_token  2-match injury treatment (no club doctor needed)
--     ban_reduction  NEW: takes 1 match off a suspension (2-match ban → 1)
--     appeal_card    red-card appeal (admin can overturn the whole ban)
--     fee_discount   10% transfer fee discount
--   Club items go to the winner's club; a winner without a club gets credits.
-- • Winner gets an inbox message; #gpsl-news gets a Discord announcement.
-- • Admin → Owners → Supporters' lottery: prize weights, past winners, draw now.
--
-- Run after ko_fi_supporters_20260922.sql, medical_consultancy_identity.sql,
-- competition_challenge_draft_token_prize.sql and gpsl_discord_sky_feed.sql.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. New prize type: ban_reduction
-- ---------------------------------------------------------------------------
ALTER TABLE public.club_prize_inventory
  DROP CONSTRAINT IF EXISTS club_prize_inventory_prize_type_check;
ALTER TABLE public.club_prize_inventory
  ADD CONSTRAINT club_prize_inventory_prize_type_check
  CHECK (prize_type IN ('medical_token', 'fee_discount', 'appeal_card', 'draft_token', 'ban_reduction'));

ALTER TABLE public.club_prize_inventory
  DROP CONSTRAINT IF EXISTS club_prize_inventory_param_check;
ALTER TABLE public.club_prize_inventory
  ADD CONSTRAINT club_prize_inventory_param_check
  CHECK (
    (prize_type = 'medical_token' AND param_int IN (2, 4, 6, 8, 10))
    OR (prize_type = 'fee_discount' AND param_int > 0 AND param_int <= 50)
    OR (prize_type = 'appeal_card' AND param_int IS NULL)
    OR (prize_type = 'draft_token' AND param_int IS NULL)
    OR (prize_type = 'ban_reduction' AND param_int IS NULL)
  );

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
  v_meta jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_ident jsonb;
  v_consult_id bigint;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF p_prize_type NOT IN ('medical_token', 'fee_discount', 'appeal_card', 'draft_token', 'ban_reduction') THEN
    RAISE EXCEPTION 'Invalid prize type %', p_prize_type;
  END IF;

  IF p_prize_type = 'medical_token' THEN
    v_ident := public.medical_random_consultancy_identity();
    v_meta := v_meta || jsonb_build_object(
      'matches_removed', p_param_int,
      'group_name', v_ident->>'group_name',
      'consultant_name', v_ident->>'consultant_name',
      'label', v_ident->>'label',
      'consultancy_label', v_ident->>'label'
    );
  END IF;

  INSERT INTO public.club_prize_inventory (
    club_short_name, prize_type, param_int, source, season_id, window_phase, metadata
  )
  VALUES (
    v_club,
    p_prize_type,
    CASE
      WHEN p_prize_type IN ('appeal_card', 'draft_token', 'ban_reduction') THEN NULL
      ELSE p_param_int
    END,
    p_source,
    p_season_id,
    p_window_phase,
    v_meta
  )
  RETURNING id INTO v_id;

  IF p_prize_type = 'medical_token' THEN
    v_consult_id := public.medical_create_named_consult(
      v_club, p_param_int, coalesce(p_source, 'prize'), v_id, v_ident
    );
    UPDATE public.club_prize_inventory
    SET metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('consult_id', v_consult_id)
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.prize_grant_inventory_item(text, text, int, text, bigint, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prize_grant_inventory_item(text, text, int, text, bigint, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Lottery injury treatment works without a club doctor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.medical_list_available_consults(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_out jsonb;
BEGIN
  IF v_club IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  PERFORM public.medical_sync_named_consults(v_club);

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.matches_removed DESC, x.consult_id), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT
      c.id AS consult_id,
      c.matches_removed AS param_int,
      c.matches_removed,
      c.inventory_id,
      c.group_name,
      c.consultant_name,
      c.label,
      c.label AS consultancy_label,
      CASE WHEN c.inventory_id IS NULL THEN 'vault' ELSE 'prize' END AS kind,
      c.status,
      c.source,
      (c.source = 'supporters_lottery') AS no_doctor_ok
    FROM public.club_medical_consults c
    WHERE c.club_short_name = v_club
      AND c.status = 'available'
  ) x;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_list_available_consults(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.medical_apply_specialist_token(
  p_injury_id bigint,
  p_inventory_id bigint DEFAULT NULL,
  p_prefer_specialist boolean DEFAULT false,
  p_consult_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_inj public.competition_player_injuries%rowtype;
  v_remove int := 2;
  v_applied int := 0;
  v_tokens int;
  v_inv public.club_prize_inventory%rowtype;
  v_use_inventory boolean := false;
  v_consult public.club_medical_consults%rowtype;
  v_label text;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked to this account'; END IF;

  SELECT * INTO v_inj
  FROM public.competition_player_injuries
  WHERE id = p_injury_id
  FOR UPDATE;

  IF NOT FOUND OR v_inj.club_short_name IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Injury not found for your club';
  END IF;
  IF v_inj.status <> 'active' THEN
    RAISE EXCEPTION 'Injury is not active';
  END IF;
  IF EXISTS (SELECT 1 FROM public.club_medical_token_use WHERE injury_id = p_injury_id) THEN
    RAISE EXCEPTION 'A specialist consult was already used on this injury';
  END IF;

  PERFORM public.medical_ensure_centre(v_club);
  PERFORM public.medical_sync_named_consults(v_club);

  IF p_consult_id IS NOT NULL THEN
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE id = p_consult_id
    FOR UPDATE;

    IF NOT FOUND OR v_consult.club_short_name IS DISTINCT FROM v_club THEN
      RAISE EXCEPTION 'Consult not found';
    END IF;
    IF v_consult.status <> 'available' THEN
      RAISE EXCEPTION 'Consult not available';
    END IF;

    v_remove := v_consult.matches_removed;
    v_label := v_consult.label;
    p_inventory_id := v_consult.inventory_id;
    IF p_inventory_id IS NOT NULL THEN
      v_use_inventory := true;
    END IF;
  ELSIF p_inventory_id IS NOT NULL THEN
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE inventory_id = p_inventory_id
      AND status = 'available'
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      p_consult_id := v_consult.id;
      v_remove := v_consult.matches_removed;
      v_label := v_consult.label;
      v_use_inventory := true;
    ELSE
      SELECT * INTO v_inv
      FROM public.club_prize_inventory
      WHERE id = p_inventory_id
      FOR UPDATE;
      IF NOT FOUND OR v_inv.club_short_name IS DISTINCT FROM v_club THEN
        RAISE EXCEPTION 'Medical token not found';
      END IF;
      IF v_inv.prize_type <> 'medical_token' OR v_inv.status <> 'available' THEN
        RAISE EXCEPTION 'Medical token not available';
      END IF;
      v_remove := v_inv.param_int;
      v_use_inventory := true;
      v_label := coalesce(v_inv.metadata->>'label', v_inv.metadata->>'consultancy_label');
    END IF;
  ELSIF coalesce(p_prefer_specialist, false) THEN
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE club_short_name = v_club
      AND status = 'available'
      AND inventory_id IS NULL
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'No specialist tokens available';
    END IF;
    p_consult_id := v_consult.id;
    v_remove := v_consult.matches_removed;
    v_label := v_consult.label;
  ELSE
    -- Prefer strongest available named consult (prize or vault)
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE club_short_name = v_club
      AND status = 'available'
    ORDER BY matches_removed DESC, id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      p_consult_id := v_consult.id;
      v_remove := v_consult.matches_removed;
      v_label := v_consult.label;
      p_inventory_id := v_consult.inventory_id;
      v_use_inventory := (v_consult.inventory_id IS NOT NULL);
    ELSE
      RAISE EXCEPTION 'No specialist tokens available';
    END IF;
  END IF;

  -- Supporters' lottery treatments are the only consults usable without a doctor
  IF NOT public.medical_club_has_doctor(v_club)
     AND coalesce(v_consult.source, v_inv.source, '') <> 'supporters_lottery' THEN
    RAISE EXCEPTION 'A club doctor is required before using specialist consultants';
  END IF;

  IF coalesce(v_inj.matches_out_remaining, 0) > 0 THEN
    v_applied := least(v_remove, v_inj.matches_out_remaining);
    UPDATE public.competition_player_injuries
    SET matches_out_remaining = matches_out_remaining - v_applied
    WHERE id = p_injury_id;
  ELSIF coalesce(v_inj.recovery_remaining, 0) > 0 THEN
    v_applied := least(v_remove, v_inj.recovery_remaining);
    UPDATE public.competition_player_injuries
    SET recovery_remaining = recovery_remaining - v_applied
    WHERE id = p_injury_id;
  ELSE
    RAISE EXCEPTION 'Nothing left to shorten on this injury';
  END IF;

  UPDATE public.competition_player_injuries i
  SET status = 'recovered',
      recovered_at = coalesce(i.recovered_at, now())
  WHERE i.id = p_injury_id
    AND coalesce(i.matches_out_remaining, 0) <= 0
    AND coalesce(i.recovery_remaining, 0) <= 0;

  INSERT INTO public.club_medical_token_use (club_short_name, injury_id, matches_removed)
  VALUES (v_club, p_injury_id, v_applied);

  IF p_consult_id IS NOT NULL THEN
    UPDATE public.club_medical_consults
    SET status = 'consumed',
        consumed_at = now()
    WHERE id = p_consult_id;
  END IF;

  IF v_use_inventory AND p_inventory_id IS NOT NULL THEN
    UPDATE public.club_prize_inventory
    SET status = 'consumed',
        consumed_at = now(),
        updated_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'injury_id', p_injury_id,
          'matches_removed', v_applied,
          'label', v_label
        )
    WHERE id = p_inventory_id;
  ELSIF p_consult_id IS NOT NULL AND NOT v_use_inventory THEN
    UPDATE public.club_medical_centre
    SET specialist_tokens = greatest(0, specialist_tokens - 1),
        updated_at = now()
    WHERE club_short_name = v_club;
  END IF;

  IF to_regprocedure('public.competition_injury_assign_fixtures(bigint)') IS NOT NULL THEN
    PERFORM public.competition_injury_assign_fixtures(p_injury_id);
  END IF;

  SELECT specialist_tokens INTO v_tokens
  FROM public.club_medical_centre
  WHERE club_short_name = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'matches_removed', v_applied,
    'token_tier', v_remove,
    'inventory_id', p_inventory_id,
    'consult_id', p_consult_id,
    'label', v_label,
    'tokens_left', coalesce(v_tokens, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_apply_specialist_token(bigint, bigint, boolean, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Using a ban reduction
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_reducible_suspensions(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_out jsonb;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club'; END IF;
  IF NOT public.is_gpsl_admin() AND v_club IS DISTINCT FROM public.my_club_shortname() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.player_name), '[]'::jsonb)
  INTO v_out
  FROM (
    SELECT
      s.id AS suspension_id,
      s.player_id,
      s.reason,
      s.ban_matches,
      p."Name" AS player_name,
      (
        SELECT count(*)::int
        FROM public.competition_player_suspension_matches sm
        WHERE sm.suspension_id = s.id AND sm.served = false
      ) AS pending_matches
    FROM public.competition_player_suspensions s
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.player_id::text
    WHERE s.club_short_name = v_club
      AND s.status = 'active'
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_suspension_appeals a
        WHERE a.suspension_id = s.id AND a.status = 'pending'
      )
  ) x
  WHERE x.pending_matches > 0;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_reducible_suspensions(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.prize_use_ban_reduction(
  p_inventory_id bigint,
  p_suspension_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_inv public.club_prize_inventory%rowtype;
  v_sus public.competition_player_suspensions%rowtype;
  v_unserved int;
  v_drop_id bigint;
  v_new_ban int;
  v_left int;
  v_status text;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked to this account'; END IF;

  SELECT * INTO v_inv
  FROM public.club_prize_inventory
  WHERE id = p_inventory_id
  FOR UPDATE;
  IF NOT FOUND OR v_inv.club_short_name IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Ban reduction not found';
  END IF;
  IF v_inv.prize_type <> 'ban_reduction' OR v_inv.status <> 'available' THEN
    RAISE EXCEPTION 'Ban reduction not available';
  END IF;

  SELECT * INTO v_sus
  FROM public.competition_player_suspensions
  WHERE id = p_suspension_id
  FOR UPDATE;
  IF NOT FOUND OR v_sus.club_short_name IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Suspension not found for your club';
  END IF;
  IF v_sus.status <> 'active' THEN
    RAISE EXCEPTION 'Suspension is not active';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.competition_suspension_appeals a
    WHERE a.suspension_id = v_sus.id AND a.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'This ban has an appeal pending review';
  END IF;

  SELECT count(*)::int INTO v_unserved
  FROM public.competition_player_suspension_matches sm
  WHERE sm.suspension_id = v_sus.id AND sm.served = false;
  IF v_unserved <= 0 THEN
    RAISE EXCEPTION 'No matches left to serve on this ban';
  END IF;

  -- Drop the LAST banned match so the player still misses the nearest fixture(s)
  SELECT sm.id INTO v_drop_id
  FROM public.competition_player_suspension_matches sm
  WHERE sm.suspension_id = v_sus.id AND sm.served = false
  ORDER BY sm.sequence_no DESC
  LIMIT 1;

  DELETE FROM public.competition_player_suspension_matches WHERE id = v_drop_id;

  -- ban_matches drives resync, so it must drop too or the match comes back
  v_new_ban := v_sus.ban_matches - 1;
  v_left := v_unserved - 1;
  IF v_new_ban < 1 THEN
    v_status := 'cancelled';
    UPDATE public.competition_player_suspensions
    SET status = 'cancelled'
    WHERE id = v_sus.id;
  ELSE
    v_status := CASE WHEN v_left = 0 THEN 'completed' ELSE 'active' END;
    UPDATE public.competition_player_suspensions
    SET ban_matches = v_new_ban,
        status = v_status
    WHERE id = v_sus.id;
  END IF;

  UPDATE public.club_prize_inventory
  SET status = 'consumed',
      consumed_at = now(),
      updated_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'suspension_id', v_sus.id,
        'player_id', v_sus.player_id,
        'ban_before', v_sus.ban_matches,
        'matches_left', v_left
      )
  WHERE id = v_inv.id;

  RETURN jsonb_build_object(
    'ok', true,
    'suspension_id', v_sus.id,
    'player_id', v_sus.player_id,
    'matches_left', v_left,
    'status', v_status
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.prize_use_ban_reduction(bigint, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Inbox message type: supporter_lottery (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'supporter_lottery'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

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
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- 5. Lottery tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.supporter_lottery_prizes (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  prize_kind text NOT NULL UNIQUE
    CHECK (prize_kind IN ('owner_credits', 'medical_token', 'ban_reduction', 'appeal_card', 'fee_discount')),
  amount numeric(14, 2),
  param_int int,
  weight int NOT NULL DEFAULT 1 CHECK (weight >= 0),
  enabled boolean NOT NULL DEFAULT true,
  label text,
  sort_order smallint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supporter_lottery_prizes_param_check CHECK (
    (prize_kind = 'owner_credits' AND amount > 0)
    OR (prize_kind = 'medical_token' AND param_int IN (2, 4, 6, 8, 10))
    OR (prize_kind = 'fee_discount' AND param_int > 0 AND param_int <= 50)
    OR (prize_kind IN ('ban_reduction', 'appeal_card'))
  )
);

INSERT INTO public.supporter_lottery_prizes (prize_kind, amount, param_int, weight, sort_order)
VALUES
  ('owner_credits', 500, NULL, 1, 1),
  ('medical_token', NULL, 2, 1, 2),
  ('ban_reduction', NULL, NULL, 1, 3),
  ('appeal_card', NULL, NULL, 1, 4),
  ('fee_discount', NULL, 10, 1, 5)
ON CONFLICT (prize_kind) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.supporter_lottery_draws (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  draw_ym text NOT NULL UNIQUE,
  owner_id uuid NOT NULL,
  owner_tag text,
  club_short_name text,
  prize_kind text NOT NULL,
  prize_label text NOT NULL,
  amount numeric(14, 2),
  param_int int,
  inventory_id bigint,
  ledger_id bigint,
  entrants int NOT NULL DEFAULT 0,
  drawn_by text NOT NULL DEFAULT 'cron',
  drawn_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.supporter_lottery_prizes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supporter_lottery_draws ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS supporter_lottery_prizes_admin ON public.supporter_lottery_prizes;
CREATE POLICY supporter_lottery_prizes_admin ON public.supporter_lottery_prizes
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin()) WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS supporter_lottery_draws_admin ON public.supporter_lottery_draws;
CREATE POLICY supporter_lottery_draws_admin ON public.supporter_lottery_draws
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin()) WITH CHECK (public.is_gpsl_admin());

CREATE OR REPLACE FUNCTION public.supporter_lottery_prize_label(
  p_kind text,
  p_amount numeric,
  p_param_int int
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_kind
    WHEN 'owner_credits' THEN format('₿%s owner credits', to_char(coalesce(p_amount, 0), 'FM999,999,990'))
    WHEN 'medical_token' THEN format('%s-match injury treatment (no doctor needed)', coalesce(p_param_int, 2))
    WHEN 'ban_reduction' THEN '1-match ban reduction'
    WHEN 'appeal_card' THEN 'Red card appeal card'
    WHEN 'fee_discount' THEN format('%s%% transfer fee discount', coalesce(p_param_int, 10))
    ELSE p_kind
  END;
$$;

-- ---------------------------------------------------------------------------
-- 6. The draw
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.supporter_lottery_draw(
  p_force boolean DEFAULT false,
  p_drawn_by text DEFAULT 'cron'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_today date := public.supporter_london_today();
  v_ym text := public.supporter_london_ym(v_today);
  v_month_label text := to_char(v_today, 'FMMonth YYYY');
  v_entrants int;
  v_owner uuid;
  v_tag text;
  v_club text;
  v_prize public.supporter_lottery_prizes%rowtype;
  v_kind text;
  v_amount numeric(14, 2);
  v_param int;
  v_label text;
  v_season_id bigint;
  v_inv_id bigint;
  v_ledger_id bigint;
  v_where text;
  v_href text;
BEGIN
  IF NOT coalesce(p_force, false) AND extract(day FROM v_today) <> 1 THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'not_first_of_month', 'london_date', v_today);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('supporter_lottery_draw'));

  IF EXISTS (SELECT 1 FROM public.supporter_lottery_draws d WHERE d.draw_ym = v_ym) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'already_drawn', 'draw_ym', v_ym);
  END IF;

  SELECT count(*)::int INTO v_entrants
  FROM public.gpsl_owner_registry r
  WHERE r.is_supporter = true;

  IF coalesce(v_entrants, 0) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'no_supporters', 'draw_ym', v_ym);
  END IF;

  SELECT r.owner_id, coalesce(nullif(btrim(r.owner_tag), ''), c.owner_tag), c.club
  INTO v_owner, v_tag, v_club
  FROM public.gpsl_owner_registry r
  LEFT JOIN LATERAL (
    SELECT cl."ShortName" AS club, nullif(btrim(cl.owner), '') AS owner_tag
    FROM public."Clubs" cl
    WHERE cl.owner_id = r.owner_id
      AND cl."ShortName" IS DISTINCT FROM 'FOREIGN'
    ORDER BY cl."ShortName"
    LIMIT 1
  ) c ON true
  WHERE r.is_supporter = true
  ORDER BY random()
  LIMIT 1;

  -- Weighted random prize; club items need the winner to have a club
  SELECT * INTO v_prize
  FROM public.supporter_lottery_prizes p
  WHERE p.enabled AND p.weight > 0
    AND (v_club IS NOT NULL OR p.prize_kind = 'owner_credits')
  ORDER BY -ln(1.0 - random()) / p.weight
  LIMIT 1;

  IF FOUND THEN
    v_kind := v_prize.prize_kind;
    v_amount := v_prize.amount;
    v_param := v_prize.param_int;
  ELSE
    v_kind := 'owner_credits';
    v_amount := 500;
    v_param := NULL;
  END IF;
  v_label := coalesce(
    nullif(btrim(v_prize.label), ''),
    public.supporter_lottery_prize_label(v_kind, v_amount, v_param)
  );

  v_season_id := public.competition_active_season_id();

  IF v_kind = 'owner_credits' THEN
    PERFORM public.owner_wallet_ensure(v_owner);
    v_ledger_id := public._post_owner_ledger_internal(
      v_owner,
      'supporter_lottery_credit',
      v_amount,
      format('Supporters'' lottery — %s', v_month_label),
      jsonb_build_object('source', 'supporters_lottery', 'draw_ym', v_ym),
      v_season_id,
      true
    );
    v_where := 'It''s been paid into your personal Building Society wallet.';
    v_href := 'owners_bank.html';
  ELSE
    v_inv_id := public.prize_grant_inventory_item(
      v_club,
      v_kind,
      v_param,
      'supporters_lottery',
      v_season_id,
      NULL,
      jsonb_build_object('draw_ym', v_ym, 'owner_id', v_owner)
    );
    v_where := 'It''s waiting in your Rewards Centre — use it whenever you need it.';
    v_href := 'club_prizes.html';
  END IF;

  INSERT INTO public.supporter_lottery_draws (
    draw_ym, owner_id, owner_tag, club_short_name, prize_kind, prize_label,
    amount, param_int, inventory_id, ledger_id, entrants, drawn_by
  )
  VALUES (
    v_ym, v_owner, v_tag, v_club, v_kind, v_label,
    v_amount, v_param, v_inv_id, v_ledger_id, v_entrants, coalesce(p_drawn_by, 'cron')
  );

  BEGIN
    PERFORM public.owner_inbox_send(
      'supporter_lottery',
      '🎟️ You won the Supporters'' lottery!',
      format(
        'Congratulations — you were drawn from %s supporter%s in the %s Supporters'' lottery. Your prize: %s. %s Thanks for supporting GPSL!',
        v_entrants, CASE WHEN v_entrants = 1 THEN '' ELSE 's' END, v_month_label, v_label, v_where
      ),
      v_club,
      v_owner,
      NULL, NULL, NULL, NULL,
      v_href,
      format('supporter_lottery:%s', v_ym),
      NULL,
      v_season_id
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'supporter lottery inbox skipped: %', SQLERRM;
  END;

  BEGIN
    PERFORM public.gpsl_discord_feed_enqueue(
      'supporter_lottery',
      format('🎟️ SUPPORTERS'' LOTTERY — %s', v_month_label),
      format(
        '**%s**%s wins this month''s Supporters'' lottery: **%s**. Drawn from %s supporter%s — thank you all for keeping GPSL going!',
        coalesce(v_tag, 'A supporter'),
        CASE WHEN v_club IS NOT NULL THEN format(' (%s)', v_club) ELSE '' END,
        v_label,
        v_entrants, CASE WHEN v_entrants = 1 THEN '' ELSE 's' END
      ),
      16766720,
      format('supporter_lottery:%s', v_ym),
      jsonb_build_object('channel', 'news', 'club', v_club, 'prize_kind', v_kind, 'draw_ym', v_ym)
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'supporter lottery discord skipped: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'draw_ym', v_ym,
    'owner_id', v_owner,
    'owner_tag', v_tag,
    'club', v_club,
    'prize_kind', v_kind,
    'prize_label', v_label,
    'entrants', v_entrants
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.supporter_lottery_draw(boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.supporter_lottery_draw(boolean, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_supporter_lottery_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ym text := public.supporter_london_ym(public.supporter_london_today());
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN jsonb_build_object(
    'current_ym', v_ym,
    'drawn_this_month', EXISTS (SELECT 1 FROM public.supporter_lottery_draws WHERE draw_ym = v_ym),
    'prizes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', p.id,
        'prize_kind', p.prize_kind,
        'amount', p.amount,
        'param_int', p.param_int,
        'weight', p.weight,
        'enabled', p.enabled,
        'label', p.label,
        'default_label', public.supporter_lottery_prize_label(p.prize_kind, p.amount, p.param_int)
      ) ORDER BY p.sort_order, p.id)
      FROM public.supporter_lottery_prizes p
    ), '[]'::jsonb),
    'entrants', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'owner_id', r.owner_id,
        'owner_tag', coalesce(nullif(btrim(r.owner_tag), ''), c.owner, '—'),
        'club', c."ShortName"
      ) ORDER BY coalesce(nullif(btrim(r.owner_tag), ''), c.owner))
      FROM public.gpsl_owner_registry r
      LEFT JOIN LATERAL (
        SELECT cl."ShortName", nullif(btrim(cl.owner), '') AS owner
        FROM public."Clubs" cl
        WHERE cl.owner_id = r.owner_id AND cl."ShortName" IS DISTINCT FROM 'FOREIGN'
        ORDER BY cl."ShortName"
        LIMIT 1
      ) c ON true
      WHERE r.is_supporter = true
    ), '[]'::jsonb),
    'draws', coalesce((
      SELECT jsonb_agg(to_jsonb(d) ORDER BY d.draw_ym DESC)
      FROM (
        SELECT * FROM public.supporter_lottery_draws
        ORDER BY draw_ym DESC
        LIMIT 36
      ) d
    ), '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_supporter_lottery_save_prize(
  p_id bigint,
  p_weight int,
  p_enabled boolean,
  p_amount numeric DEFAULT NULL,
  p_param_int int DEFAULT NULL,
  p_label text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.supporter_lottery_prizes%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row FROM public.supporter_lottery_prizes WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prize not found';
  END IF;

  UPDATE public.supporter_lottery_prizes
  SET weight = greatest(0, coalesce(p_weight, weight)),
      enabled = coalesce(p_enabled, enabled),
      amount = CASE WHEN prize_kind = 'owner_credits' THEN coalesce(p_amount, amount) ELSE NULL END,
      param_int = CASE
        WHEN prize_kind IN ('medical_token', 'fee_discount') THEN coalesce(p_param_int, param_int)
        ELSE NULL
      END,
      label = nullif(btrim(coalesce(p_label, '')), ''),
      updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_supporter_lottery_draw_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.supporter_lottery_draw(true, 'admin');
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_supporter_lottery_state() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_supporter_lottery_save_prize(bigint, int, boolean, numeric, int, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_supporter_lottery_draw_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_supporter_lottery_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_supporter_lottery_save_prize(bigint, int, boolean, numeric, int, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_supporter_lottery_draw_now() TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Schedule: daily check, draws only on the 1st (London)
-- ---------------------------------------------------------------------------
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-supporter-lottery');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-supporter-lottery',
      '20 0 * * *',
      $$SELECT public.supporter_lottery_draw();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron supporter lottery schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
