-- Retire the league ₿1m late-arrangement fee.
-- A proposal in the last 48 hours before the play month opens is no longer charged.
-- No-proposal strikes are unchanged.
-- Safe re-run.

DO $fines$
DECLARE
  v_def text;
  v_els int;
  v_end int;
  v_chunk text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
  ), E'\r\n', E'\n');

  IF position('late arrangement fee retired' IN v_def) > 0 THEN
    RAISE NOTICE 'arrangement fines already skip the late fee';
    RETURN;
  END IF;

  v_els := position('ELSIF v_deadline IS NOT NULL' IN v_def);
  IF v_els = 0 THEN
    RAISE EXCEPTION 'arrangement fines: late-fee branch not found';
  END IF;
  v_end := v_els + position('END IF;' IN substring(v_def FROM v_els)) - 1;
  v_chunk := substring(v_def FROM v_els FOR v_end - v_els);
  IF position('match_late_arrangement' IN v_chunk) = 0
     OR position('match_mgmt_no_proposal' IN v_chunk) > 0 THEN
    RAISE EXCEPTION 'arrangement fines: late-fee branch did not match';
  END IF;

  v_def := substring(v_def FROM 1 FOR v_els - 1)
    || E'\n      -- late arrangement fee retired 2026-11-12\n      '
    || substring(v_def FROM v_end);
  EXECUTE v_def;
END;
$fines$;

DO $forecast$
DECLARE
  v_def text;
  v_at int;
  v_end int;
  v_chunk text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.admin_owner_board_fine_forecast()'::regprocedure
  ), E'\r\n', E'\n');

  IF position('THEN ''match_late_arrangement''' IN v_def) = 0 THEN
    RAISE NOTICE 'forecast already skips the late fee';
    RETURN;
  END IF;

  v_at := position('WHEN cal_play.unlock_at IS NOT NULL' IN v_def);
  v_end := position('THEN ''match_late_arrangement''' IN v_def);
  IF v_at = 0 OR v_end = 0 OR v_end < v_at THEN
    RAISE EXCEPTION 'forecast: late-fee branch not found';
  END IF;
  v_end := v_end + length('THEN ''match_late_arrangement''');
  v_chunk := substring(v_def FROM v_at FOR v_end - v_at);
  IF position('48 hours' IN v_chunk) = 0 THEN
    RAISE EXCEPTION 'forecast: late-fee branch did not match';
  END IF;
  v_def := substring(v_def FROM 1 FOR v_at - 1) || substring(v_def FROM v_end + 1);
  EXECUTE v_def;
END;
$forecast$;

DO $wire$
DECLARE
  v_def text;
  v_if int;
  v_end int;
  v_chunk text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.club_wire_cutoffs()'::regprocedure
  ), E'\r\n', E'\n');
  IF position('avoid late fee' IN v_def) = 0 THEN
    RAISE NOTICE 'club wire already has no late-fee deadline';
    RETURN;
  END IF;
  v_if := position('IF r.unlock_at - interval ''48 hours'' > now() THEN' IN v_def);
  v_end := CASE WHEN v_if = 0 THEN 0
    ELSE v_if + position('END IF;' IN substring(v_def FROM v_if)) - 1 END;
  IF v_if = 0 OR v_end < v_if THEN
    RAISE EXCEPTION 'club wire: late-fee deadline not found';
  END IF;
  v_end := v_end + length('END IF;');
  v_chunk := substring(v_def FROM v_if FOR v_end - v_if);
  IF position('avoid late fee' IN v_chunk) = 0 THEN
    RAISE EXCEPTION 'club wire: end if did not cover the late fee';
  END IF;
  v_def := substring(v_def FROM 1 FOR v_if - 1) || substring(v_def FROM v_end + 1);
  EXECUTE v_def;
END;
$wire$;

DO $deadlines$
DECLARE
  v_def text;
  v_if int;
  v_end int;
  v_chunk text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.owner_personal_deadlines(text)'::regprocedure
  ), E'\r\n', E'\n');
  IF position('avoid late fee' IN v_def) = 0 THEN
    RAISE NOTICE 'personal deadlines already have no late-fee item';
    RETURN;
  END IF;
  v_if := position('IF r.unlock_at - interval ''48 hours'' > now() THEN' IN v_def);
  v_end := CASE WHEN v_if = 0 THEN 0
    ELSE v_if + position('END IF;' IN substring(v_def FROM v_if)) - 1 END;
  IF v_if = 0 OR v_end < v_if THEN
    RAISE EXCEPTION 'personal deadlines: late-fee item not found';
  END IF;
  v_end := v_end + length('END IF;');
  v_chunk := substring(v_def FROM v_if FOR v_end - v_if);
  IF position('avoid late fee' IN v_chunk) = 0 THEN
    RAISE EXCEPTION 'personal deadlines: end if did not cover the late fee';
  END IF;
  v_def := substring(v_def FROM 1 FOR v_if - 1) || substring(v_def FROM v_end + 1);
  EXECUTE v_def;
