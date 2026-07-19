-- =============================================================================
-- Transfer gossip: also accept "Player is interested in Club"
-- with its own rotating RUMOUR lines (separate from club→player).
--
-- Formats:
--   A) Club are interested in Player
--   B) Player is interested in Club
--
-- Safe re-run. Redeploy discord-transfer-gossip-ingest after.
-- =============================================================================

ALTER TABLE public.gpsl_transfer_rumours
  ADD COLUMN IF NOT EXISTS angle text;

ALTER TABLE public.gpsl_transfer_rumours
  DROP CONSTRAINT IF EXISTS gpsl_transfer_rumours_angle_check;

ALTER TABLE public.gpsl_transfer_rumours
  ADD CONSTRAINT gpsl_transfer_rumours_angle_check
  CHECK (
    angle IS NULL
    OR angle IN ('club_to_player', 'player_to_club')
  );

UPDATE public.gpsl_transfer_rumours
SET angle = 'club_to_player'
WHERE source = 'discord'
  AND angle IS NULL;

-- Club → player (existing 5 lines, round-robin)
CREATE OR REPLACE FUNCTION public.gpsl_rumour_discord_headline(
  p_club_name text,
  p_player_name text
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club_name), ''), 'A GPSL club');
  v_player text := coalesce(nullif(btrim(p_player_name), ''), 'a target');
  v_n int;
  v_pick int;
BEGIN
  SELECT count(*)::int INTO v_n
  FROM public.gpsl_transfer_rumours
  WHERE source = 'discord'
    AND coalesce(angle, 'club_to_player') = 'club_to_player';

  v_pick := (coalesce(v_n, 0) % 5) + 1;

  RETURN CASE v_pick
    WHEN 1 THEN format('RUMOUR: %s are tracking %s', v_club, v_player)
    WHEN 2 THEN format('RUMOUR: %s are considering an approach for %s', v_club, v_player)
    WHEN 3 THEN format(
      'RUMOUR: %s have been scouting %s, offer imminent according to sources',
      v_club, v_player
    )
    WHEN 4 THEN format('RUMOUR: %s in private discussions with %s', v_player, v_club)
    ELSE format(
      'RUMOUR: %s sporting director at odds with manager on transfer targets as %s causes divide',
      v_club, v_player
    )
  END;
END;
$function$;

-- Player → club (new 5 lines, round-robin)
CREATE OR REPLACE FUNCTION public.gpsl_rumour_discord_headline_player(
  p_club_name text,
  p_player_name text
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club_name), ''), 'A GPSL club');
  v_player text := coalesce(nullif(btrim(p_player_name), ''), 'a target');
  v_n int;
  v_pick int;
BEGIN
  SELECT count(*)::int INTO v_n
  FROM public.gpsl_transfer_rumours
  WHERE source = 'discord'
    AND angle = 'player_to_club';

  v_pick := (coalesce(v_n, 0) % 5) + 1;

  RETURN CASE v_pick
    WHEN 1 THEN format(
      'RUMOUR: %s has instructed his agent to make a deal happen with %s',
      v_player, v_club
    )
    WHEN 2 THEN format(
      'RUMOUR: %s has made direct contact with %s to instigate a transfer',
      v_player, v_club
    )
    WHEN 3 THEN format(
      'RUMOUR: %s has threatened to go on strike unless a deal is made with %s',
      v_player, v_club
    )
    WHEN 4 THEN format(
      'RUMOUR: %s has admitted his favourite club growing up was %s, fueling rumours of a potential offer',
      v_player, v_club
    )
    ELSE format(
      'RUMOUR: %s has voiced concerns over his latest contract offer amid interest from %s',
      v_player, v_club
    )
  END;
END;
$function$;

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

  -- B) Player is interested in Club
  v_m := regexp_match(v_raw, '^(.+?)\s+is\s+interested\s+in\s+(.+)$', 'i');
  IF v_m IS NOT NULL THEN
    v_angle := 'player_to_club';
    v_player_text := btrim(v_m[1]);
    v_club_text := btrim(v_m[2]);
  ELSE
    -- A) Club are interested in Player
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
      public.competition_active_gpsl_month(v_season_id, coalesce(p_posted_at, now())),
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
    public.gpsl_rumour_uk_day_end(coalesce(p_posted_at, now()))
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'rumour',
    'angle', v_angle,
    'rumour_id', v_id,
    'headline', v_headline,
    'club', v_club ->> 'short_name',
    'player', v_player ->> 'player_name'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_rumour_discord_headline_player(text, text)
  TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_transfer_gossip_ingest_post(text, text, text, timestamptz)
  TO service_role, authenticated;
