-- Manual video-report tariffs were saved with an amount, but approve passes no override,
-- so both Monaco charges were skipped. Use the catalogue amount when no override is typed.
-- News posts name the accused club and the breaches only.

DO $manual_amount$
DECLARE
  v_oid oid;
  v_def text;
  v_old text := $old$  IF v_tariff.amount_mode = 'manual' THEN
    v_amount := p_amount_override;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Manual amount required for %', v_tariff.label;
    END IF;$old$;
  v_new text := $new$  IF v_tariff.amount_mode = 'manual' THEN
    v_amount := coalesce(p_amount_override, v_tariff.amount);
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Manual amount required for %', v_tariff.label;
    END IF;$new$;
BEGIN
  v_oid := to_regprocedure(
    'public.competition_apply_club_fine_tariff(text,text,numeric,text,bigint,bigint)'
  );
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'competition_apply_club_fine_tariff not found';
  END IF;
  v_def := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'manual amount branch not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$manual_amount$;

DO $alert_text$
DECLARE
  v_oid oid;
  v_def text;
  v_old text := $old$      v_body := format(
        E'%s reported %s (%s video).\nFixture %s vs %s.\n\n%s\n\nNothing is applied until you approve it on Match video reports.',
        v_reporter_club,
        v_accused,$old$;
  v_new text := $new$      v_body := format(
        E'A match video report was filed against %s (%s video).\nFixture %s vs %s.\n\n%s\n\nNothing is applied until you approve it on Match video reports.',
        v_accused,$new$;
BEGIN
  v_oid := to_regprocedure('public.match_video_submit_breach_report(bigint,text,jsonb)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'submit function missing';
  END IF;
  v_def := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('A match video report was filed against' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'report alert wording not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$alert_text$;

DO $hide_reporter$
DECLARE
  v_oid oid;
  v_def text;
  v_old text := $old$        r.reporter_club_short_name,
        r.reporter_owner_id,
$old$;
BEGIN
  v_oid := to_regprocedure('public.admin_match_video_list_breach_reports(text,integer)');
  IF v_oid IS NULL THEN
    v_oid := to_regprocedure('public.admin_match_video_list_breach_reports(text,int)');
  END IF;
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'report list function missing';
  END IF;
  v_def := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  v_old := replace(v_old, E'\r\n', E'\n');
  IF position('r.reporter_club_short_name' IN v_def) = 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'reporter columns not found on the report list';
  END IF;
  EXECUTE replace(v_def, v_old, '');
END;
$hide_reporter$;

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
    format('MATCH VIDEO REPORT — %s', v_r.accused_club_short_name),
    concat_ws(
      E'\n',
      format(
        '%s %s video. %s vs %s.',
        v_r.accused_club_short_name,
        v_r.side,
        coalesce(v_home, '?'),
        coalesce(v_away, '?')
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

CREATE OR REPLACE FUNCTION public.match_video_report_news_on_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.match_video_report_post_news(NEW.id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS match_video_report_news_on_insert ON public.match_video_breach_reports;
CREATE TRIGGER match_video_report_news_on_insert
  AFTER INSERT ON public.match_video_breach_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.match_video_report_news_on_insert();

UPDATE public.gpsl_staff_alerts
SET body = regexp_replace(body, '^[^\n]*', 'A match video report was filed.', 1)
WHERE alert_type = 'match_video_report'
  AND metadata->>'report_id' = '1';

DO $charge$
DECLARE
  v_season bigint;
  v_a jsonb;
  v_b jsonb;
  v_news bigint;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.competition_fine_applied a
    WHERE a.fixture_id = 9105
      AND a.club_short_name = 'MON'
      AND a.tariff_code IN ('notshowingmanager', 'notshowingadvancedskill')
      AND coalesce(a.waived, false) = false
  ) THEN
    RAISE EXCEPTION 'Monaco video fines already posted';
  END IF;

  SELECT season_id INTO v_season
  FROM public.match_video_breach_reports
  WHERE id = 1;

  v_a := public.competition_apply_club_fine_tariff(
    'MON',
    'notshowingmanager',
    NULL,
    'didnt show default manager',
    9105,
    v_season
  );
  v_b := public.competition_apply_club_fine_tariff(
    'MON',
    'notshowingadvancedskill',
    NULL,
    'didnt show advanced skill',
    9105,
    v_season
  );

  IF (
    SELECT count(*)
    FROM public.competition_fine_applied a
    JOIN public.competition_finance_ledger l ON l.id = a.ledger_id
    WHERE a.fixture_id = 9105
      AND a.club_short_name = 'MON'
      AND a.tariff_code IN ('notshowingmanager', 'notshowingadvancedskill')
      AND coalesce(a.waived, false) = false
      AND a.amount = 500000
      AND l.amount = -500000
  ) <> 2 THEN
    RAISE EXCEPTION 'Expected two itemised 500000 Monaco fines';
  END IF;

  UPDATE public.match_video_breach_reports
  SET fine_applied_id = (v_a->>'applied_id')::bigint,
      fine_ledger_id = (v_a->>'ledger_id')::bigint
  WHERE id = 1;

  v_news := public.match_video_report_post_news(1);
  IF v_news IS NULL THEN
    RAISE EXCEPTION 'News post was not queued';
  END IF;
END;
$charge$;

SELECT
  a.tariff_code,
  a.amount,
  a.waived,
  l.amount AS ledger_amount,
  l.description
FROM public.competition_fine_applied a
JOIN public.competition_finance_ledger l ON l.id = a.ledger_id
WHERE a.fixture_id = 9105
  AND a.club_short_name = 'MON'
  AND a.tariff_code IN ('notshowingmanager', 'notshowingadvancedskill')
ORDER BY a.tariff_code;