END;
$deadlines$;

DO $guide$
DECLARE
  v_def text;
  v_start int;
  v_end int;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.match_owner_guidance_reminders()'::regprocedure
  ), E'\r\n', E'\n');
  IF position('late fee' IN v_def) = 0 THEN
    RAISE NOTICE 'guidance reminders already omit the late fee';
    RETURN;
  END IF;
  v_start := position('IF v_stage = ''early'' THEN' IN v_def);
  v_end := CASE WHEN v_start = 0 THEN 0
    ELSE v_start + position('END IF;' IN substring(v_def FROM v_start)) - 1 END;
  IF v_start = 0 OR v_end = 0 THEN
    RAISE EXCEPTION 'guidance reminders: stage block not found';
  END IF;
  IF position('late fee' IN substring(v_def FROM v_start FOR v_end - v_start)) = 0 THEN
    RAISE EXCEPTION 'guidance reminders: stage block has no late fee';
  END IF;
  v_new := replace($body$IF v_stage = 'early' THEN
      v_title := 'Arrange your next match';
      v_body := format(
        E'You are home in %s vs %s (GPSL %s).\n\nPropose a kick-off by %s. No proposal when the month opens is a strike: ₿500,000.\n\nOpen Schedule, pick a slot from your availability and press Propose kick-off.',
        v_label, v_opp, public.competition_gpsl_month_label(r.gpsl_month), v_deadline_txt
      );
    ELSIF v_stage = 'final' THEN
      v_title := 'Propose a kick-off — deadline soon';
      v_body := format(
        E'You still need to propose a kick-off for %s vs %s (GPSL %s).\n\nDeadline: %s. No proposal when the month opens is a strike: ₿500,000.',
        v_label, v_opp, public.competition_gpsl_month_label(r.gpsl_month), v_deadline_txt
      );
    ELSE
      v_title := 'Propose a kick-off before the month opens';
      v_body := format(
        E'No kick-off proposed yet for %s vs %s (GPSL %s). Propose before %s. No proposal when the month opens is a strike: ₿500,000. Each later lock with still no proposal is another strike.',
        v_label, v_opp, public.competition_gpsl_month_label(r.gpsl_month), v_deadline_txt
      );
    END IF;$body$, E'\r\n', E'\n');
  v_def := substring(v_def FROM 1 FOR v_start - 1)
    || v_new
    || substring(v_def FROM v_end + length('END IF;'));
  EXECUTE v_def;
END;
$guide$;

DO $notify$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.competition_notify_scheduling_deadline_warnings(bigint)'::regprocedure
  ), E'\r\n', E'\n');
  v_old := 'Last 48h = ₿2.5m late fee; no proposal by lock = ₿5m (repeats each lock until you propose).';
  v_new := 'No proposal when the month opens is a strike: ₿500,000. Each later lock with still no proposal is another.';
  IF position(v_old IN v_def) = 0 THEN
    IF position(v_new IN v_def) > 0 THEN
      RAISE NOTICE 'deadline warnings already omit the late fee';
      RETURN;
    END IF;
    RAISE EXCEPTION 'deadline warnings: late-fee sentence not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END;
$notify$;

SELECT
  position('match_late_arrangement' IN pg_get_functiondef(
    'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
  )) = 0 AS charge_gone,
  position('THEN ''match_late_arrangement''' IN pg_get_functiondef(
    'public.admin_owner_board_fine_forecast()'::regprocedure
  )) = 0 AS forecast_gone,
  position('avoid late fee' IN pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure)) = 0 AS wire_gone,
  position('avoid late fee' IN pg_get_functiondef('public.owner_personal_deadlines(text)'::regprocedure)) = 0 AS calendar_gone,
  position('late fee' IN pg_get_functiondef('public.match_owner_guidance_reminders()'::regprocedure)) = 0 AS guidance_gone,
  position('late fee' IN pg_get_functiondef(
    'public.competition_notify_scheduling_deadline_warnings(bigint)'::regprocedure
  )) = 0 AS notify_gone;
