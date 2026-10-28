-- =============================================================================
-- Friendlies: second Discord post must always register (2026-10-28)
--
-- Pattern: first post gets ⏳; opponent's matching post never gets a tick.
-- Cause: when the *second* ingest finds a match it also pays both clubs. If
-- pay/ledger raises (e.g. missing Club_Finances), the whole RPC rolls back —
-- so the second Discord message is never stored. The edge watermark still
-- advanced past it → never retried.
--
-- Fix: confirm the friendly first; pay inside EXCEPTION blocks so a pay miss
-- cannot wipe the match. Pair with redeployed discord-friendlies-ingest
-- (watermark no longer skips errored messages).
--
-- Safe re-run. Requires gpsl_friendlies_resolve_month + pay_club helpers.
-- =============================================================================

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
  v_pay_err text;
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
      'reason', 'Bad format — use: CLUB score - score CLUB (e.g. JUB 2 - 2 BEN) or CLUB score - CLUB score'
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

  IF to_regprocedure('public.gpsl_friendlies_resolve_month(bigint,timestamptz)') IS NOT NULL THEN
    v_month := public.gpsl_friendlies_resolve_month(v_season_id, coalesce(p_posted_at, now()));
  ELSE
    v_month := public.competition_active_gpsl_month(v_season_id, coalesce(p_posted_at, now()));
  END IF;
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

  -- Match found — always persist the friendly even if pay fails
  v_scoreline := format(
    '%s %s - %s %s',
    v_match.club_left, v_match.score_left, v_match.score_right, v_match.club_right
  );

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

  BEGIN
    v_pay_l := public.gpsl_friendlies_pay_club(
      v_season_id, v_month, v_match.club_left, v_friendly_id, v_scoreline
    );
  EXCEPTION WHEN OTHERS THEN
    v_pay_err := SQLERRM;
    v_pay_l := jsonb_build_object('paid', 0, 'skipped', left('Pay error: ' || v_pay_err, 200));
  END;

  BEGIN
    v_pay_r := public.gpsl_friendlies_pay_club(
      v_season_id, v_month, v_match.club_right, v_friendly_id, v_scoreline
    );
  EXCEPTION WHEN OTHERS THEN
    v_pay_err := SQLERRM;
    v_pay_r := jsonb_build_object('paid', 0, 'skipped', left('Pay error: ' || v_pay_err, 200));
  END;

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

REVOKE ALL ON FUNCTION public.gpsl_friendlies_ingest_post(text, text, text, text, timestamptz)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_ingest_post(text, text, text, text, timestamptz)
  TO service_role, authenticated;

COMMENT ON FUNCTION public.gpsl_friendlies_ingest_post(text, text, text, text, timestamptz) IS
  'Ingest Discord friendly scoreline. Match confirms even if gate pay fails (pay errors recorded on friendly row).';

-- Rematch any pairs that are both pending (recovery for stuck first posts)
-- Requires friendlies_rematch_pending_diagnose_20261028.sql first.
DO $chk$
BEGIN
  IF to_regprocedure('public.admin_gpsl_friendlies_rematch_pending(boolean)') IS NOT NULL THEN
    RAISE NOTICE 'rematch dry_run: %',
      public.admin_gpsl_friendlies_rematch_pending(true);
  ELSE
    RAISE NOTICE 'admin_gpsl_friendlies_rematch_pending missing — run friendlies_rematch_pending_diagnose_20261028.sql';
  END IF;
END;
$chk$;
-- SELECT public.admin_gpsl_friendlies_rematch_pending(false) AS rematch_applied;
