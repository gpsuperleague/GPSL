-- November MD15, fixture 9484: Ajax had entered 4-3 with their stats.
-- A vacant walkover replaced that with Ajax 3-0 Paris and rejected the card.
-- Restore the entered score and Ajax's submitted stats only. No fine, no Discord.

DO $restore$
DECLARE
  v_f public.competition_fixtures;
  v_sub public.competition_result_submissions;
  v_bal_ajx numeric;
  v_bal_pfc numeric;
  v_stats int;
  v_goals int;
  v_expected int;
BEGIN
  PERFORM set_config('statement_timeout', '90s', true);
  PERFORM set_config('gpsl.skip_clinch_scan', 'on', true);
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);
  PERFORM set_config('gpsl.defer_injury_fitness', 'on', true);

  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = 9484 FOR UPDATE;
  SELECT * INTO v_sub FROM public.competition_result_submissions WHERE id = 195 FOR UPDATE;

  IF v_f.home_goals = 4
     AND v_f.away_goals = 3
     AND v_f.is_forfeit = false
     AND v_sub.status = 'confirmed'
  THEN
    RETURN;
  END IF;

  IF v_f.home_club_short_name IS DISTINCT FROM 'AJX'
     OR v_f.away_club_short_name IS DISTINCT FROM 'PFC'
     OR v_f.competition_type IS DISTINCT FROM 'league'
     OR v_f.gpsl_month IS DISTINCT FROM 'november'
     OR v_f.matchday IS DISTINCT FROM 15
     OR v_f.status IS DISTINCT FROM 'played'
     OR v_f.home_goals IS DISTINCT FROM 3
     OR v_f.away_goals IS DISTINCT FROM 0
     OR v_f.is_forfeit IS DISTINCT FROM true
     OR v_f.forfeit_loser_club IS DISTINCT FROM 'PFC'
     OR v_sub.fixture_id IS DISTINCT FROM 9484
     OR v_sub.status IS DISTINCT FROM 'rejected'
     OR v_sub.submitted_by_club IS DISTINCT FROM 'AJX'
     OR v_sub.home_goals IS DISTINCT FROM 4
     OR v_sub.away_goals IS DISTINCT FROM 3
     OR v_sub.reject_reason IS DISTINCT FROM 'Superseded by vacant/absence walkover'
     OR jsonb_array_length(v_sub.player_stats) IS DISTINCT FROM 16
  THEN
    RAISE EXCEPTION '9484 is not the Ajax 3-0 walkover over a rejected 4-3 card';
  END IF;

  SELECT coalesce(sum(coalesce((e->>'goals')::int, 0)), 0)
  INTO v_goals
  FROM jsonb_array_elements(v_sub.player_stats) e;

  IF v_goals IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Ajax card goals sum to %', v_goals;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_sub.player_stats) e
    WHERE NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = trim(both '"' FROM (e->>'player_id'))
        AND p."Contracted_Team" = 'AJX'
    )
  ) THEN
    RAISE EXCEPTION 'a player on the Ajax card is no longer at Ajax';
  END IF;

  SELECT balance INTO v_bal_ajx FROM public."Club_Finances" WHERE club_name = 'AJX' FOR UPDATE;
  SELECT balance INTO v_bal_pfc FROM public."Club_Finances" WHERE club_name = 'PFC' FOR UPDATE;

  UPDATE public.competition_fixtures
  SET home_goals = 4,
      away_goals = 3,
      is_forfeit = false,
      forfeit_loser_club = NULL,
      is_void = false,
      award_note = 'Score kept from the Ajax card entered before the walkover'
  WHERE id = 9484;

  UPDATE public.competition_result_submissions
  SET status = 'confirmed',
      reject_reason = NULL,
      responded_by_club = NULL,
      responded_at = now()
  WHERE id = 195;

  PERFORM public.competition_apply_submission_player_stats(195);

  SELECT count(*) INTO v_expected
  FROM jsonb_array_elements(v_sub.player_stats) e
  WHERE (
      CASE
        WHEN e ? 'started' OR e ? 'subbed_on'
          THEN coalesce((e->>'started')::boolean, false)
            OR coalesce((e->>'subbed_on')::boolean, false)
        ELSE coalesce((e->>'appeared')::boolean, false)
      END
      OR coalesce((e->>'goals')::int, 0) <> 0
      OR coalesce((e->>'assists')::int, 0) <> 0
      OR nullif(e->>'rating', '') IS NOT NULL
      OR coalesce((e->>'potm')::boolean, false)
    )
    AND nullif(trim(both '"' FROM coalesce(e->>'player_id', '')), '') IS NOT NULL;

  SELECT count(*), coalesce(sum(goals), 0)
  INTO v_stats, v_goals
  FROM public.competition_match_player_stats m
  WHERE m.fixture_id = 9484
    AND m.club_short_name = 'AJX';

  IF v_stats IS DISTINCT FROM v_expected OR v_goals IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Ajax stats written % rows, % goals, expected % rows', v_stats, v_goals, v_expected;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9484
      AND m.club_short_name IS DISTINCT FROM 'AJX'
  ) THEN
    RAISE EXCEPTION 'stats were written for a club other than Ajax';
  END IF;

  IF (SELECT balance FROM public."Club_Finances" WHERE club_name = 'AJX') IS DISTINCT FROM v_bal_ajx
     OR (SELECT balance FROM public."Club_Finances" WHERE club_name = 'PFC') IS DISTINCT FROM v_bal_pfc
  THEN
    RAISE EXCEPTION 'a club balance changed';
  END IF;
END;
$restore$;

SELECT jsonb_build_object(
  'score', f.home_goals || '-' || f.away_goals,
  'forfeit', f.is_forfeit,
  'loser', f.forfeit_loser_club,
  'note', f.award_note,
  'card', s.status,
  'ajax_rows', (
    SELECT count(*) FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9484 AND m.club_short_name = 'AJX'
  ),
  'ajax_goals', (
    SELECT coalesce(sum(m.goals), 0) FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9484 AND m.club_short_name = 'AJX'
  ),
  'other_rows', (
    SELECT count(*) FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9484 AND m.club_short_name IS DISTINCT FROM 'AJX'
  )
) AS restored
FROM public.competition_fixtures f
JOIN public.competition_result_submissions s ON s.id = 195
WHERE f.id = 9484;
