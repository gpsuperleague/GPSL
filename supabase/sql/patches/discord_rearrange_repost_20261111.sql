-- =============================================================================
-- Rearranged kick-offs post again in #gpsl-scheduled (2026-11-11)
--
-- A new agreed time already posts SCHEDULED (that key includes the kick-off).
-- Check-in open and checked-in were once per fixture, so a replay stayed silent.
-- Those keys now include the kick-off minute. An old post for the same minute
-- still counts, so a match already announced is not posted twice.
-- When an agreed kick-off moves, both clubs are pinged that the new time is on.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_post_club_fixture_rearranged(p_fixture_id bigint)
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
  v_kind text;
  v_ko_label text;
  v_headline text;
  v_body text;
  v_dedupe text;
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

  IF coalesce(v_f.status, '') IN ('played', 'void') OR coalesce(v_f.is_forfeit, false) THEN
    RETURN NULL;
  END IF;

  SELECT s.agreed_kickoff_at
  INTO v_ko
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id
    AND s.status = 'agreed'
    AND s.agreed_kickoff_at IS NOT NULL;

  IF v_ko IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c."Club" INTO v_home FROM public."Clubs" c WHERE c."ShortName" = v_f.home_club_short_name;
  SELECT c."Club" INTO v_away FROM public."Clubs" c WHERE c."ShortName" = v_f.away_club_short_name;
  v_home := coalesce(nullif(btrim(v_home), ''), v_f.home_club_short_name, 'Home');
  v_away := coalesce(nullif(btrim(v_away), ''), v_f.away_club_short_name, 'Away');

  IF v_f.competition_type = 'cup' OR nullif(btrim(coalesce(v_f.cup_code, '')), '') IS NOT NULL THEN
    v_kind := 'CUP';
  ELSE
    v_kind := 'LEAGUE';
  END IF;

  BEGIN
    v_ko_label := public.match_schedule_format_kickoff_uk(v_ko);
  EXCEPTION WHEN OTHERS THEN
    v_ko_label := to_char(v_ko AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';
  END;

  BEGIN
    v_home_tag := public.gpsl_discord_notifications_owner_tag(v_f.home_club_short_name);
    v_away_tag := public.gpsl_discord_notifications_owner_tag(v_f.away_club_short_name);
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

  v_headline := format('📣 REARRANGED · %s — %s vs %s', v_kind, v_home, v_away);
  v_body := format(
    E'%s vs %s is on.\nKick-off: %s\nBoth clubs — this is the new time.',
    v_home,
    v_away,
    v_ko_label
  );
  v_dedupe := 'scheduled:on:' || p_fixture_id::text || ':'
    || to_char(v_ko AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI');

  v_qid := public.gpsl_discord_feed_enqueue_scheduled(
    'scheduled',
    v_headline,
    v_body,
    3447003,
    v_dedupe,
    jsonb_build_object(
      'kind', 'rearranged',
      'ping', true,
      'try_dm', true,
      'fixture_id', p_fixture_id,
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
  RAISE WARNING 'gpsl_discord_post_club_fixture_rearranged(%) failed: %', p_fixture_id, SQLERRM;
  RETURN NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_post_club_fixture_rearranged(bigint)
  TO authenticated, service_role;

-- Ping both clubs only when an already agreed kick-off moves.
DO $trg$
DECLARE
  v_def text;
  v_needle text := 'PERFORM public.gpsl_discord_post_club_fixture_scheduled(NEW.fixture_id);';
  v_insert text := $ins$IF TG_OP = 'UPDATE'
     AND OLD.status IS NOT DISTINCT FROM 'agreed'
     AND OLD.agreed_kickoff_at IS NOT NULL
     AND OLD.agreed_kickoff_at IS DISTINCT FROM NEW.agreed_kickoff_at
  THEN
    PERFORM public.gpsl_discord_post_club_fixture_rearranged(NEW.fixture_id);
  END IF;

  PERFORM public.gpsl_discord_post_club_fixture_scheduled(NEW.fixture_id);$ins$;
BEGIN
  v_insert := replace(replace(v_insert, E'\r\n', E'\n'), E'\r', E'\n');
  v_def := replace(replace(
    pg_get_functiondef('public.gpsl_discord_on_club_schedule_agreed()'::regprocedure),
    E'\r\n', E'\n'), E'\r', E'\n');

  IF position('gpsl_discord_post_club_fixture_rearranged' IN v_def) > 0 THEN
    RAISE NOTICE 'schedule trigger already calls rearranged';
    RETURN;
  END IF;

  IF position(v_needle IN v_def) = 0 THEN
    RAISE EXCEPTION 'schedule trigger needle missing';
  END IF;

  v_def := replace(v_def, v_needle, v_insert);
  EXECUTE v_def;
END;
$trg$;

-- Check-in open: one Discord post and one inbox note per kick-off minute.
DO $open$
DECLARE
  v_def text;
  v_stamp text := 'to_char(v_kickoff AT TIME ZONE ''UTC'', ''YYYYMMDDHH24MI'')';
BEGIN
  v_def := replace(replace(
    pg_get_functiondef('public.match_schedule_notify_checkin_open(bigint)'::regprocedure),
    E'\r\n', E'\n'), E'\r', E'\n');

  IF position(v_stamp IN v_def) > 0 THEN
    RAISE NOTICE 'check-in open already stamped';
    RETURN;
  END IF;

  IF position('''scheduled:checkin:'' || p_fixture_id::text' IN v_def) = 0
     OR position('''match_checkin_open:'' || p_fixture_id::text || '':home''' IN v_def) = 0
     OR position('''match_checkin_open:'' || p_fixture_id::text || '':away''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'check-in open dedupe needle missing';
  END IF;

  v_def := replace(
    v_def,
    '''scheduled:checkin:'' || p_fixture_id::text',
    '''scheduled:checkin:'' || p_fixture_id::text || '':'' || ' || v_stamp
  );
  v_def := replace(
    v_def,
    '''match_checkin_open:'' || p_fixture_id::text || '':home''',
    '''match_checkin_open:'' || p_fixture_id::text || '':'' || ' || v_stamp || ' || '':home'''
  );
  v_def := replace(
    v_def,
    '''match_checkin_open:'' || p_fixture_id::text || '':away''',
    '''match_checkin_open:'' || p_fixture_id::text || '':'' || ' || v_stamp || ' || '':away'''
  );
  EXECUTE v_def;
END;
$open$;

-- Due scanner: a previous kick-off's post does not block the new minute.
-- A post with no kick-off stored, or the same minute, still counts as sent.
DO $due$
DECLARE
  v_def text;
  v_needle text := 'q.dedupe_key = ''scheduled:checkin:'' || f.id::text';
  v_insert text := $ins$q.dedupe_key = 'scheduled:checkin:' || f.id::text || ':' || to_char(sch.agreed_kickoff_at AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI')
               OR (
                 q.dedupe_key = 'scheduled:checkin:' || f.id::text
                 AND (
                   nullif(q.metadata->>'kickoff_at', '') IS NULL
                   OR (q.metadata->>'kickoff_at')::timestamptz = sch.agreed_kickoff_at
                 )
               )$ins$;
BEGIN
  v_insert := replace(replace(v_insert, E'\r\n', E'\n'), E'\r', E'\n');
  v_def := replace(replace(
    pg_get_functiondef('public.match_schedule_process_due_checkin_notices()'::regprocedure),
    E'\r\n', E'\n'), E'\r', E'\n');

  IF position('to_char(sch.agreed_kickoff_at AT TIME ZONE ''UTC'', ''YYYYMMDDHH24MI'')' IN v_def) > 0 THEN
    RAISE NOTICE 'due scanner already stamped';
    RETURN;
  END IF;

  IF position(v_needle IN v_def) = 0 THEN
    RAISE EXCEPTION 'due scanner needle missing';
  END IF;

  v_def := replace(v_def, v_needle, v_insert);
  EXECUTE v_def;
END;
$due$;

-- Checked-in and both-ready: one post per club per kick-off minute.
DO $mark$
DECLARE
  v_def text;
  v_both_old text := 'v_dedupe := ''scheduled:checkin_both:'' || p_fixture_id::text;';
  v_both_new text := 'v_dedupe := ''scheduled:checkin_both:'' || p_fixture_id::text || coalesce('':'' || to_char(v_ko AT TIME ZONE ''UTC'', ''YYYYMMDDHH24MI''), '''');';
  v_side_old text := $old$v_dedupe := format(
      'scheduled:checkin_side:%s:%s',
      p_fixture_id::text,
      coalesce(nullif(v_club, ''), CASE WHEN v_home_in THEN 'home' ELSE 'away' END)
    );$old$;
  v_side_new text := $new$v_dedupe := format(
      'scheduled:checkin_side:%s:%s%s',
      p_fixture_id::text,
      coalesce(nullif(v_club, ''), CASE WHEN v_home_in THEN 'home' ELSE 'away' END),
      coalesce(':' || to_char(v_ko AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'), '')
    );$new$;
BEGIN
  v_side_old := replace(replace(v_side_old, E'\r\n', E'\n'), E'\r', E'\n');
  v_side_new := replace(replace(v_side_new, E'\r\n', E'\n'), E'\r', E'\n');
  v_def := replace(replace(
    pg_get_functiondef('public.gpsl_discord_post_club_fixture_checkin(bigint,text)'::regprocedure),
    E'\r\n', E'\n'), E'\r', E'\n');

  IF position('to_char(v_ko AT TIME ZONE ''UTC'', ''YYYYMMDDHH24MI'')' IN v_def) > 0 THEN
    RAISE NOTICE 'check-in mark already stamped';
    RETURN;
  END IF;

  IF position(v_both_old IN v_def) = 0 OR position(v_side_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'check-in mark dedupe needle missing';
  END IF;

  v_def := replace(v_def, v_both_old, v_both_new);
  v_def := replace(v_def, v_side_old, v_side_new);
  EXECUTE v_def;
END;
$mark$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'rearranged', to_regprocedure('public.gpsl_discord_post_club_fixture_rearranged(bigint)') IS NOT NULL,
  'trigger', position('gpsl_discord_post_club_fixture_rearranged' IN pg_get_functiondef('public.gpsl_discord_on_club_schedule_agreed()'::regprocedure)) > 0,
  'open', position('to_char(v_kickoff AT TIME ZONE ''UTC'', ''YYYYMMDDHH24MI'')' IN pg_get_functiondef('public.match_schedule_notify_checkin_open(bigint)'::regprocedure)) > 0,
  'due', position('to_char(sch.agreed_kickoff_at AT TIME ZONE ''UTC'', ''YYYYMMDDHH24MI'')' IN pg_get_functiondef('public.match_schedule_process_due_checkin_notices()'::regprocedure)) > 0,
  'mark', position('to_char(v_ko AT TIME ZONE ''UTC'', ''YYYYMMDDHH24MI'')' IN pg_get_functiondef('public.gpsl_discord_post_club_fixture_checkin(bigint,text)'::regprocedure)) > 0
) AS rearranged_feed;
