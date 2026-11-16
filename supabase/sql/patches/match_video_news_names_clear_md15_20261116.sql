-- News posts for match-video reports use full club names.
-- Backfill the admin "checked" mark on Monaco's matchday 15 away video.

CREATE OR REPLACE FUNCTION public.match_video_report_post_news(p_report_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_r record;
  v_home text;
  v_away text;
  v_accused text;
  v_home_name text;
  v_away_name text;
  v_lines text;
  v_qid bigint;
BEGIN
  SELECT
    r.id,
    r.accused_club_short_name,
    r.side,
    r.breaches,
    r.fixture_id
  INTO v_r
  FROM public.match_video_breach_reports r
  WHERE r.id = p_report_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = v_r.fixture_id;

  v_accused := public.gpsl_discord_feed_club_name(v_r.accused_club_short_name);
  v_home_name := public.gpsl_discord_feed_club_name(v_home);
  v_away_name := public.gpsl_discord_feed_club_name(v_away);

  SELECT string_agg(
    format(
      '%s — %s',
      coalesce(b->>'label', b->>'code'),
      coalesce(b->>'note', '')
    ),
    E'\n'
    ORDER BY ordinality
  )
  INTO v_lines
  FROM jsonb_array_elements(coalesce(v_r.breaches, '[]'::jsonb)) WITH ORDINALITY AS x(b, ordinality);

  v_qid := public.gpsl_discord_feed_enqueue(
    'match_video_report',
    format('MATCH VIDEO REPORT — %s', v_accused),
    concat_ws(
      E'\n',
      format(
        '%s %s video. %s vs %s.',
        v_accused,
        v_r.side,
        coalesce(v_home_name, '?'),
        coalesce(v_away_name, '?')
      ),
      coalesce(v_lines, ''),
      'Staff will review it. Nothing is charged until it is approved.'
    ),
    15105570,
    format('match_video_report_news:%s', v_r.id),
    jsonb_build_object(
      'channel', 'news',
      'kind', 'match_video_report',
      'report_id', v_r.id,
      'fixture_id', v_r.fixture_id,
      'accused', v_r.accused_club_short_name
    )
  );

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_qid;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_report_post_news(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_report_post_news(bigint) TO service_role;

INSERT INTO public.match_video_admin_clear (fixture_id, side, cleared_by, cleared_at)
SELECT f.id, 'away', NULL, now()
FROM public.competition_fixtures f
WHERE f.id = 9105
  AND f.matchday = 15
  AND upper(f.home_club_short_name) = 'DOR'
  AND upper(f.away_club_short_name) = 'MON'
ON CONFLICT (fixture_id, side) DO NOTHING;

NOTIFY pgrst, 'reload schema';

SELECT
  c.fixture_id,
  c.side,
  f.matchday,
  f.home_club_short_name,
  f.away_club_short_name,
  position('gpsl_discord_feed_club_name' IN pg_get_functiondef('public.match_video_report_post_news(bigint)'::regprocedure)) > 0 AS uses_full_names
FROM public.match_video_admin_clear c
JOIN public.competition_fixtures f ON f.id = c.fixture_id
WHERE c.fixture_id = 9105
  AND c.side = 'away';
