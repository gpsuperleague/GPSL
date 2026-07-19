-- =============================================================================
-- Discord transfer gossip → Transfer News ticker rumours + idle gossip
--
-- Trigger format (exact):
--   {Club} are interested in {Player}
--   e.g. Jubilo are interested in Alexander Isak
--
-- Channel: #gpsl-transfer-gossip
-- Edge: discord-transfer-gossip-ingest (poll every 2 min like friendlies)
--
-- Ticker: max 5 — real deals first, then Discord rumours, then mild idle gossip.
-- Rumours expire end of UK calendar day.
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_transfer_rumours (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id),
  source text NOT NULL CHECK (source IN ('discord', 'idle')),
  kind text NOT NULL CHECK (kind IN ('rumour', 'idle')),
  club_short_name text,
  club_name text,
  player_id text,
  player_name text,
  headline text NOT NULL,
  discord_message_id text,
  discord_user_id text,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_transfer_rumours_discord_msg_uidx
  ON public.gpsl_transfer_rumours (discord_message_id)
  WHERE discord_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS gpsl_transfer_rumours_active_idx
  ON public.gpsl_transfer_rumours (season_id, expires_at DESC, created_at DESC);

ALTER TABLE public.gpsl_transfer_rumours ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_transfer_rumours_select ON public.gpsl_transfer_rumours;
CREATE POLICY gpsl_transfer_rumours_select
  ON public.gpsl_transfer_rumours
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS gpsl_transfer_rumours_admin ON public.gpsl_transfer_rumours;
CREATE POLICY gpsl_transfer_rumours_admin
  ON public.gpsl_transfer_rumours
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.gpsl_transfer_rumours TO authenticated;
GRANT ALL ON public.gpsl_transfer_rumours TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.gpsl_transfer_rumours_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_rumour_uk_day_end(p_at timestamptz DEFAULT now())
RETURNS timestamptz
LANGUAGE sql
STABLE
AS $$
  SELECT (
    ((p_at AT TIME ZONE 'Europe/London')::date + 1)
    AT TIME ZONE 'Europe/London'
  );
$$;

CREATE OR REPLACE FUNCTION public.gpsl_rumour_resolve_club(p_text text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := nullif(btrim(coalesce(p_text, '')), '');
  v_short text;
  v_name text;
BEGIN
  IF v_q IS NULL THEN
    RETURN NULL;
  END IF;

  -- Exact short name
  SELECT c."ShortName", c."Club" INTO v_short, v_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(v_q)
  LIMIT 1;
  IF v_short IS NOT NULL THEN
    RETURN jsonb_build_object('short_name', v_short, 'club_name', v_name);
  END IF;

  -- Exact full name
  SELECT c."ShortName", c."Club" INTO v_short, v_name
  FROM public."Clubs" c
  WHERE lower(c."Club") = lower(v_q)
  LIMIT 1;
  IF v_short IS NOT NULL THEN
    RETURN jsonb_build_object('short_name', v_short, 'club_name', v_name);
  END IF;

  -- Starts with / contains (Jubilo → Jubilo Iwata)
  SELECT c."ShortName", c."Club" INTO v_short, v_name
  FROM public."Clubs" c
  WHERE lower(c."Club") LIKE lower(v_q) || '%'
     OR lower(c."Club") LIKE '%' || lower(v_q) || '%'
  ORDER BY
    CASE WHEN lower(c."Club") LIKE lower(v_q) || '%' THEN 0 ELSE 1 END,
    length(c."Club")
  LIMIT 1;

  IF v_short IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('short_name', v_short, 'club_name', v_name);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_rumour_resolve_player(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := nullif(btrim(coalesce(p_name, '')), '');
  v_id text;
  v_name text;
  v_n int;
BEGIN
  IF v_q IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT p."Konami_ID"::text, p."Name"
  INTO v_id, v_name
  FROM public."Players" p
  WHERE lower(btrim(p."Name")) = lower(v_q)
  LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('player_id', v_id, 'player_name', v_name);
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public."Players" p
  WHERE lower(p."Name") LIKE '%' || lower(v_q) || '%';

  IF v_n = 1 THEN
    SELECT p."Konami_ID"::text, p."Name"
    INTO v_id, v_name
    FROM public."Players" p
    WHERE lower(p."Name") LIKE '%' || lower(v_q) || '%'
    LIMIT 1;
    RETURN jsonb_build_object('player_id', v_id, 'player_name', v_name);
  END IF;

  -- Prefer unique surname match
  SELECT count(*)::int INTO v_n
  FROM public."Players" p
  WHERE lower(p."Name") LIKE '% ' || lower(v_q)
     OR lower(p."Name") = lower(v_q);

  IF v_n = 1 THEN
    SELECT p."Konami_ID"::text, p."Name"
    INTO v_id, v_name
    FROM public."Players" p
    WHERE lower(p."Name") LIKE '% ' || lower(v_q)
       OR lower(p."Name") = lower(v_q)
    LIMIT 1;
    RETURN jsonb_build_object('player_id', v_id, 'player_name', v_name);
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_rumour_discord_headline(
  p_club_name text,
  p_player_name text
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club_name), ''), 'A GPSL club');
  v_player text := coalesce(nullif(btrim(p_player_name), ''), 'a target');
  v_pick int := 1 + floor(random() * 5)::int;
