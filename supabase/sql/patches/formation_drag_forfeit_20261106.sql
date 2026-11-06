-- =============================================================================
-- Sub tactic and Fluid must be a default Konami formation, set before the
-- eFootball match. No player dragging.
--
-- A video report does nothing until staff approve it. Approving:
--   offender won or drew → replay the match
--   opponent won         → result stands
--   2 or more drags      → also deduct 1 league point
-- Staff get an alert as soon as the report is submitted.
-- Run once in the Supabase SQL Editor.
-- =============================================================================

INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES (
  'formation_player_drag',
  'Dragged players off the default formation',
  'matchday',
  'fine',
  0,
  'fixed',
  84,
  true
)
ON CONFLICT (code) DO UPDATE
SET
  label = excluded.label,
  category = excluded.category,
  direction = excluded.direction,
  amount = excluded.amount,
  amount_mode = excluded.amount_mode,
  sort_order = excluded.sort_order,
  is_active = true,
  updated_at = now();

CREATE OR REPLACE FUNCTION public.fixture_apply_formation_drag_sanction(
  p_fixture_id bigint,
  p_offender_club text,
  p_instances int,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_offender text := upper(btrim(coalesce(p_offender_club, '')));
  v_home text;
  v_away text;
  v_pen text;
  v_instances int := greatest(1, least(20, coalesce(p_instances, 1)));
  v_won_or_drew boolean := false;
  v_replay jsonb;
  v_points bigint;
  v_reason text := coalesce(
    nullif(btrim(coalesce(p_reason, '')), ''),
    'Dragged players off the default formation'
  );
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;
  IF v_f.home_goals IS NULL OR v_f.away_goals IS NULL THEN
    RAISE EXCEPTION 'Fixture has no score yet';
  END IF;

  v_home := upper(btrim(v_f.home_club_short_name));
  v_away := upper(btrim(v_f.away_club_short_name));
  IF v_offender NOT IN (v_home, v_away) THEN
    RAISE EXCEPTION 'Offender must be a club in this fixture';
  END IF;

  v_pen := upper(btrim(coalesce(v_f.cup_pen_winner_club_short_name, '')));

  IF v_f.home_goals = v_f.away_goals THEN
    IF v_pen = '' THEN
      v_won_or_drew := true;
    ELSE
      v_won_or_drew := v_pen = v_offender;
    END IF;
  ELSIF v_f.home_goals > v_f.away_goals THEN
    v_won_or_drew := v_offender = v_home;
  ELSE
    v_won_or_drew := v_offender = v_away;
  END IF;

  IF v_instances >= 2
     AND to_regprocedure('public.match_video_apply_league_points(text, smallint, text, bigint)') IS NOT NULL THEN
    v_points := public.match_video_apply_league_points(
      v_offender,
      -1::smallint,
      format(
        'Formation drag: %s drags. %s',
        v_instances,
        v_reason
      ),
      v_f.season_id
    );
  END IF;

  v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Formation drag upheld');
  v_body := public.competition_fixture_inbox_body(
    p_fixture_id,
    format(
      '%s dragged players off the default formation (%s time%s). %s%s',
      public.club_display_name(v_offender),
      v_instances,
      CASE WHEN v_instances = 1 THEN '' ELSE 's' END,
      CASE
        WHEN v_won_or_drew THEN 'They won or drew, so this match will be replayed.'
        ELSE 'The opponent won, so the result stands.'
      END,
      CASE
        WHEN v_instances >= 2 THEN ' 1 league point deducted.'
        ELSE ''
      END
    )
  );

  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_f.home_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'formation-drag:' || p_fixture_id::text || ':' || v_instances::text || ':home',
    v_f.gpsl_month, v_f.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_f.away_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'formation-drag:' || p_fixture_id::text || ':' || v_instances::text || ':away',
    v_f.gpsl_month, v_f.season_id, NULL
  );

  IF v_won_or_drew THEN
    IF to_regprocedure('public.admin_fixture_reset_for_replay(bigint, text, text)') IS NULL THEN
      RAISE EXCEPTION 'Replay reset is not installed';
    END IF;
    v_replay := public.admin_fixture_reset_for_replay(
      p_fixture_id,
      format('Formation drag upheld (%s drag%s). %s', v_instances, CASE WHEN v_instances = 1 THEN '' ELSE 's' END, v_reason),
      'RESET FIXTURE REPLAY'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'offender', v_offender,
    'instances', v_instances,
    'replay', v_won_or_drew,
    'result_stands', NOT v_won_or_drew,
    'points_deducted', v_instances >= 2,
    'points_adjustment_id', v_points,
    'replay_reset', v_replay
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_apply_formation_drag_sanction(bigint, text, int, text)
  FROM PUBLIC, anon;

DROP FUNCTION IF EXISTS public.fixture_apply_formation_drag_forfeit(bigint, text, text);

-- Approve path: formation drag replays or leaves the result, and may deduct 1 point. Other breaches stay fines.
CREATE OR REPLACE FUNCTION public.admin_match_video_resolve_breach_report(
  p_report_id bigint,
  p_action text,
  p_tariff_code text DEFAULT NULL,
  p_review_note text DEFAULT NULL,
  p_amount_override numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_action text := lower(btrim(p_action));
  v_uid uuid := auth.uid();
  v_r public.match_video_breach_reports%ROWTYPE;
  v_item jsonb;
  v_code text;
  v_note text;
  v_apply jsonb;
  v_fines jsonb := '[]'::jsonb;
  v_reward_id bigint;
  v_reward numeric := 2000;
  v_forfeit jsonb;
  v_instances int;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  IF v_action IN ('uphold', 'ok', 'approve') THEN
    v_action := 'approve';
  ELSIF v_action IN ('dismiss', 'reject') THEN
    v_action := 'reject';
  END IF;

  IF v_action NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'action must be approve or reject';
  END IF;

  SELECT * INTO v_r
  FROM public.match_video_breach_reports
  WHERE id = p_report_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Report not found';
  END IF;
  IF v_r.status <> 'open' THEN
    RAISE EXCEPTION 'Report already resolved';
  END IF;

  IF v_action = 'reject' THEN
    UPDATE public.match_video_breach_reports
    SET status = 'rejected',
        reviewed_at = now(),
        reviewed_by = v_uid,
        review_note = nullif(btrim(coalesce(p_review_note, '')), '')
    WHERE id = p_report_id;

    RETURN jsonb_build_object('ok', true, 'status', 'rejected', 'report_id', p_report_id);
  END IF;

  FOR v_item IN
    SELECT * FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(coalesce(v_r.breaches, '[]'::jsonb)) = 'array'
             AND jsonb_array_length(v_r.breaches) > 0
          THEN v_r.breaches
        ELSE jsonb_build_array(
          jsonb_build_object(
            'code', coalesce(nullif(btrim(coalesce(p_tariff_code, '')), ''), v_r.breach_tariff_code),
            'note', coalesce(v_r.note, format('Match video breach report #%s', p_report_id))
          )
        )
      END
    )
  LOOP
    v_code := btrim(coalesce(v_item->>'code', ''));
    v_note := btrim(coalesce(v_item->>'note', ''));
    IF v_code = '' THEN
      CONTINUE;
    END IF;

    IF v_code = 'formation_player_drag' THEN
      v_instances := 1;
      BEGIN
        v_instances := greatest(
          1,
          least(20, coalesce(nullif(v_item->>'instances', '')::int, 1))
        );
      EXCEPTION WHEN OTHERS THEN
        v_instances := 1;
      END;
      -- Failure here aborts the approval so a replay cannot be half-applied.
      v_forfeit := public.fixture_apply_formation_drag_sanction(
        v_r.fixture_id,
        v_r.accused_club_short_name,
        v_instances,
        coalesce(nullif(v_note, ''), 'Dragged players off the default formation')
      );
      v_fines := v_fines || jsonb_build_array(
        jsonb_build_object('code', v_code, 'sanction', v_forfeit)
      );
      CONTINUE;
    END IF;

    BEGIN
      v_apply := public.competition_apply_club_fine_tariff(
        v_r.accused_club_short_name,
        v_code,
        p_amount_override,
        coalesce(
          nullif(v_note, ''),
          format('Match video breach report #%s', p_report_id)
        ),
        v_r.fixture_id,
        v_r.season_id
      );
      v_fines := v_fines || jsonb_build_array(
        jsonb_build_object('code', v_code, 'apply', v_apply)
      );
    EXCEPTION WHEN OTHERS THEN
      v_fines := v_fines || jsonb_build_array(
        jsonb_build_object('code', v_code, 'error', SQLERRM)
      );
    END;
  END LOOP;

  BEGIN
    PERFORM public.owner_wallet_ensure(v_r.reporter_owner_id);
    v_reward_id := public._post_owner_ledger_internal(
      v_r.reporter_owner_id,
      'match_video_report_reward',
      v_reward,
      format('Match video report approved (#%s)', p_report_id),
      jsonb_build_object(
        'source', 'match_video_breach_report',
        'report_id', p_report_id,
        'fixture_id', v_r.fixture_id
      ),
      v_r.season_id,
      true
    );
  EXCEPTION WHEN OTHERS THEN
    v_reward_id := NULL;
  END;

  UPDATE public.match_video_breach_reports
  SET status = 'approved',
      reviewed_at = now(),
      reviewed_by = v_uid,
      review_note = nullif(btrim(coalesce(p_review_note, '')), ''),
      upheld_tariff_code = coalesce(v_r.breaches->0->>'code', v_r.breach_tariff_code),
      fine_applied_id = nullif(v_fines->0->'apply'->>'applied_id', '')::bigint,
      fine_ledger_id = nullif(v_fines->0->'apply'->>'ledger_id', '')::bigint,
      reward_ledger_id = v_reward_id
  WHERE id = p_report_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'approved',
    'report_id', p_report_id,
    'fines', v_fines,
    'reward_ledger_id', v_reward_id,
    'reward_amount', v_reward
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric)
  TO authenticated;

-- Keep the drag count on the report, and tell staff a report is waiting.
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
      AND t.category IN ('matchday', 'squad', 'manager')
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
