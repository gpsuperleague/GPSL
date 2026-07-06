-- =============================================================================
-- Fix: GPSL Sport in-season edition — "record v_u is not assigned yet" on month end
-- Run once in Supabase SQL Editor (after gpsl_sport_may_preseason.sql).
-- Also re-run competition_admin_end_gpsl_month.sql for month-end error resilience.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_inseason_edition(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_existing bigint;
  v_month_label text;
  v_club_count int;
  v_story_type text := 'roundup';
  v_story_score numeric := 0;
  v_seed text;
  v_vars jsonb;
  v_headline text;
  v_subhead text;
  v_lead text;
  v_stories jsonb := '[]'::jsonb;
  v_front jsonb;
  v_back jsonb := jsonb_build_object('enabled', false);
  v_f record;
  v_u record;
  v_winner text;
  v_loser text;
  v_winner_name text;
  v_loser_name text;
  v_score text;
  v_division text;
  v_tpl text;
  v_headlines text[];
  v_bodies text[];
  v_subheads text[];
  v_win int;
  v_lose int;
  v_gap int;
  v_shock numeric;
  v_cal record;
  v_transfer record;
  v_transfer_stories jsonb := '[]'::jsonb;
  v_player_name text;
  v_player_rating int;
  v_goals int;
  v_assists int;
  v_seller_name text;
  v_buyer_name text;
  v_fee text;
  v_i int := 0;
  v_pressure_club text;
  v_pressure_pts int;
  v_pressure_position int;
BEGIN
  IF p_season_id IS NULL OR p_gpsl_month IS NULL OR btrim(p_gpsl_month) = '' THEN
    RETURN NULL;
  END IF;

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND e.gpsl_month = p_gpsl_month;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_month_label := public.gpsl_sport_month_label(p_gpsl_month);

  SELECT count(DISTINCT ccs.club_short_name)::int INTO v_club_count
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = p_season_id;

  FOR v_f IN
    SELECT
      f.id,
      f.home_club_short_name,
      f.away_club_short_name,
      f.home_goals,
      f.away_goals,
      f.division,
      f.cup_code,
      f.competition_type,
      ph.prestige_rank AS home_prestige,
      pa.prestige_rank AS away_prestige
    FROM public.competition_fixtures f
    LEFT JOIN public.competition_club_prestige_public ph
      ON ph.club_short_name = f.home_club_short_name
    LEFT JOIN public.competition_club_prestige_public pa
      ON pa.club_short_name = f.away_club_short_name
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
  LOOP
    IF v_f.home_goals > v_f.away_goals THEN
      v_winner := v_f.home_club_short_name;
      v_loser := v_f.away_club_short_name;
      v_win := v_f.home_goals;
      v_lose := v_f.away_goals;
      v_gap := coalesce(v_f.away_prestige, 99) - coalesce(v_f.home_prestige, 99);
    ELSIF v_f.away_goals > v_f.home_goals THEN
      v_winner := v_f.away_club_short_name;
      v_loser := v_f.home_club_short_name;
      v_win := v_f.away_goals;
      v_lose := v_f.home_goals;
      v_gap := coalesce(v_f.home_prestige, 99) - coalesce(v_f.away_prestige, 99);
    ELSE
      CONTINUE;
    END IF;

    v_shock := greatest(0, v_gap) * greatest(1, v_win - v_lose + 1);
    IF coalesce(v_f.competition_type, 'league') = 'cup' OR v_f.cup_code IS NOT NULL THEN
      v_shock := v_shock + 5;
    END IF;

    IF v_shock > v_story_score THEN
      v_story_score := v_shock;
      v_story_type := CASE
        WHEN coalesce(v_f.competition_type, 'league') = 'cup' OR v_f.cup_code IS NOT NULL THEN 'cup_upset'
        ELSE 'shock_result'
      END;
      v_winner_name := public.gpsl_sport_club_display_name(v_winner);
      v_loser_name := public.gpsl_sport_club_display_name(v_loser);
      v_score := v_win::text || '–' || v_lose::text;
      v_division := public.gpsl_sport_fixture_division_label(v_f.division, v_f.cup_code, v_f.competition_type);
    END IF;
  END LOOP;

  IF v_story_type <> 'cup_upset' AND v_story_score < 50 THEN
    FOR v_u IN
      SELECT
        ccs.club_short_name,
        ccs.division,
        s.table_position,
        s.pts,
        coalesce(pr.manager_rating, 70) AS mgr_rating
      FROM public.competition_club_seasons ccs
      JOIN public.competition_standings_public s
        ON s.season_id = ccs.season_id AND s.club_short_name = ccs.club_short_name
      LEFT JOIN public.competition_club_prestige_public pr
        ON pr.club_short_name = ccs.club_short_name
      WHERE ccs.season_id = p_season_id
        AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      ORDER BY s.pts ASC, s.table_position DESC
      LIMIT 5
    LOOP
      IF coalesce(v_u.mgr_rating, 70) >= 80 AND coalesce(v_u.pts, 0) <= 8 THEN
        v_story_score := 50;
        v_story_type := 'manager_pressure';
        v_winner := v_u.club_short_name;
        v_pressure_club := v_u.club_short_name;
        v_pressure_pts := v_u.pts;
        v_pressure_position := v_u.table_position;
        v_winner_name := public.gpsl_sport_club_display_name(v_u.club_short_name);
        v_division := public.gpsl_sport_fixture_division_label(v_u.division, NULL, 'league');
        EXIT;
      END IF;
    END LOOP;
  END IF;

  v_seed := p_season_id::text || ':' || p_gpsl_month || ':' || v_story_type;
  v_vars := jsonb_build_object(
    'winner', coalesce(v_winner_name, 'GPSL'),
    'loser', coalesce(v_loser_name, ''),
    'score', coalesce(v_score, ''),
    'division', coalesce(v_division, 'League'),
    'month', v_month_label
  );

  IF v_story_type = 'shock_result' THEN
    v_headlines := ARRAY[
      'SHOCK IN {{DIVISION}}: {{LOSER}} FALL TO {{WINNER}}',
      '{{WINNER}} STUN {{LOSER}} IN {{SCORE}} {{DIVISION}} UPSET',
      '{{LOSER}} LEFT REELING AFTER {{SCORE}} DEFEAT TO {{WINNER}}'
    ];
    v_subheads := ARRAY[
      'Prestige gap makes result all the more remarkable',
      'GPSL Sport names the scoreline of the month'
    ];
    v_bodies := ARRAY[
      E'{{WINNER}} pulled off the result of {{MONTH}} with a {{SCORE}} victory over {{LOSER}} in the {{DIVISION}}.\n\nThe GPSL table does not lie — but sometimes it is turned on its head.',
      E'Few saw this coming. {{WINNER}}''s {{SCORE}} win over {{LOSER}} sent shockwaves through the {{DIVISION}} and dominated inbox chatter across the league.'
    ];
  ELSIF v_story_type = 'cup_upset' THEN
    v_headlines := ARRAY[
      'CUP SHOCK: {{WINNER}} ELIMINATE {{LOSER}}',
      '{{WINNER}} PULL OFF CUP UPSET AGAINST {{LOSER}}'
    ];
    v_subheads := ARRAY['Knockout football at its cruellest', 'Giant-killing headline act'];
    v_bodies := ARRAY[
      E'{{WINNER}} knocked out {{LOSER}} in the cups with a {{SCORE}} scoreline that will live long in GPSL folklore.',
      E'The cups delivered again. {{WINNER}}''s {{SCORE}} defeat of {{LOSER}} was the story {{MONTH}} needed.'
    ];
  ELSIF v_story_type = 'manager_pressure' AND v_pressure_club IS NOT NULL THEN
    v_headlines := ARRAY[
      'MANAGER UNDER PRESSURE: {{WINNER}} FLOUNDER IN {{MONTH}}',
      '{{WINNER}} OWNER FACING QUESTIONS AFTER POOR {{MONTH}}'
    ];
    v_subheads := ARRAY['Points tally nowhere near expectation', 'Prestige club in the relegation conversation'];
    v_bodies := ARRAY[
      E'{{WINNER}} sit on just {{POINTS}} points — far below what their squad prestige promised. {{MONTH}} was another month of frustration for one of the GPSL''s biggest clubs.',
      E'Expectation versus reality: {{WINNER}} are {{POSITION}} in the table with {{POINTS}} points. Patience is wearing thin.'
    ];
    v_vars := v_vars || jsonb_build_object(
      'winner', v_winner_name,
      'points', coalesce(v_pressure_pts::text, '0'),
      'position', coalesce(v_pressure_position::text, '')
    );
  ELSE
    v_story_type := 'roundup';
    v_headlines := ARRAY[
      '{{MONTH}} GPSL ROUND-UP: TABLE STILL WIDE OPEN',
      'ANOTHER DRAMATIC MONTH IN GPSL FOOTBALL'
    ];
    v_subheads := ARRAY['Fixtures, fines and inbox drama across the league'];
    v_bodies := ARRAY[
      E'{{MONTH}} is in the books and the GPSL rolls on. Results across SuperLeague and the Championships reshaped the table.',
      E'From shock scorelines to late check-ins, {{MONTH}} had it all.'
    ];
    v_vars := jsonb_build_object('month', v_month_label, 'division', 'GPSL');
  END IF;

  v_headline := public.gpsl_sport_apply_template(
    public.gpsl_sport_pick_template(v_seed || ':h', v_headlines), v_vars);
  v_subhead := public.gpsl_sport_apply_template(
    public.gpsl_sport_pick_template(v_seed || ':s', v_subheads), v_vars);
  v_lead := public.gpsl_sport_apply_template(
    public.gpsl_sport_pick_template(v_seed || ':b', v_bodies), v_vars);

  FOR v_f IN
    SELECT f.home_club_short_name, f.away_club_short_name, f.home_goals, f.away_goals,
           f.division, f.cup_code, f.competition_type
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id AND f.gpsl_month = p_gpsl_month AND f.status = 'played'
    ORDER BY (coalesce(f.home_goals, 0) + coalesce(f.away_goals, 0)) DESC, f.id
    LIMIT 4
  LOOP
    EXIT WHEN jsonb_array_length(v_stories) >= 3;
    v_division := public.gpsl_sport_fixture_division_label(v_f.division, v_f.cup_code, v_f.competition_type);
    v_stories := v_stories || jsonb_build_array(jsonb_build_object(
      'kicker', v_division,
      'headline', public.gpsl_sport_club_display_name(v_f.home_club_short_name)
        || ' ' || coalesce(v_f.home_goals, 0)::text || '–' || coalesce(v_f.away_goals, 0)::text
        || ' ' || public.gpsl_sport_club_display_name(v_f.away_club_short_name),
      'body', format('Full-time in %s on a busy %s matchday.', v_division, v_month_label),
      'club_short', v_f.home_club_short_name
    ));
  END LOOP;

  v_front := jsonb_build_object(
    'masthead', 'GPSL Sport',
    'edition_label', v_month_label,
    'gpsl_month', p_gpsl_month,
    'headline', v_headline,
    'subhead', v_subhead,
    'lead_paragraph', v_lead,
    'stories', v_stories,
    'story_type', v_story_type,
    'hero', CASE
      WHEN v_winner IS NOT NULL AND v_story_type IN ('shock_result', 'cup_upset') THEN jsonb_build_object(
        'kind', 'stadium',
        'club_short', v_winner,
        'caption', coalesce(v_winner_name, 'GPSL') || ' — ' || coalesce(v_score, '') || ' headline'
      )
      WHEN v_story_type = 'manager_pressure' AND v_winner_name IS NOT NULL THEN jsonb_build_object(
        'kind', 'stadium',
        'club_short', coalesce(v_winner, v_pressure_club),
        'caption', v_winner_name || ' under the microscope'
      )
      ELSE jsonb_build_object('kind', 'generic', 'caption', v_month_label || ' round-up')
    END
  );

  SELECT c.unlock_at, c.lock_at INTO v_cal
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND c.gpsl_month = p_gpsl_month;

  IF v_cal.unlock_at IS NOT NULL AND v_cal.lock_at IS NOT NULL THEN
    FOR v_transfer IN
      SELECT h.id, h.player_id, h.seller_club_id, h.buyer_club_id, h.fee, h.transfer_time,
             p."Name" AS player_name, nullif(btrim(p."Rating"::text), '')::int AS rating
      FROM public."Transfer_History" h
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
      WHERE h.transfer_time >= v_cal.unlock_at AND h.transfer_time < v_cal.lock_at
        AND coalesce(h.buyer_club_id, '') <> '' AND h.buyer_club_id <> 'FOREIGN'
        AND coalesce(h.fee, 0) > 0
      ORDER BY h.fee DESC NULLS LAST, h.transfer_time DESC
      LIMIT 9
    LOOP
      v_i := v_i + 1;
      v_player_name := coalesce(v_transfer.player_name, 'Unknown player');
      v_player_rating := coalesce(v_transfer.rating, 0);
      v_seller_name := public.gpsl_sport_club_display_name(v_transfer.seller_club_id);
      v_buyer_name := public.gpsl_sport_club_display_name(v_transfer.buyer_club_id);
      v_fee := public.gpsl_sport_format_fee(v_transfer.fee);
      IF v_i = 1 THEN
        v_back := jsonb_build_object(
          'enabled', true,
          'page_title', 'Transfer special',
          'lead', jsonb_build_object(
            'headline', v_buyer_name || ' sign ' || v_player_name || ' (' || v_fee || ')',
            'body', format('%s completed the signing of %s from %s for %s in %s.',
              v_buyer_name, v_player_name, v_seller_name, v_fee, v_month_label)
          ),
          'stories', '[]'::jsonb
        );
      ELSE
        v_transfer_stories := v_transfer_stories || jsonb_build_array(jsonb_build_object(
          'headline', v_buyer_name || ' sign ' || v_player_name || ' (' || v_fee || ')',
          'body', format('Rated %s. Arrives from %s.', v_player_rating, v_seller_name)
        ));
      END IF;
    END LOOP;
    IF (v_back->>'enabled')::boolean IS TRUE THEN
      v_back := v_back || jsonb_build_object('stories', v_transfer_stories);
    END IF;
  END IF;

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id, p_gpsl_month, v_month_label, v_story_type, v_front, v_back,
    jsonb_build_object('story_score', v_story_score, 'generated_at', now())
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

NOTIFY pgrst, 'reload schema';
