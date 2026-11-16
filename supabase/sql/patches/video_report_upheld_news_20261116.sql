-- Approved video-report fines post to Discord news.
-- The filing post stays as it is. This is the follow-up once staff approve.
-- Dedupe key match_video_report_upheld:{report id} so a re-run does not post twice.
-- Does not name the reporter.

CREATE OR REPLACE FUNCTION public.match_video_report_post_upheld_news(p_report_id bigint)
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
  v_n int;
  v_qid bigint;
BEGIN
  SELECT
    r.id,
    r.accused_club_short_name,
    r.side,
    r.breaches,
    r.fixture_id,
    r.created_at,
    r.reviewed_at,
    r.status
  INTO v_r
  FROM public.match_video_breach_reports r
  WHERE r.id = p_report_id;

  IF NOT FOUND OR v_r.status NOT IN ('approved', 'upheld') THEN
    RETURN NULL;
  END IF;

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = v_r.fixture_id;

  v_accused := public.gpsl_discord_feed_club_name(v_r.accused_club_short_name);
  v_home_name := public.gpsl_discord_feed_club_name(v_home);
  v_away_name := public.gpsl_discord_feed_club_name(v_away);

  SELECT
    string_agg(
      format(
        '%s — %s%s',
        coalesce(t.label, a.description),
        public.transfer_format_money(a.amount),
        CASE
          WHEN nullif(btrim(coalesce(a.note, '')), '') IS NULL THEN ''
          WHEN a.note ~* '^Match video breach report #' THEN ''
          ELSE ' — ' || btrim(a.note)
        END
      ),
      E'\n'
      ORDER BY a.id
    ),
    count(*)::int
  INTO v_lines, v_n
  FROM public.competition_fine_applied a
  LEFT JOIN public.competition_fine_tariff t ON t.code = a.tariff_code
  WHERE a.fixture_id = v_r.fixture_id
    AND upper(a.club_short_name) = upper(v_r.accused_club_short_name)
    AND coalesce(a.waived, false) = false
    AND a.direction = 'fine'
    AND a.amount > 0
    AND a.applied_at >= v_r.created_at - interval '1 minute'
    AND a.applied_at <= coalesce(v_r.reviewed_at, now()) + interval '2 minutes'
    AND (
      a.tariff_code IN (
        SELECT b->>'code'
        FROM jsonb_array_elements(coalesce(v_r.breaches, '[]'::jsonb)) b
      )
      OR (
        coalesce(jsonb_array_length(v_r.breaches), 0) = 0
        AND a.tariff_code = (
          SELECT r2.breach_tariff_code
          FROM public.match_video_breach_reports r2
          WHERE r2.id = v_r.id
        )
      )
    );

  IF coalesce(v_n, 0) = 0 OR coalesce(btrim(v_lines), '') = '' THEN
    RETURN NULL;
  END IF;

  v_qid := public.gpsl_discord_feed_enqueue(
    'match_video_report',
    format('MATCH VIDEO REPORT UPHELD — %s', v_accused),
    concat_ws(
      E'\n',
      format(
        '%s %s video. %s vs %s.',
        v_accused,
        v_r.side,
        coalesce(v_home_name, '?'),
        coalesce(v_away_name, '?')
      ),
      v_lines,
      CASE WHEN v_n = 1
        THEN 'The fine is on the club account.'
        ELSE 'The fines are on the club account.'
      END
    ),
    15105570,
    format('match_video_report_upheld:%s', v_r.id),
    jsonb_build_object(
      'channel', 'news',
      'kind', 'match_video_report_upheld',
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

REVOKE ALL ON FUNCTION public.match_video_report_post_upheld_news(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_report_post_upheld_news(bigint)
  TO service_role;

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('match_video_report_post_upheld_news' IN v_def) > 0 THEN
    RETURN;
  END IF;
  v_old := replace($old$
  RETURN jsonb_build_object(
    'ok', true,
    'status', 'approved',
    'report_id', p_report_id,$old$, E'\r\n', E'\n');
  v_new := replace($new$
  BEGIN
    PERFORM public.match_video_report_post_upheld_news(p_report_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'approved',
    'report_id', p_report_id,$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'approve return not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$wire$;

-- Reports already approved, with no upheld news post yet.
DO $backfill$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT rep.id
    FROM public.match_video_breach_reports rep
    WHERE rep.status IN ('approved', 'upheld')
      AND NOT EXISTS (
        SELECT 1
        FROM public.gpsl_discord_feed_queue q
        WHERE q.dedupe_key = 'match_video_report_upheld:' || rep.id::text
      )
    ORDER BY rep.id
  LOOP
    PERFORM public.match_video_report_post_upheld_news(r.id);
  END LOOP;
END
$backfill$;

SELECT jsonb_build_object(
  'wired', position(
    'match_video_report_post_upheld_news'
    IN pg_get_functiondef('public.admin_match_video_resolve_breach_report(bigint,text,text,text,numeric,boolean)'::regprocedure)
  ) > 0,
  'queue', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'key', q.dedupe_key,
      'title', q.headline,
      'status', q.status
    ) ORDER BY q.dedupe_key), '[]'::jsonb)
    FROM public.gpsl_discord_feed_queue q
    WHERE q.dedupe_key LIKE 'match_video_report_upheld:%'
  )
);
