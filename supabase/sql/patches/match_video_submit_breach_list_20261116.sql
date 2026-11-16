-- Video report submit: the fixtures page sends p_breaches (jsonb).
-- Live submit was still the single-code function, and the breaches column was missing.
-- Accepts the same fines the R button lists (on_video_report).

ALTER TABLE public.match_video_breach_reports
  ADD COLUMN IF NOT EXISTS breaches jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.match_video_breach_reports.breaches IS
  'Array of {code, note, label, instances?} for one match-side report.';

CREATE UNIQUE INDEX IF NOT EXISTS match_video_breach_reports_fixture_side_uidx
  ON public.match_video_breach_reports (fixture_id, side);

DROP FUNCTION IF EXISTS public.match_video_submit_breach_report(bigint, text, text, text);

CREATE OR REPLACE FUNCTION public.match_video_submit_breach_report(
  p_fixture_id bigint,
  p_side text,
  p_breaches jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_side text := lower(btrim(p_side));
  v_f record;
  v_accused text;
  v_reporter_club text;
  v_id bigint;
  v_item jsonb;
  v_code text;
  v_note text;
  v_label text;
  v_instances int;
  v_clean jsonb := '[]'::jsonb;
  v_n int := 0;
  v_first_code text;
  v_alert_id bigint;
  v_body text;
  v_summary text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_fixture_id IS NULL OR v_side NOT IN ('home', 'away') THEN
    RAISE EXCEPTION 'fixture_id and side (home|away) required';
  END IF;
  IF p_breaches IS NULL OR jsonb_typeof(p_breaches) <> 'array' OR jsonb_array_length(p_breaches) < 1 THEN
    RAISE EXCEPTION 'Select at least one breach';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.match_video_breach_reports r
    WHERE r.fixture_id = p_fixture_id AND r.side = v_side
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'already_reported',
      'message', 'This match side has already been reported and cannot be reported again.'
    );
  END IF;

  SELECT f.* INTO v_f
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;
  IF v_f.status <> 'played' THEN
    RAISE EXCEPTION 'Fixture must be played';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.fixture_match_videos v
    WHERE v.fixture_id = p_fixture_id AND v.side = v_side
  ) THEN
    RAISE EXCEPTION 'No uploaded video on that side to report';
  END IF;

  v_accused := CASE
    WHEN v_side = 'home' THEN upper(btrim(v_f.home_club_short_name))
    ELSE upper(btrim(v_f.away_club_short_name))
  END;

  SELECT upper(btrim(c."ShortName"))
  INTO v_reporter_club
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  ORDER BY c."ShortName"
  LIMIT 1;

  IF v_reporter_club IS NULL THEN
    RAISE EXCEPTION 'You must own a club to submit a report';
  END IF;
  IF v_reporter_club = v_accused THEN
    RAISE EXCEPTION 'You cannot report your own club video';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_breaches)
  LOOP
    v_code := btrim(coalesce(v_item->>'code', ''));
    v_note := btrim(coalesce(v_item->>'note', ''));
    IF v_code = '' THEN
      RAISE EXCEPTION 'Each breach must include a code';
    END IF;
    IF v_note = '' THEN
      RAISE EXCEPTION 'Every selected breach must include a note';
    END IF;

    SELECT t.label INTO v_label
    FROM public.competition_fine_tariff t
    WHERE t.code = v_code
      AND t.is_active
      AND t.direction = 'fine'
      AND t.on_video_report
      AND t.code <> 'match_video_missing';

    IF v_label IS NULL THEN
      RAISE EXCEPTION 'Invalid breach code: %', v_code;
    END IF;

    v_instances := NULL;
    IF v_code = 'formation_player_drag' THEN
      BEGIN
        v_instances := greatest(1, least(20, coalesce(nullif(v_item->>'instances', '')::int, 1)));
      EXCEPTION WHEN OTHERS THEN
        v_instances := 1;
      END;
    END IF;

    IF v_first_code IS NULL THEN
      v_first_code := v_code;
    END IF;

    v_clean := v_clean || jsonb_build_array(
      jsonb_strip_nulls(jsonb_build_object(
        'code', v_code,
        'note', v_note,
        'label', v_label,
        'instances', v_instances
      ))
    );
    v_n := v_n + 1;
  END LOOP;

  IF v_n < 1 THEN
    RAISE EXCEPTION 'Select at least one breach';
  END IF;

  BEGIN
    INSERT INTO public.match_video_breach_reports (
      season_id, fixture_id, side, accused_club_short_name,
      reporter_owner_id, reporter_club_short_name,
      breach_tariff_code, note, breaches, status
    ) VALUES (
      v_f.season_id,
      p_fixture_id,
      v_side,
      v_accused,
      v_uid,
      v_reporter_club,
      v_first_code,
      (v_clean->0->>'note'),
      v_clean,
      'open'
    )
    RETURNING id INTO v_id;
  EXCEPTION
    WHEN unique_violation THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'already_reported',
        'message', 'This match side has already been reported and cannot be reported again.'
      );
  END;

  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    BEGIN
      SELECT string_agg(
        format(
          '%s%s — %s',
          coalesce(b->>'label', b->>'code'),
          CASE
            WHEN b->>'code' = 'formation_player_drag'
              THEN format(' (%s drag%s)', coalesce(b->>'instances', '1'), CASE WHEN coalesce(b->>'instances', '1') = '1' THEN '' ELSE 's' END)
            ELSE ''
          END,
          coalesce(b->>'note', '')
        ),
        E'\n'
      )
      INTO v_summary
      FROM jsonb_array_elements(v_clean) b;

      v_body := format(
        E'%s reported %s (%s video).\nFixture %s vs %s.\n\n%s\n\nNothing is applied until you approve it on Match video reports.',
        v_reporter_club,
        v_accused,
        v_side,
        v_f.home_club_short_name,
        v_f.away_club_short_name,
        coalesce(v_summary, '')
      );
      v_alert_id := public.gpsl_staff_alert_create(
        'match_video_report',
        format('Match video report: %s', v_accused),
        v_body,
        'admin_match_video_reports.html',
        jsonb_build_object(
          'report_id', v_id,
          'fixture_id', p_fixture_id,
          'side', v_side,
          'accused', v_accused,
          'reporter', v_reporter_club
        ),
        format('match_video_report:%s', v_id)
      );
    EXCEPTION WHEN OTHERS THEN
      v_alert_id := NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'report_id', v_id,
    'breach_count', v_n,
    'staff_alert_id', v_alert_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_submit_breach_report(bigint, text, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_match_video_list_breach_reports(
  p_status text DEFAULT 'open',
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text := lower(btrim(coalesce(p_status, 'open')));
  v_limit int := greatest(1, least(coalesce(p_limit, 100), 500));
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC)
    FROM (
      SELECT
        r.id,
        r.season_id,
        r.fixture_id,
        r.side,
        r.accused_club_short_name,
        r.reporter_club_short_name,
        r.reporter_owner_id,
        r.breach_tariff_code,
        r.breaches,
        jsonb_array_length(coalesce(r.breaches, '[]'::jsonb)) AS breach_count,
        r.note,
        CASE r.status
          WHEN 'upheld' THEN 'approved'
          WHEN 'dismissed' THEN 'rejected'
          ELSE r.status
        END AS status,
        r.created_at,
        r.reviewed_at,
        r.review_note,
        r.upheld_tariff_code,
        r.fine_applied_id,
        r.reward_ledger_id,
        f.matchday,
        f.gpsl_month,
        f.competition_type,
        f.division,
        f.cup_code,
        f.home_club_short_name,
        f.away_club_short_name,
        f.home_goals,
        f.away_goals,
        f.cup_pen_winner_club_short_name,
        v.video_url
      FROM public.match_video_breach_reports r
      JOIN public.competition_fixtures f ON f.id = r.fixture_id
      LEFT JOIN public.fixture_match_videos v
        ON v.fixture_id = r.fixture_id AND v.side = r.side
      WHERE (
        v_status = 'all'
        OR r.status = v_status
        OR (v_status = 'approved' AND r.status IN ('approved', 'upheld'))
        OR (v_status = 'rejected' AND r.status IN ('rejected', 'dismissed'))
        OR (v_status = 'open' AND r.status = 'open')
      )
      ORDER BY r.created_at DESC
      LIMIT v_limit
    ) x
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_match_video_list_breach_reports(text, int) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.match_video_submit_breach_report(bigint,text,jsonb)') IS NOT NULL AS submit_list,
  to_regprocedure('public.match_video_submit_breach_report(bigint,text,text,text)') IS NOT NULL AS submit_old,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'match_video_breach_reports'
      AND column_name = 'breaches'
  ) AS breaches_column;
