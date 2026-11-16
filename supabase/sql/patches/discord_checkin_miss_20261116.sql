-- Post to #gpsl-scheduled when a check-in window closes with a miss.
-- Only the first time that miss is recorded (rearranged kick-offs can post again).

CREATE OR REPLACE FUNCTION public.gpsl_discord_post_club_fixture_checkin_miss(
  p_fixture_id bigint,
  p_missed text
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
  v_missed text := lower(btrim(coalesce(p_missed, '')));
  v_kind text;
  v_comp text;
  v_detail text;
  v_ko_label text;
  v_headline text;
  v_body text;
  v_who text;
  v_dedupe text;
  v_qid bigint;
  v_home_tag text;
  v_away_tag text;
  v_home_discord text;
  v_away_discord text;
BEGIN
  IF p_fixture_id IS NULL OR v_missed NOT IN ('home', 'away', 'both') THEN
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

  SELECT s.agreed_kickoff_at
  INTO v_ko
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id
    AND s.agreed_kickoff_at IS NOT NULL
  ORDER BY s.updated_at DESC NULLS LAST
  LIMIT 1;

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

  IF v_missed = 'both' THEN
    v_who := v_home || ' and ' || v_away;
  ELSIF v_missed = 'home' THEN
    v_who := v_home;
  ELSE
    v_who := v_away;
  END IF;

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

  v_headline := format('MISSED CHECK-IN · %s — %s', v_kind, v_who);
  v_body := format(
    E'%s vs %s%s\n%sCheck-in: %s %s · %s %s\n%s',
    v_home,
    v_away,
    CASE WHEN v_detail IS NOT NULL THEN E'\n' || v_detail ELSE '' END,
    CASE WHEN v_ko_label IS NOT NULL THEN 'Kick-off: ' || v_ko_label || E'\n' ELSE '' END,
    v_home,
    CASE WHEN v_home_in OR v_missed = 'away' THEN '✅' ELSE '❌' END,
    v_away,
    CASE WHEN v_away_in OR v_missed = 'home' THEN '✅' ELSE '❌' END,
    CASE
      WHEN v_missed = 'both' THEN 'Both clubs missed check-in.'
      ELSE v_who || ' missed check-in.'
    END
  );
  v_dedupe := format(
    'scheduled:checkin_miss:%s:%s:%s',
    p_fixture_id::text,
    coalesce(to_char(v_ko AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'), 'noko'),
    v_missed
  );

  v_qid := public.gpsl_discord_feed_enqueue_scheduled(
    'scheduled',
    v_headline,
    v_body,
    15158332,
    v_dedupe,
    jsonb_build_object(
      'kind', 'checkin_miss',
      'channel', 'scheduled',
      'ping', true,
      'fixture_id', p_fixture_id,
      'missed', v_missed,
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
  RAISE WARNING 'gpsl_discord_post_club_fixture_checkin_miss(%, %) failed: %', p_fixture_id, p_missed, SQLERRM;
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_post_club_fixture_checkin_miss(bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_post_club_fixture_checkin_miss(bigint, text)
  TO service_role;

DO $wire$
DECLARE
  v_def text;
  v_both_old text;
  v_both_new text;
  v_one_old text;
  v_one_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure),
    E'\r\n',
    E'\n'
  );
  v_both_old := replace($old$
    IF v_new_event THEN
      PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
    END IF;$old$, E'\r\n', E'\n');
  v_both_new := replace($new$
    IF v_new_event THEN
      PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
      PERFORM public.gpsl_discord_post_club_fixture_checkin_miss(p_fixture_id, 'both');
    END IF;$new$, E'\r\n', E'\n');
  v_one_old := replace($old$
    PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
  END IF;$old$, E'\r\n', E'\n');
  v_one_new := replace($new$
    PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
    PERFORM public.gpsl_discord_post_club_fixture_checkin_miss(
      p_fixture_id,
      CASE WHEN v_home_in THEN 'away' ELSE 'home' END
    );
  END IF;$new$, E'\r\n', E'\n');

  IF position(v_both_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'both-miss check-in block not found';
  END IF;
  v_def := replace(v_def, v_both_old, v_both_new);
  IF position(v_one_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'one-sided check-in block not found';
  END IF;
  v_def := replace(v_def, v_one_old, v_one_new);
  EXECUTE v_def;
END;
$wire$;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.gpsl_discord_post_club_fixture_checkin_miss(bigint,text)') IS NOT NULL AS miss_fn,
  (
    length(pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure))
    - length(replace(
        pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure),
        'gpsl_discord_post_club_fixture_checkin_miss',
        ''
      ))
  ) / length('gpsl_discord_post_club_fixture_checkin_miss') AS wired_calls;