BEGIN
  RETURN CASE v_pick
    WHEN 1 THEN format('RUMOUR: %s are tracking %s', v_club, v_player)
    WHEN 2 THEN format('RUMOUR: %s are considering an approach for %s', v_club, v_player)
    WHEN 3 THEN format('RUMOUR: %s have been scouting %s — offer imminent, say sources', v_club, v_player)
    WHEN 4 THEN format('RUMOUR: %s in private talks with %s', v_player, v_club)
    ELSE format('RUMOUR: %s sporting director and manager split over %s', v_club, v_player)
  END;
END;
$function$;

-- Filtered, shortened idle templates (no NSFW / personal affairs / betting)
CREATE OR REPLACE FUNCTION public.gpsl_rumour_idle_templates()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'RUMOUR: Auditors query {club} over mystery consultancy fees — board calls it "analytics"',
    'RUMOUR: {club} paid an agent''s cousin for "scouting" — cousin has never watched a match',
    'RUMOUR: {club} accused of creative wage accounting via a "wellness programme"',
    'RUMOUR: {club} owner storms training demanding "more direct football"; manager hands him the tactics board',
    'RUMOUR: {club} owner tries to pick the XI; manager refuses the favourite',
    'RUMOUR: {club} owner wants nephew "who''s good at Excel" as lead analyst; manager threatens to walk',
    'RUMOUR: {club} striker claims unpaid goal bonuses; owner says only for "important goals"',
    'RUMOUR: {club} squad groan at owner''s 45-minute dressing-room PowerPoints',
    'RUMOUR: Contract talks at {club} stall over docking wages for looking "disinterested"',
    'RUMOUR: Agent claims {club} wanted fines for misplaced passes; club won''t show the paperwork',
    'RUMOUR: Backup keeper at {club} earns more than the top scorer — dressing room erupts',
    'RUMOUR: {club} sign shirt sponsor with a one-page site that just says "Coming Soon"',
    'RUMOUR: Training-ground reno budget at {club} doubles amid private-lounge whispers',
    'RUMOUR: {club} owner bans ketchup in the canteen; manager quietly puts it back',
    'RUMOUR: Fans spot burner accounts defending {club}''s owner — all created the same day',
    'RUMOUR: {club} unveil a giant pineapple mascot; players refuse the walkout',
    'RUMOUR: {player} linked with a quiet contract tweak at {club} before the window shuts',
    'RUMOUR: {club} manager and board "not aligned" on whether to cash in on {player}',
    'RUMOUR: Agents circle {player} as {club} go quiet on renewal talks'
  ];
$$;

