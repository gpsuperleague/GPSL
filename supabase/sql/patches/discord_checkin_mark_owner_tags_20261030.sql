-- Discord #gpsl-scheduled check-in marks: ping both owners
-- =============================================================================
-- Keeps existing CHECKED IN / BOTH READY copy unchanged.
-- Adds owner_tags + discord_user_ids for home and away so the sky-feed edge
-- can @mention both owners above the embed (same pattern as check-in open).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_post_club_fixture_checkin(
  p_fixture_id bigint,
  p_club text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_ko timestamptz;
  v_home text;
  v_away text;
  v_home_in boolean := false;
  v_away_in boolean := false;
  v_kind text;
  v_comp text;
  v_detail text;
  v_ko_label text;
  v_headline text;
  v_body text;
  v_dedupe text;
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_who text;
  v_color int;
  v_qid bigint;
  v_home_tag text;
  v_away_tag text;
  v_home_discord text;
  v_away_discord text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF to_regprocedure(
    'public.gpsl_discord_feed_enqueue_scheduled(text,text,text,integer,text,jsonb)'
  ) IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF coalesce(v_f.status, '') <> 'scheduled' THEN
    RETURN NULL;
  END IF;

  SELECT s.agreed_kickoff_at
  INTO v_ko
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id
    AND s.status = 'agreed'
    AND s.agreed_kickoff_at IS NOT NULL;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_f.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_f.away_club_short_name
  ) INTO v_away_in;

  IF NOT v_home_in AND NOT v_away_in THEN
    RETURN NULL;
  END IF;

  SELECT c."Club" INTO v_home FROM public."Clubs" c WHERE c."ShortName" = v_f.home_club_short_name;
  SELECT c."Club" INTO v_away FROM public."Clubs" c WHERE c."ShortName" = v_f.away_club_short_name;
  v_home := coalesce(nullif(btrim(v_home), ''), v_f.home_club_short_name, 'Home');
  v_away := coalesce(nullif(btrim(v_away), ''), v_f.away_club_short_name, 'Away');

  IF v_f.competition_type = 'cup' OR nullif(btrim(coalesce(v_f.cup_code, '')), '') IS NOT NULL THEN
    v_kind := 'CUP';
    BEGIN
      v_comp := public.competition_cup_fixture_label(v_f);
    EXCEPTION WHEN OTHERS THEN
      v_comp := NULL;
    END;
    IF nullif(btrim(coalesce(v_comp, '')), '') IS NULL THEN
      v_comp := coalesce(nullif(btrim(v_f.cup_code), ''), 'Cup');
    END IF;
  ELSE
    v_kind := 'LEAGUE';
    v_comp := CASE lower(coalesce(v_f.division, ''))
      WHEN 'superleague' THEN 'SuperLeague'
      WHEN 'championship_a' THEN 'Championship A'
      WHEN 'championship_b' THEN 'Championship B'
      ELSE coalesce(nullif(btrim(v_f.division), ''), 'League')
    END;
    IF v_f.matchday IS NOT NULL THEN
      v_detail := 'Matchday ' || v_f.matchday::text;
    END IF;
  END IF;

  IF v_ko IS NOT NULL THEN
    BEGIN
      v_ko_label := public.match_schedule_format_kickoff_uk(v_ko);
    EXCEPTION WHEN OTHERS THEN
      v_ko_label := to_char(v_ko AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';
    END;
  END IF;

  IF v_club <> '' THEN
    IF v_club = upper(btrim(v_f.home_club_short_name)) THEN
      v_who := v_home;
    ELSIF v_club = upper(btrim(v_f.away_club_short_name)) THEN
      v_who := v_away;
    ELSE
      v_who := v_club;
    END IF;
  ELSIF v_home_in AND NOT v_away_in THEN
    v_who := v_home;
  ELSIF v_away_in AND NOT v_home_in THEN
    v_who := v_away;
  ELSE
    v_who := NULL;
  END IF;

  -- Owner tags for both clubs (message body unchanged; edge pings above embed)
  BEGIN
    IF to_regprocedure('public.gpsl_discord_notifications_owner_tag(text)') IS NOT NULL THEN
      v_home_tag := public.gpsl_discord_notifications_owner_tag(v_f.home_club_short_name);
      v_away_tag := public.gpsl_discord_notifications_owner_tag(v_f.away_club_short_name);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_home_tag := NULL;
    v_away_tag := NULL;
  END;

  SELECT nullif(btrim(r.discord_user_id), '') INTO v_home_discord
  FROM public."Clubs" c
  JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
  WHERE c."ShortName" = v_f.home_club_short_name
  LIMIT 1;

  SELECT nullif(btrim(r.discord_user_id), '') INTO v_away_discord
  FROM public."Clubs" c
  JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
  WHERE c."ShortName" = v_f.away_club_short_name
  LIMIT 1;

  IF v_home_in AND v_away_in THEN
    v_headline := format('✅ BOTH READY · %s — %s vs %s', v_kind, v_home, v_away);
    v_body := format(
      E'%s%s\nCheck-in: %s ✅ · %s ✅\n%sBoth clubs checked in — Match Day unlocked for the play window.',
      v_comp,
      CASE WHEN v_detail IS NOT NULL THEN E'\n' || v_detail ELSE '' END,
      v_home,
      v_away,
      CASE WHEN v_ko_label IS NOT NULL THEN 'Kick-off: ' || v_ko_label || E'\n' ELSE '' END
    );
    v_color := 3066993; -- green
    v_dedupe := 'scheduled:checkin_both:' || p_fixture_id::text;
  ELSE
    v_headline := format(
      '✅ CHECKED IN · %s — %s',
      v_kind,
      coalesce(v_who, 'Owner')
    );
    v_body := format(
      E'%s vs %s%s\nCheck-in: %s %s · %s %s\n%sWaiting for opponent (1 of 2).',
      v_home,
      v_away,
      CASE WHEN v_detail IS NOT NULL THEN E'\n' || v_detail ELSE '' END,
      v_home,
      CASE WHEN v_home_in THEN '✅' ELSE '⏳' END,
      v_away,
      CASE WHEN v_away_in THEN '✅' ELSE '⏳' END,
      CASE WHEN v_ko_label IS NOT NULL THEN 'Kick-off: ' || v_ko_label || E'\n' ELSE '' END
    );
    v_color := 15105570; -- amber
    v_dedupe := format(
      'scheduled:checkin_side:%s:%s',
      p_fixture_id::text,
      coalesce(nullif(v_club, ''), CASE WHEN v_home_in THEN 'home' ELSE 'away' END)
    );
  END IF;

  v_qid := public.gpsl_discord_feed_enqueue_scheduled(
    'scheduled',
    v_headline,
    v_body,
    v_color,
    v_dedupe,
    jsonb_build_object(
      'kind', CASE WHEN v_home_in AND v_away_in THEN 'checkin_both' ELSE 'checkin_side' END,
      'ping', true,
      'fixture_id', p_fixture_id,
      'club', nullif(v_club, ''),
      'home_checked_in', v_home_in,
      'away_checked_in', v_away_in,
      'kickoff_at', v_ko,
      'owner_tags', coalesce((
        SELECT jsonb_agg(to_jsonb(t) ORDER BY ord)
        FROM (
          SELECT 1 AS ord, nullif(btrim(v_home_tag), '') AS t
          UNION ALL
          SELECT 2, nullif(btrim(v_away_tag), '')
        ) x
        WHERE t IS NOT NULL
      ), '[]'::jsonb),
      'discord_user_ids', coalesce((
        SELECT jsonb_agg(to_jsonb(t) ORDER BY ord)
        FROM (
          SELECT 1 AS ord, nullif(btrim(v_home_discord), '') AS t
          UNION ALL
          SELECT 2, nullif(btrim(v_away_discord), '')
        ) x
        WHERE t IS NOT NULL
      ), '[]'::jsonb)
    )
  );

  IF v_qid IS NOT NULL
     AND to_regprocedure('public.gpsl_discord_feed_request_flush()') IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_discord_feed_request_flush();
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN v_qid;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'gpsl_discord_post_club_fixture_checkin(%) failed: %', p_fixture_id, SQLERRM;
  RETURN NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_post_club_fixture_checkin(bigint, text)
  TO authenticated, service_role;

-- Confirm metadata shape
SELECT
  position('owner_tags' IN pg_get_functiondef(
    'public.gpsl_discord_post_club_fixture_checkin(bigint,text)'::regprocedure
  )) > 0 AS has_owner_tags,
  position('ping' IN pg_get_functiondef(
    'public.gpsl_discord_post_club_fixture_checkin(bigint,text)'::regprocedure
  )) > 0 AS has_ping;

NOTIFY pgrst, 'reload schema';
