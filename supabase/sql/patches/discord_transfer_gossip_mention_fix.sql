-- =============================================================================
-- Transfer gossip: ignore Discord @mentions / extra lines under the phrase
-- e.g. "Jubilo are interested in Alexander Isak" + "@pjft" on next line
-- Safe re-run. Redeploy discord-transfer-gossip-ingest after this.
-- =============================================================================

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
  v_raw := split_part(v_raw, E'\n', 1);
  v_raw := regexp_replace(v_raw, '<@!?[0-9]+>', '', 'g');
  v_raw := regexp_replace(v_raw, '<@&[0-9]+>', '', 'g');
  v_raw := regexp_replace(v_raw, '@[A-Za-z0-9_./-]+', '', 'g');
  v_raw := regexp_replace(v_raw, '\s+', ' ', 'g');
  v_raw := btrim(v_raw);

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