CREATE OR REPLACE FUNCTION public.gpsl_rumour_ensure_idle(
  p_season_id bigint,
  p_need int DEFAULT 2
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_have int;
  v_need int := greatest(0, least(coalesce(p_need, 2), 3));
  v_i int;
  v_tpl text;
  v_club_short text;
  v_club_name text;
  v_player_id text;
  v_player_name text;
  v_headline text;
  v_expires timestamptz := public.gpsl_rumour_uk_day_end(now());
  v_templates text[] := public.gpsl_rumour_idle_templates();
BEGIN
  IF p_season_id IS NULL OR v_need < 1 THEN
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_have
  FROM public.gpsl_transfer_rumours r
  WHERE r.season_id = p_season_id
    AND r.source = 'idle'
    AND r.expires_at > now();

  FOR v_i IN 1..(v_need - coalesce(v_have, 0)) LOOP
    SELECT c."ShortName", c."Club"
    INTO v_club_short, v_club_name
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND coalesce(c."ShortName", '') NOT IN ('FOREIGN', 'GPDB')
    ORDER BY random()
    LIMIT 1;

    IF v_club_short IS NULL THEN
      EXIT;
    END IF;

    SELECT p."Konami_ID"::text, p."Name"
    INTO v_player_id, v_player_name
    FROM public."Players" p
    WHERE nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
      AND (
        upper(btrim(p."Contracted_Team")) = upper(v_club_short)
        OR lower(btrim(p."Contracted_Team")) = lower(v_club_name)
      )
    ORDER BY random()
    LIMIT 1;

    IF v_player_name IS NULL THEN
      SELECT p."Konami_ID"::text, p."Name"
      INTO v_player_id, v_player_name
      FROM public."Players" p
      WHERE nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_player_name IS NULL THEN
      v_player_name := 'a key player';
    END IF;

    v_tpl := v_templates[1 + floor(random() * array_length(v_templates, 1))::int];
    v_headline := replace(v_tpl, '{club}', coalesce(v_club_name, v_club_short));
    v_headline := replace(v_headline, '{player}', coalesce(v_player_name, 'a key player'));

    INSERT INTO public.gpsl_transfer_rumours (
      season_id, source, kind, club_short_name, club_name,
      player_id, player_name, headline, expires_at
    )
    VALUES (
      p_season_id, 'idle', 'idle', v_club_short, v_club_name,
      v_player_id, v_player_name, v_headline, v_expires
    );
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Discord ingest
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_transfer_gossip_ingest_post(
  p_discord_message_id text,
  p_discord_user_id text,
  p_content text,
  p_posted_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_msg text := nullif(btrim(coalesce(p_discord_message_id, '')), '');
  v_raw text := btrim(coalesce(p_content, ''));
  v_club_text text;
  v_player_text text;
  v_m text[];
  v_club jsonb;
  v_player jsonb;
  v_season_id bigint;
  v_headline text;
  v_id bigint;
  v_month text;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_msg IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Missing message id');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpsl_transfer_rumours r WHERE r.discord_message_id = v_msg
  ) THEN
    RETURN jsonb_build_object('ok', true, 'status', 'duplicate', 'reason', 'Already ingested');
  END IF;

  v_raw := regexp_replace(v_raw, E'[\\u2013\\u2014\\u2212]', '-', 'g');
  v_raw := regexp_replace(v_raw, E'[\\u200B-\\u200D\\uFEFF]', '', 'g');
  v_raw := btrim(v_raw);

  -- "{Club} are interested in {Player}"
  v_m := regexp_match(v_raw, '^(.+?)\s+are\s+interested\s+in\s+(.+)$', 'i');
  IF v_m IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Bad format — use: Club are interested in Player'
    );
  END IF;

  v_club_text := btrim(v_m[1]);
  v_player_text := btrim(v_m[2]);

  v_club := public.gpsl_rumour_resolve_club(v_club_text);
  IF v_club IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', format('Unknown club "%s"', v_club_text)
    );
  END IF;

  v_player := public.gpsl_rumour_resolve_player(v_player_text);
  IF v_player IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', format('Unknown or ambiguous player "%s"', v_player_text)
    );
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'No current season');
  END IF;

  BEGIN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, coalesce(p_posted_at, now())), ''));
  EXCEPTION WHEN OTHERS THEN
    v_month := '';
  END;

  IF v_month IS NULL OR v_month = '' OR v_month NOT IN ('june', 'july', 'august', 'january') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Outside transfer news window (Jun/Jul/Aug/Jan)'
    );
  END IF;

  v_headline := public.gpsl_rumour_discord_headline(
    v_club ->> 'club_name',
    v_player ->> 'player_name'
  );

  INSERT INTO public.gpsl_transfer_rumours (
    season_id, source, kind, club_short_name, club_name,
    player_id, player_name, headline,
    discord_message_id, discord_user_id, expires_at
  )
  VALUES (
    v_season_id, 'discord', 'rumour',
    v_club ->> 'short_name', v_club ->> 'club_name',
    v_player ->> 'player_id', v_player ->> 'player_name',
    v_headline,
    v_msg, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
    public.gpsl_rumour_uk_day_end(coalesce(p_posted_at, now()))
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'rumour',
    'rumour_id', v_id,
    'headline', v_headline,
    'club', v_club ->> 'short_name',
    'player', v_player ->> 'player_name'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_gossip_ingest_post(text, text, text, timestamptz)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- Transfer news feed: deals + rumours + idle (max 5)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_transfer_news_feed(
  p_force_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_label text;
  v_uk_today date;
  v_win_start timestamptz;
  v_win_end timestamptz;
  v_stories jsonb := '[]'::jsonb;
  v_row record;
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee_label text;
  v_method text;
  v_listing_type text;
  v_headline text;
  v_body text;
  v_kind text;
  v_need int := 5;
  v_count int := 0;
  v_ids bigint[] := ARRAY[]::bigint[];
  v_force text := lower(nullif(btrim(coalesce(p_force_month, '')), ''));
  v_window_months text[] := ARRAY['june', 'july', 'august', 'january'];
  v_rumour record;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('visible', false, 'reason', 'no_season', 'stories', '[]'::jsonb);
  END IF;

  BEGIN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  EXCEPTION WHEN OTHERS THEN
    v_month := '';
  END;

  IF v_force IS NOT NULL THEN
    IF NOT (v_force = ANY (v_window_months)) THEN
      RAISE EXCEPTION 'force month must be june, july, august, or january';
    END IF;
    v_month := v_force;
  END IF;

  IF NOT (v_month = ANY (v_window_months)) THEN
    RETURN jsonb_build_object(
      'visible', false,
      'reason', 'outside_transfer_news_months',
      'gpsl_month', nullif(v_month, ''),
      'stories', '[]'::jsonb
    );
  END IF;

  BEGIN
    v_month_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION WHEN OTHERS THEN
    v_month_label := initcap(v_month);
  END;

  v_uk_today := (now() AT TIME ZONE 'Europe/London')::date;

  SELECT m.unlock_at, m.lock_at
  INTO v_win_start, v_win_end
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season_id
    AND lower(m.gpsl_month) = v_month
  LIMIT 1;

  -- 1) Today's deals
  FOR v_row IN
    SELECT
      h.id, h.player_id, h.seller_club_id, h.buyer_club_id, h.fee,
      h.transfer_time, h.listing_id, h.foreign_buyer_name, h.transfer_sale_note,
      l.listing_type
    FROM public."Transfer_History" h
    LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
    WHERE coalesce(h.transfer_sale_note, '') NOT IN (
      'voluntary_contract_release', 'squad_overflow', 'new_owner_release'
    )
      AND (h.transfer_time AT TIME ZONE 'Europe/London')::date = v_uk_today
    ORDER BY coalesce(h.fee, 0) DESC, h.transfer_time DESC, h.id DESC
    LIMIT v_need
  LOOP
    v_ids := array_append(v_ids, v_row.id);
    v_listing_type := lower(coalesce(v_row.listing_type, ''));

    SELECT p."Name" INTO v_name FROM public."Players" p
    WHERE p."Konami_ID"::text = v_row.player_id::text LIMIT 1;
    v_name := coalesce(nullif(btrim(v_name), ''), 'Player');

    SELECT coalesce(c."Club", v_row.seller_club_id) INTO v_seller
    FROM public."Clubs" c WHERE c."ShortName" = v_row.seller_club_id LIMIT 1;
    v_seller := coalesce(v_seller, nullif(btrim(v_row.seller_club_id), ''), 'Free agent');

    IF v_row.buyer_club_id = 'FOREIGN' THEN
      v_buyer := coalesce(nullif(btrim(v_row.foreign_buyer_name), ''), 'Foreign club');
    ELSE
      SELECT coalesce(c."Club", v_row.buyer_club_id) INTO v_buyer
      FROM public."Clubs" c WHERE c."ShortName" = v_row.buyer_club_id LIMIT 1;
      v_buyer := coalesce(v_buyer, v_row.buyer_club_id, 'Unknown');
    END IF;

    BEGIN
      v_fee_label := public.transfer_format_money(coalesce(v_row.fee, 0));
    EXCEPTION WHEN OTHERS THEN
      v_fee_label := coalesce(v_row.fee, 0)::text;
    END;

    BEGIN
      v_method := public.transfer_classify_method(
        v_row.seller_club_id, v_row.buyer_club_id, v_row.listing_id,
        v_row.transfer_sale_note, v_row.foreign_buyer_name, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      v_method := CASE WHEN v_listing_type = 'draft' THEN 'Draft auction' ELSE 'Transfer' END;
    END;

    IF v_listing_type = 'draft' OR v_method ILIKE 'Draft%' THEN
      v_kind := 'draft';
      v_headline := format('DRAFT DEAL — %s joins %s', v_name, v_buyer);
      v_body := coalesce(v_method, 'Draft auction');
    ELSE
      v_kind := 'transfer';
      v_headline := format('DONE DEAL — %s', v_name);
      v_body := format('%s → %s · %s', v_seller, v_buyer, v_fee_label);
      IF v_method IS NOT NULL THEN
        v_body := v_body || ' · ' || v_method;
      END IF;
    END IF;

    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'id', 'transfer:' || v_row.id::text,
        'kind', v_kind,
        'kicker', 'TRANSFER NEWS',
        'headline', v_headline,
        'body', v_body,
        'href', 'transfer_center.html',
        'fee', coalesce(v_row.fee, 0),
        'transfer_time', v_row.transfer_time
      )
    );
    v_count := v_count + 1;
  END LOOP;

  -- 2) Pad with window deals if needed
  IF v_count < 5 THEN
    v_need := 5 - v_count;
    FOR v_row IN
      SELECT
        h.id, h.player_id, h.seller_club_id, h.buyer_club_id, h.fee,
        h.transfer_time, h.listing_id, h.foreign_buyer_name, h.transfer_sale_note,
        l.listing_type
      FROM public."Transfer_History" h
      LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
      WHERE coalesce(h.transfer_sale_note, '') NOT IN (
        'voluntary_contract_release', 'squad_overflow', 'new_owner_release'
      )
        AND NOT (h.id = ANY (v_ids))
        AND (
          (v_win_start IS NOT NULL AND h.transfer_time >= v_win_start
            AND h.transfer_time < coalesce(v_win_end, now() + interval '1 day'))
          OR (v_win_start IS NULL AND h.transfer_time >= (now() - interval '30 days'))
        )
      ORDER BY coalesce(h.fee, 0) DESC, h.transfer_time DESC, h.id DESC
      LIMIT v_need
    LOOP
      SELECT p."Name" INTO v_name FROM public."Players" p
      WHERE p."Konami_ID"::text = v_row.player_id::text LIMIT 1;
      v_name := coalesce(nullif(btrim(v_name), ''), 'Player');

      SELECT coalesce(c."Club", v_row.seller_club_id) INTO v_seller
      FROM public."Clubs" c WHERE c."ShortName" = v_row.seller_club_id LIMIT 1;
      v_seller := coalesce(v_seller, nullif(btrim(v_row.seller_club_id), ''), 'Free agent');

      IF v_row.buyer_club_id = 'FOREIGN' THEN
        v_buyer := coalesce(nullif(btrim(v_row.foreign_buyer_name), ''), 'Foreign club');
      ELSE
        SELECT coalesce(c."Club", v_row.buyer_club_id) INTO v_buyer
        FROM public."Clubs" c WHERE c."ShortName" = v_row.buyer_club_id LIMIT 1;
        v_buyer := coalesce(v_buyer, v_row.buyer_club_id, 'Unknown');
      END IF;

      BEGIN
        v_fee_label := public.transfer_format_money(coalesce(v_row.fee, 0));
      EXCEPTION WHEN OTHERS THEN
        v_fee_label := coalesce(v_row.fee, 0)::text;
      END;

      v_listing_type := lower(coalesce(v_row.listing_type, ''));
      IF v_listing_type = 'draft' THEN
        v_kind := 'draft';
        v_headline := format('DRAFT DEAL — %s joins %s', v_name, v_buyer);
        v_body := 'Draft auction';
      ELSE
        v_kind := 'transfer';
        v_headline := format('DONE DEAL — %s', v_name);
        v_body := format('%s → %s · %s', v_seller, v_buyer, v_fee_label);
      END IF;

      v_stories := v_stories || jsonb_build_array(
        jsonb_build_object(
          'id', 'transfer:' || v_row.id::text,
          'kind', v_kind,
          'kicker', 'TRANSFER NEWS',
          'headline', v_headline,
          'body', v_body,
          'href', 'transfer_center.html',
          'fee', coalesce(v_row.fee, 0),
          'transfer_time', v_row.transfer_time
        )
      );
      v_count := v_count + 1;
    END LOOP;
  END IF;

  -- 3) Discord rumours (rest of UK day), newest first — leave room if empty day
  IF v_count < 5 THEN
    IF v_count < 2 THEN
      PERFORM public.gpsl_rumour_ensure_idle(v_season_id, 2);
    ELSIF v_count < 4 THEN
      PERFORM public.gpsl_rumour_ensure_idle(v_season_id, 1);
    END IF;

    FOR v_rumour IN
      SELECT r.id, r.kind, r.headline, r.created_at, r.source
      FROM public.gpsl_transfer_rumours r
      WHERE r.season_id = v_season_id
        AND r.expires_at > now()
      ORDER BY
        CASE WHEN r.source = 'discord' THEN 0 ELSE 1 END,
        r.created_at DESC
      LIMIT (5 - v_count)
    LOOP
      v_stories := v_stories || jsonb_build_array(
        jsonb_build_object(
          'id', 'rumour:' || v_rumour.id::text,
          'kind', CASE WHEN v_rumour.kind = 'idle' THEN 'idle' ELSE 'rumour' END,
          'kicker', 'TRANSFER RUMOUR',
          'headline', v_rumour.headline,
          'body', '',
          'href', 'transfer_center.html',
          'created_at', v_rumour.created_at
        )
      );
      v_count := v_count + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'visible', jsonb_array_length(v_stories) > 0,
    'gpsl_month', v_month,
    'gpsl_month_label', v_month_label,
    'uk_date', v_uk_today,
    'forced', v_force IS NOT NULL,
    'story_count', jsonb_array_length(v_stories),
    'stories', v_stories
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_news_feed(text) TO authenticated;

-- Admin overview
CREATE OR REPLACE FUNCTION public.admin_gpsl_transfer_gossip_overview(p_limit int DEFAULT 40)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(1, least(coalesce(p_limit, 40), 100));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN jsonb_build_object(
    'format', 'Club are interested in Player',
    'example', 'Jubilo are interested in Alexander Isak',
    'active', coalesce((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
      FROM (
        SELECT id, source, kind, club_short_name, club_name, player_name,
               headline, expires_at, created_at, discord_message_id
        FROM public.gpsl_transfer_rumours
        WHERE expires_at > now()
        ORDER BY created_at DESC
        LIMIT v_limit
      ) r
    ), '[]'::jsonb),
    'recent', coalesce((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
      FROM (
        SELECT id, source, kind, club_short_name, player_name,
               headline, expires_at, created_at
        FROM public.gpsl_transfer_rumours
        ORDER BY created_at DESC
        LIMIT v_limit
      ) r
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpsl_transfer_gossip_overview(int) TO authenticated;

NOTIFY pgrst, 'reload schema';
