-- Match Day: store started vs subbed on (appeared = started OR subbed_on).
-- Run once after competition_phase4_player_stats.sql.

ALTER TABLE public.competition_match_player_stats
  ADD COLUMN IF NOT EXISTS started boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS subbed_on boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.competition_apply_submission_player_stats(
  p_submission_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sub public.competition_result_submissions;
  v_fixture public.competition_fixtures;
  v_item jsonb;
  v_player_id text;
  v_goals int;
  v_assists int;
  v_rating numeric;
  v_potm boolean;
  v_started boolean;
  v_subbed boolean;
  v_appeared boolean;
  v_team_goals int := 0;
  v_expected int;
  v_potm_count int := 0;
BEGIN
  SELECT * INTO v_sub
  FROM public.competition_result_submissions
  WHERE id = p_submission_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_sub.fixture_id;

  DELETE FROM public.competition_match_player_stats
  WHERE fixture_id = v_sub.fixture_id;

  IF v_sub.player_stats IS NULL OR jsonb_typeof(v_sub.player_stats) <> 'array' THEN
    RETURN;
  END IF;

  IF jsonb_array_length(v_sub.player_stats) = 0 THEN
    RETURN;
  END IF;

  v_expected := CASE
    WHEN v_sub.submitted_by_club = v_fixture.home_club_short_name THEN v_sub.home_goals
    ELSE v_sub.away_goals
  END;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_sub.player_stats)
  LOOP
    v_player_id := trim(both '"' FROM (v_item ->> 'player_id'));
    v_goals := coalesce((v_item ->> 'goals')::int, 0);
    v_assists := coalesce((v_item ->> 'assists')::int, 0);
    v_rating := nullif(v_item ->> 'rating', '')::numeric;
    v_potm := coalesce((v_item ->> 'potm')::boolean, false);
    v_started := coalesce((v_item ->> 'started')::boolean, false);
    v_subbed := coalesce((v_item ->> 'subbed_on')::boolean, false);

    IF v_item ? 'started' OR v_item ? 'subbed_on' THEN
      v_appeared := v_started OR v_subbed;
    ELSE
      v_appeared := coalesce((v_item ->> 'appeared')::boolean, false);
    END IF;

    IF v_started AND v_subbed THEN
      RAISE EXCEPTION 'Player % cannot be both started and subbed on', v_player_id;
    END IF;

    IF v_player_id IS NULL OR v_player_id = '' THEN
      CONTINUE;
    END IF;

    IF NOT v_appeared AND v_goals = 0 AND v_assists = 0 AND v_rating IS NULL AND NOT v_potm THEN
      CONTINUE;
    END IF;

    IF v_sub.submitted_by_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
      RAISE EXCEPTION 'Invalid submitter club on submission';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = v_player_id
        AND p."Contracted_Team" = v_sub.submitted_by_club
    ) THEN
      RAISE EXCEPTION 'Player % is not on submitter club roster', v_player_id;
    END IF;

    IF v_potm THEN
      v_potm_count := v_potm_count + 1;
    END IF;

    v_team_goals := v_team_goals + v_goals;

    INSERT INTO public.competition_match_player_stats (
      fixture_id,
      season_id,
      club_short_name,
      player_id,
      appeared,
      started,
      subbed_on,
      goals,
      assists,
      rating,
      is_player_of_match
    )
    VALUES (
      v_fixture.id,
      v_fixture.season_id,
      v_sub.submitted_by_club,
      v_player_id,
      v_appeared,
      v_started,
      v_subbed,
      v_goals,
      v_assists,
      v_rating,
      v_potm
    );
  END LOOP;

  IF v_potm_count > 1 THEN
    RAISE EXCEPTION 'Only one player of the match allowed';
  END IF;

  IF v_team_goals > 0 AND v_team_goals <> v_expected THEN
    RAISE EXCEPTION 'Player goals (%) must match your team score (%)', v_team_goals, v_expected;
  END IF;
END;
$function$;

CREATE OR REPLACE VIEW public.competition_player_season_stats_public
WITH (security_invoker = false)
AS
SELECT
  m.season_id,
  m.player_id,
  p."Name" AS player_name,
  m.club_short_name,
  c."Club" AS club_name,
  ccs.division,
  count(*) FILTER (WHERE m.appeared)::int AS appearances,
  count(*) FILTER (WHERE m.started)::int AS starts,
  count(*) FILTER (WHERE m.subbed_on)::int AS subs,
  coalesce(sum(m.goals), 0)::int AS goals,
  coalesce(sum(m.assists), 0)::int AS assists,
  round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
  count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards
FROM public.competition_match_player_stats m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = m.season_id
JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.season_id = m.season_id AND ccs.club_short_name = m.club_short_name
WHERE s.is_current = true
  AND s.status = 'active'
  AND f.status = 'played'
  AND f.competition_type = 'league'
GROUP BY
  m.season_id,
  m.player_id,
  p."Name",
  m.club_short_name,
  c."Club",
  ccs.division;

GRANT SELECT ON public.competition_player_season_stats_public TO authenticated;
GRANT SELECT ON public.competition_player_season_stats_public TO anon;
