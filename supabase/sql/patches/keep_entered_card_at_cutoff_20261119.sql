-- A pending result card is the score. The play-window award must not
-- forfeit over it. Keeps the entered stats. Safe re-run.

CREATE OR REPLACE FUNCTION public.match_result_keep_entered_card(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_sub public.competition_result_submissions;
  v_note text;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN;
  END IF;

  SELECT * INTO v_sub
  FROM public.competition_result_submissions s
  WHERE s.fixture_id = p_fixture_id
    AND s.status = 'pending'
  ORDER BY s.id DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_note := 'Score kept from the club that entered it before the cutoff';

  UPDATE public.competition_fixtures
  SET status = 'played',
      home_goals = v_sub.home_goals,
      away_goals = v_sub.away_goals,
      is_forfeit = false,
      forfeit_loser_club = NULL,
      is_void = false,
      award_note = v_note
  WHERE id = p_fixture_id;

  UPDATE public.competition_result_submissions
  SET status = 'confirmed',
      reject_reason = NULL,
      responded_by_club = NULL,
      responded_at = now()
  WHERE id = v_sub.id;

  BEGIN
    PERFORM public.competition_apply_submission_player_stats(v_sub.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'keep entered card stats %: %', p_fixture_id, SQLERRM;
  END;

  PERFORM public.owner_inbox_send(
    'result_confirmed',
    'Result kept — opponent had not confirmed',
    format(
      'The cutoff closed this match with a score already in: %s %s–%s %s. That card stands, including the stats that were entered. The other club can still add their own stats once.',
      v_f.home_club_short_name, v_sub.home_goals, v_sub.away_goals, v_f.away_club_short_name
    ),
    v_f.home_club_short_name, NULL, p_fixture_id,
    v_sub.id, NULL, NULL,
    'matchday.html?fixture=' || p_fixture_id::text,
    'entered_card_kept:' || p_fixture_id::text || ':home',
    v_f.gpsl_month, v_f.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'result_confirmed',
    'Result kept — opponent had not confirmed',
    format(
      'The cutoff closed this match with a score already in: %s %s–%s %s. That card stands, including the stats that were entered. The other club can still add their own stats once.',
      v_f.home_club_short_name, v_sub.home_goals, v_sub.away_goals, v_f.away_club_short_name
    ),
    v_f.away_club_short_name, NULL, p_fixture_id,
    v_sub.id, NULL, NULL,
    'matchday.html?fixture=' || p_fixture_id::text,
    'entered_card_kept:' || p_fixture_id::text || ':away',
    v_f.gpsl_month, v_f.season_id, NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_result_keep_entered_card(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_result_keep_entered_card(bigint) TO service_role;

DO $award$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_enforce_scheduling_window_awards(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('entered card kept' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$    v_loser := public.match_schedule_pick_window_loser(
      p_season_id, v_f.id, p_closed_gpsl_month
    );
$old$, E'\r\n', E'\n');

  v_new := replace($new$    IF EXISTS (
      SELECT 1 FROM public.competition_result_submissions s
      WHERE s.fixture_id = v_f.id AND s.status = 'pending'
    ) THEN
      PERFORM public.match_result_keep_entered_card(v_f.id);
      v_count := v_count + 1;
      v_awarded := v_awarded || jsonb_build_array(jsonb_build_object(
        'fixture_id', v_f.id,
        'result', 'entered card kept'
      ));
      CONTINUE;
    END IF;

    v_loser := public.match_schedule_pick_window_loser(
      p_season_id, v_f.id, p_closed_gpsl_month
    );
$new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'window award: pending-card insert point not found';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END;
$award$;

DO $fix$
DECLARE
  v_f public.competition_fixtures;
  v_sub public.competition_result_submissions;
  v_stats int;
  v_bal_tig numeric;
  v_bal_ars numeric;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = 9406 FOR UPDATE;
  SELECT * INTO v_sub FROM public.competition_result_submissions WHERE id = 238 FOR UPDATE;
  SELECT balance INTO v_bal_tig FROM public."Club_Finances" WHERE club_name = 'TIG' FOR UPDATE;
  SELECT balance INTO v_bal_ars FROM public."Club_Finances" WHERE club_name = 'ARS' FOR UPDATE;

  IF v_f.home_club_short_name IS DISTINCT FROM 'TIG'
     OR v_f.away_club_short_name IS DISTINCT FROM 'ARS'
     OR v_f.home_goals IS DISTINCT FROM 0
     OR v_f.away_goals IS DISTINCT FROM 3
     OR v_f.is_forfeit IS DISTINCT FROM true
     OR v_f.forfeit_loser_club IS DISTINCT FROM 'TIG'
     OR v_f.award_note IS DISTINCT FROM 'Unplayed after play window · September MD7 · awarded on activity'
     OR v_sub.status IS DISTINCT FROM 'rejected'
     OR v_sub.home_goals IS DISTINCT FROM 1
     OR v_sub.away_goals IS DISTINCT FROM 4
     OR v_sub.submitted_by_club IS DISTINCT FROM 'ARS'
     OR jsonb_array_length(v_sub.player_stats) IS DISTINCT FROM 11
  THEN
    RAISE EXCEPTION '9406 is not the expected thrown-away Arsenal card';
  END IF;

  UPDATE public.competition_fixtures
  SET home_goals = 1,
      away_goals = 4,
      is_forfeit = false,
      forfeit_loser_club = NULL,
      is_void = false,
      award_note = 'Score kept from the club that entered it before the cutoff'
  WHERE id = 9406;

  UPDATE public.competition_result_submissions
  SET status = 'confirmed',
      reject_reason = NULL,
      responded_by_club = NULL,
      responded_at = now()
  WHERE id = 238;

  PERFORM public.competition_apply_submission_player_stats(238);

  SELECT count(*) INTO v_stats
  FROM public.competition_match_player_stats m
  WHERE m.fixture_id = 9406 AND m.club_short_name = 'ARS';

  IF v_stats IS DISTINCT FROM 11 THEN
    RAISE EXCEPTION 'Arsenal stats written: %', v_stats;
  END IF;

  IF (SELECT balance FROM public."Club_Finances" WHERE club_name = 'TIG') IS DISTINCT FROM v_bal_tig
     OR (SELECT balance FROM public."Club_Finances" WHERE club_name = 'ARS') IS DISTINCT FROM v_bal_ars
  THEN
    RAISE EXCEPTION 'a club balance changed';
  END IF;

  PERFORM public.owner_inbox_send(
    'result_confirmed',
    'September MD7 score restored',
    E'Tigres UANL vs Arsenal\nArsenal had already entered Tigres 1–4 Arsenal, with their stats. The cutoff awarded the match as unplayed and removed that card. The 1–4 and Arsenal''s stats are restored. Tigres can still add their stats once. Neither club confirmed the other''s card.',
    'TIG', NULL, 9406,
    238, NULL, NULL,
    'matchday.html?fixture=9406',
    'entered_card_restored:9406:home',
    'september', 1, NULL
  );
  PERFORM public.owner_inbox_send(
    'result_confirmed',
    'September MD7 score restored',
    E'Tigres UANL vs Arsenal\nArsenal had already entered Tigres 1–4 Arsenal, with their stats. The cutoff awarded the match as unplayed and removed that card. The 1–4 and Arsenal''s stats are restored. Tigres can still add their stats once. Neither club confirmed the other''s card.',
    'ARS', NULL, 9406,
    238, NULL, NULL,
    'matchday.html?fixture=9406',
    'entered_card_restored:9406:away',
    'september', 1, NULL
  );
END;
$fix$;

SELECT jsonb_build_object(
  'score', f.home_goals || '-' || f.away_goals,
  'forfeit', f.is_forfeit,
  'loser', f.forfeit_loser_club,
  'sub', s.status,
  'arsenal_stats', (
    SELECT count(*) FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9406 AND m.club_short_name = 'ARS'
  ),
  'arsenal_goals', (
    SELECT coalesce(sum(m.goals), 0) FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9406 AND m.club_short_name = 'ARS'
  ),
  'keeps_card', position(
    'entered card kept' IN pg_get_functiondef(
      'public.competition_enforce_scheduling_window_awards(bigint,text)'::regprocedure
    )
  ) > 0
) AS result
FROM public.competition_fixtures f
JOIN public.competition_result_submissions s ON s.id = 238
WHERE f.id = 9406;
