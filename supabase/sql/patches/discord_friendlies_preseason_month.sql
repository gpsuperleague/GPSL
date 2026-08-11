-- =============================================================================
-- Discord friendlies: allow ingest in calendar gaps (pre-June / between months)
--
-- Live evidence: poll ingested LIV/MON scorelines then ignored with
--   "No active GPSL month" and advanced the watermark.
-- Cause: competition_active_gpsl_month is null before June unlock.
-- Not caused by security_hardening_safe.sql (poll + key were healthy).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_resolve_month(
  p_season_id bigint,
  p_at timestamptz DEFAULT now()
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text;
  v_at timestamptz := coalesce(p_at, now());
BEGIN
  IF p_season_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_month := public.competition_active_gpsl_month(p_season_id, v_at);
  IF v_month IS NOT NULL THEN
    RETURN v_month;
  END IF;

  -- Before first unlock, or between month lock and next unlock:
  -- attribute friendlies to the next upcoming GPSL month.
  SELECT m.gpsl_month INTO v_month
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id
    AND m.unlock_at > v_at
    AND lower(m.gpsl_month) <> 'playoffs'
  ORDER BY m.unlock_at
  LIMIT 1;

  RETURN v_month;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_friendlies_resolve_month(bigint, timestamptz) IS
  'GPSL month for friendlies: active month, else next upcoming calendar month.';

-- Only the month-resolution line differs from discord_friendlies_gate.sql
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_ingest_post(
  p_discord_message_id text,
  p_discord_user_id text,
  p_reporter_club text,
  p_content text,
  p_posted_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_msg_id text := nullif(btrim(coalesce(p_discord_message_id, '')), '');
  v_club text := upper(nullif(btrim(coalesce(p_reporter_club, '')), ''));
  v_parsed jsonb;
  v_canon jsonb;
  v_season_id bigint;
  v_month text;
  v_club_l text;
  v_club_r text;
  v_score_l int;
  v_score_r int;
  v_canon_a text;
  v_canon_b text;
  v_score_a int;
  v_score_b int;
  v_report public.gpsl_friendly_reports%ROWTYPE;
  v_match public.gpsl_friendly_reports%ROWTYPE;
  v_friendly_id bigint;
  v_scoreline text;
  v_pay_l jsonb;
  v_pay_r jsonb;
  v_exists boolean;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_msg_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Missing Discord message id');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.gpsl_friendly_reports r WHERE r.discord_message_id = v_msg_id
  ) INTO v_exists;
  IF v_exists THEN
    RETURN jsonb_build_object('ok', true, 'status', 'duplicate', 'reason', 'Already ingested');
  END IF;

  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Could not map Discord user to a GPSL club');
  END IF;

  v_parsed := public.gpsl_friendlies_parse_scoreline(p_content);
  IF v_parsed IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Bad format — use: CLUB score - score CLUB (e.g. JUB 2 - 2 BEN)'
    );
  END IF;

  v_club_l := v_parsed ->> 'club_left';
  v_club_r := v_parsed ->> 'club_right';
  v_score_l := (v_parsed ->> 'score_left')::int;
  v_score_r := (v_parsed ->> 'score_right')::int;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE upper(c."ShortName") = v_club_l) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', format('Unknown club %s', v_club_l));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE upper(c."ShortName") = v_club_r) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', format('Unknown club %s', v_club_r));
  END IF;

  IF v_club <> v_club_l AND v_club <> v_club_r THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', format('Your club (%s) is not in this scoreline', v_club)
    );
  END IF;

  v_season_id := public.gpsl_friendlies_live_season_id();
  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'No live season');
  END IF;

  -- Was competition_active_gpsl_month — rejected all pre-June posts
  v_month := public.gpsl_friendlies_resolve_month(v_season_id, coalesce(p_posted_at, now()));
  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'No active GPSL month');
  END IF;

  v_canon := public.gpsl_friendlies_canonical(v_club_l, v_score_l, v_club_r, v_score_r);
  v_canon_a := v_canon ->> 'canon_club_a';
  v_canon_b := v_canon ->> 'canon_club_b';
  v_score_a := (v_canon ->> 'canon_score_a')::int;
  v_score_b := (v_canon ->> 'canon_score_b')::int;

  UPDATE public.gpsl_friendly_reports
  SET status = 'expired',
      note = 'Expired — no matching opponent post'
  WHERE status = 'pending'
    AND season_id = v_season_id
    AND posted_at < now() - make_interval(hours => public.gpsl_friendlies_pending_hours());

  IF EXISTS (
    SELECT 1
    FROM public.gpsl_friendly_reports r
    WHERE r.status = 'pending'
      AND r.season_id = v_season_id
      AND r.gpsl_month = v_month
      AND r.canon_club_a = v_canon_a
      AND r.canon_club_b = v_canon_b
      AND r.canon_score_a = v_score_a
      AND r.canon_score_b = v_score_b
      AND upper(r.reporter_club_short_name) = v_club
      AND r.posted_at >= now() - make_interval(hours => public.gpsl_friendlies_pending_hours())
  ) THEN
    INSERT INTO public.gpsl_friendly_reports (
      season_id, gpsl_month, discord_message_id, discord_user_id,
      reporter_club_short_name,
      club_left, score_left, club_right, score_right,
      canon_club_a, canon_score_a, canon_club_b, canon_score_b,
      status, note, posted_at
    )
    VALUES (
      v_season_id, v_month, v_msg_id, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
      v_club,
      v_club_l, v_score_l, v_club_r, v_score_r,
      v_canon_a, v_score_a, v_canon_b, v_score_b,
      'ignored',
      'Duplicate pending post from same club',
      coalesce(p_posted_at, now())
    );
    RETURN jsonb_build_object(
      'ok', true,
      'status', 'duplicate',
      'reason', 'You already have a pending post for this scoreline'
    );
  END IF;

  SELECT r.* INTO v_match
  FROM public.gpsl_friendly_reports r
  WHERE r.status = 'pending'
    AND r.season_id = v_season_id
    AND r.gpsl_month = v_month
    AND r.canon_club_a = v_canon_a
    AND r.canon_club_b = v_canon_b
    AND r.canon_score_a = v_score_a
    AND r.canon_score_b = v_score_b
    AND upper(r.reporter_club_short_name) <> v_club
    AND (
      upper(r.reporter_club_short_name) = v_club_l
      OR upper(r.reporter_club_short_name) = v_club_r
    )
    AND r.posted_at >= now() - make_interval(hours => public.gpsl_friendlies_pending_hours())
  ORDER BY r.posted_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  INSERT INTO public.gpsl_friendly_reports (
    season_id, gpsl_month, discord_message_id, discord_user_id,
    reporter_club_short_name,
    club_left, score_left, club_right, score_right,
    canon_club_a, canon_score_a, canon_club_b, canon_score_b,
    status, posted_at
  )
  VALUES (
    v_season_id, v_month, v_msg_id, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
    v_club,
    v_club_l, v_score_l, v_club_r, v_score_r,
    v_canon_a, v_score_a, v_canon_b, v_score_b,
    CASE WHEN v_match.id IS NULL THEN 'pending' ELSE 'matched' END,
    coalesce(p_posted_at, now())
  )
  RETURNING * INTO v_report;

  IF v_match.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'status', 'pending',
      'report_id', v_report.id,
      'scoreline', format('%s %s - %s %s', v_club_l, v_score_l, v_score_r, v_club_r),
      'reason', 'Waiting for opponent to post the matching result'
    );
  END IF;

  v_scoreline := format('%s %s - %s %s', v_match.club_left, v_match.score_left, v_match.score_right, v_match.club_right);

  INSERT INTO public.gpsl_friendlies (
    season_id, gpsl_month,
    club_left, score_left, club_right, score_right,
    report_1_id, report_2_id
  )
  VALUES (
    v_season_id, v_month,
    v_match.club_left, v_match.score_left, v_match.club_right, v_match.score_right,
    v_match.id, v_report.id
  )
  RETURNING id INTO v_friendly_id;

  v_pay_l := public.gpsl_friendlies_pay_club(
    v_season_id, v_month, v_match.club_left, v_friendly_id, v_scoreline
  );
  v_pay_r := public.gpsl_friendlies_pay_club(
    v_season_id, v_month, v_match.club_right, v_friendly_id, v_scoreline
  );

  UPDATE public.gpsl_friendlies
  SET paid_left = coalesce((v_pay_l ->> 'paid')::numeric, 0),
      paid_right = coalesce((v_pay_r ->> 'paid')::numeric, 0),
      left_skipped_reason = v_pay_l ->> 'skipped',
      right_skipped_reason = v_pay_r ->> 'skipped'
  WHERE id = v_friendly_id;

  UPDATE public.gpsl_friendly_reports
  SET status = 'matched',
      matched_friendly_id = v_friendly_id
  WHERE id IN (v_match.id, v_report.id);

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'matched',
    'friendly_id', v_friendly_id,
    'scoreline', v_scoreline,
    'paid_left', coalesce((v_pay_l ->> 'paid')::numeric, 0),
    'paid_right', coalesce((v_pay_r ->> 'paid')::numeric, 0),
    'left_skipped', v_pay_l ->> 'skipped',
    'right_skipped', v_pay_r ->> 'skipped',
    'report_id', v_report.id,
    'matched_report_id', v_match.id,
    'discord_message_ids', jsonb_build_array(
      v_match.discord_message_id,
      v_report.discord_message_id
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_resolve_month(bigint, timestamptz)
  TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_ingest_post(text, text, text, text, timestamptz)
  TO service_role, authenticated;
