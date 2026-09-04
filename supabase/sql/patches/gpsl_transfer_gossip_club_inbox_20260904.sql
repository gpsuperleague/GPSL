-- =============================================================================
-- Discord transfer gossip → notify player's club of rival interest
--
-- When ingest is club→player ("Jubilo are interested in Isak"), the holding
-- club gets an owner inbox message. Player→club angle does not notify.
--
-- Run after gpsl_transfer_gossip_jump_cycle_20260904.sql (or any later ingest).
-- Safe re-run.
-- =============================================================================

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
    SELECT 'transfer_gossip_interest'
  ) s;

  IF v_list IS NULL OR btrim(v_list) = '' THEN
    RAISE EXCEPTION 'No inbox message types to install';
  END IF;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  BEGIN
    ALTER TABLE public.competition_inbox
      VALIDATE CONSTRAINT competition_inbox_message_type_check;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'competition_inbox_message_type_check left NOT VALID: %', SQLERRM;
  END;
END;
$inbox_types$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_transfer_gossip_interest(
  p_player_id text,
  p_player_name text,
  p_interested_club_short text,
  p_interested_club_name text,
  p_rumour_id bigint DEFAULT NULL,
  p_discord_message_id text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text := nullif(btrim(coalesce(p_player_id, '')), '');
  v_player_name text := coalesce(nullif(btrim(p_player_name), ''), 'Your player');
  v_interest_short text := nullif(btrim(coalesce(p_interested_club_short, '')), '');
  v_interest_name text := coalesce(
    nullif(btrim(p_interested_club_name), ''),
    v_interest_short,
    'Another club'
  );
  v_holding text;
  v_team text;
  v_id bigint;
  v_dedupe text;
BEGIN
  IF v_player_id IS NULL OR v_interest_short IS NULL THEN
    RETURN NULL;
  END IF;

  IF to_regprocedure('public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint,bigint)') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT p."Contracted_Team" INTO v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_player_id
  LIMIT 1;

  BEGIN
    v_holding := public.player_contracted_club_key(v_team);
  EXCEPTION WHEN OTHERS THEN
    v_holding := nullif(btrim(coalesce(v_team, '')), '');
  END;

  IF v_holding IS NULL OR upper(v_holding) IN ('FOREIGN', 'GPDB') THEN
    RETURN NULL;
  END IF;

  -- Don't ping a club about their own "interest"
  IF lower(v_holding) = lower(v_interest_short) THEN
    RETURN NULL;
  END IF;

  v_dedupe := format(
    'transfer_gossip_interest:%s',
    coalesce(
      nullif(btrim(coalesce(p_discord_message_id, '')), ''),
      p_rumour_id::text,
      v_player_id || ':' || v_interest_short || ':' || to_char(now(), 'YYYYMMDDHH24')
    )
  );

  v_id := public.owner_inbox_send(
    'transfer_gossip_interest',
    format('Transfer interest — %s', v_player_name),
    format(
      '%s are being linked with %s. Another club is showing interest — keep an eye on the window.',
      v_interest_name,
      v_player_name
    ),
    v_holding,
    NULL, -- owner_id
    NULL, -- fixture
    NULL, -- submission
    NULL, -- transfer_history
    NULL, -- listing
    'transfer_center.html',
    v_dedupe,
    nullif(btrim(coalesce(p_gpsl_month, '')), ''),
    p_season_id,
    NULL  -- schedule_proposal
  );

  RETURN v_id;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'transfer gossip inbox notify failed: %', SQLERRM;
  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.owner_inbox_notify_transfer_gossip_interest(
  text, text, text, text, bigint, text, bigint, text
) IS
  'Inbox the holding club when Discord gossip says another club are interested in their player.';

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_transfer_gossip_interest(
  text, text, text, text, bigint, text, bigint, text
) TO service_role, authenticated;

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
  v_angle text;
  v_at timestamptz := coalesce(p_posted_at, now());
  v_expires timestamptz := v_at + interval '30 minutes';
  v_inbox_id bigint;
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

  v_m := regexp_match(v_raw, '^(.+?)\s+is\s+interested\s+in\s+(.+)$', 'i');
  IF v_m IS NOT NULL THEN
    v_angle := 'player_to_club';
    v_player_text := btrim(v_m[1]);
    v_club_text := btrim(v_m[2]);
  ELSE
    v_m := regexp_match(v_raw, '^(.+?)\s+are\s+interested\s+in\s+(.+)$', 'i');
    IF v_m IS NULL THEN
      RETURN jsonb_build_object(
        'ok', false,
        'status', 'ignored',
        'reason', 'Bad format — use: Club are interested in Player  OR  Player is interested in Club'
      );
    END IF;
    v_angle := 'club_to_player';
    v_club_text := btrim(v_m[1]);
    v_player_text := btrim(v_m[2]);
  END IF;

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
    v_month := lower(coalesce(
      public.competition_active_gpsl_month(v_season_id, v_at),
      ''
    ));
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

  IF v_angle = 'player_to_club' THEN
    v_headline := public.gpsl_rumour_discord_headline_player(
      v_club ->> 'club_name',
      v_player ->> 'player_name'
    );
  ELSE
    v_headline := public.gpsl_rumour_discord_headline(
      v_club ->> 'club_name',
      v_player ->> 'player_name'
    );
  END IF;

  UPDATE public.gpsl_transfer_rumours r
  SET expires_at = least(r.expires_at, now())
  WHERE r.season_id = v_season_id
    AND r.source = 'idle'
    AND r.expires_at > now();

  IF to_regprocedure('public.gpsl_transfer_ticker_reset_cycle(text)') IS NOT NULL THEN
    PERFORM public.gpsl_transfer_ticker_reset_cycle('discord_gossip');
  END IF;

  INSERT INTO public.gpsl_transfer_rumours (
    season_id, source, kind, angle, club_short_name, club_name,
    player_id, player_name, headline,
    discord_message_id, discord_user_id, expires_at
  )
  VALUES (
    v_season_id, 'discord', 'rumour', v_angle,
    v_club ->> 'short_name', v_club ->> 'club_name',
    v_player ->> 'player_id', v_player ->> 'player_name',
    v_headline,
    v_msg, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
    v_expires
  )
  RETURNING id INTO v_id;

  -- Holding club: another club are showing interest
  IF v_angle = 'club_to_player' THEN
    v_inbox_id := public.owner_inbox_notify_transfer_gossip_interest(
      v_player ->> 'player_id',
      v_player ->> 'player_name',
      v_club ->> 'short_name',
      v_club ->> 'club_name',
      v_id,
      v_msg,
      v_season_id,
      v_month
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'rumour',
    'angle', v_angle,
    'rumour_id', v_id,
    'headline', v_headline,
    'club', v_club ->> 'short_name',
    'player', v_player ->> 'player_name',
    'expires_at', v_expires,
    'cycle_reset', true,
    'inbox_id', v_inbox_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_gossip_ingest_post(text, text, text, timestamptz)
  TO service_role, authenticated;

NOTIFY pgrst, 'reload schema';
