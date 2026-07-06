-- =============================================================================
-- GPSL Sport — May season review + June/July pre-season editions
-- Run after gpsl_sport_phase1.sql
-- Safe to re-run (CREATE OR REPLACE).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Calendar helpers (June/July sit outside competition_season_calendar)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_sport_month_label(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(p_month))
    WHEN 'june' THEN 'June'
    WHEN 'july' THEN 'July'
    ELSE public.competition_gpsl_month_label(p_month)
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_edition_sort_key(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(p_month))
    WHEN 'june' THEN 0
    WHEN 'july' THEN 1
    WHEN 'august' THEN 2
    WHEN 'september' THEN 3
    WHEN 'october' THEN 4
    WHEN 'november' THEN 5
    WHEN 'december' THEN 6
    WHEN 'january' THEN 7
    WHEN 'february' THEN 8
    WHEN 'march' THEN 9
    WHEN 'april' THEN 10
    WHEN 'may' THEN 11
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_is_preseason_month(p_month text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(p_month)) IN ('june', 'july');
$$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_preseason_window(p_season_id bigint)
RETURNS TABLE (
  august_start timestamptz,
  may_end timestamptz,
  preseason_start timestamptz,
  preseason_weeks numeric,
  june_window_start timestamptz,
  june_window_end timestamptz,
  july_window_start timestamptz,
  july_window_end timestamptz,
  publish_june_at timestamptz,
  publish_july_at timestamptz,
  include_june boolean,
  include_july boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_august timestamptz;
  v_may timestamptz;
  v_start timestamptz;
  v_mid timestamptz;
  v_weeks numeric;
BEGIN
  SELECT cfg.anchor_unlock_at INTO v_august
  FROM public.competition_season_calendar_config cfg
  WHERE cfg.season_id = p_season_id;

  IF v_august IS NULL THEN
    RETURN;
  END IF;

  SELECT c.lock_at INTO v_may
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = 'may'
  LIMIT 1;

  v_start := coalesce(v_may, v_august - interval '8 weeks');
  v_mid := v_start + ((v_august - v_start) / 2.0);
  v_weeks := greatest(0, extract(epoch FROM (v_august - v_start)) / 604800.0);

  august_start := v_august;
  may_end := v_may;
  preseason_start := v_start;
  preseason_weeks := round(v_weeks::numeric, 2);

  include_june := v_weeks >= 5;
  include_july := true;

  IF include_june THEN
    publish_june_at := v_start;
    publish_july_at := v_august - interval '4 weeks';
    june_window_start := v_start;
    june_window_end := v_mid;
    july_window_start := v_mid;
    july_window_end := v_august;
  ELSE
    publish_june_at := NULL;
    publish_july_at := v_start;
    june_window_start := NULL;
    june_window_end := NULL;
    july_window_start := v_start;
    july_window_end := v_august;
  END IF;

  RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Shared transfer back-page builder
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_transfer_edition(
  p_seed text,
  p_month_label text,
  p_window_start timestamptz,
  p_window_end timestamptz,
  p_preseason boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_front jsonb;
  v_back jsonb := jsonb_build_object('enabled', false);
  v_transfer record;
  v_transfer_stories jsonb := '[]'::jsonb;
  v_i int := 0;
  v_player_name text;
  v_player_rating int;
  v_seller_name text;
  v_buyer_name text;
  v_fee text;
  v_goals int;
  v_assists int;
  v_tpl text;
  v_lead_headline text;
  v_lead_body text;
  v_top_fee numeric := 0;
  v_top_buyer text;
  v_top_player text;
  v_xfer_count int := 0;
BEGIN
  IF p_window_start IS NULL OR p_window_end IS NULL OR p_window_end <= p_window_start THEN
    v_front := jsonb_build_object(
      'masthead', 'GPSL Sport',
      'edition_label', p_month_label,
      'headline', format('GPSL Sport — %s pre-season quiet so far', p_month_label),
      'subhead', 'Owners hold their nerve as August approaches',
      'lead_paragraph', format(
        E'The %s window has been subdued on the transfer front. With the new GPSL campaign around the corner, clubs are still weighing their moves.\n\nGPSL Sport will track every deal as pre-season builds.',
        p_month_label
      ),
      'stories', '[]'::jsonb,
      'story_type', CASE WHEN p_preseason THEN 'preseason_quiet' ELSE 'transfer_quiet' END
    );
    RETURN jsonb_build_object('front_page', v_front, 'back_page', v_back, 'story_type', v_front->>'story_type');
  END IF;

  FOR v_transfer IN
    SELECT
      h.id,
      h.player_id,
      h.seller_club_id,
      h.buyer_club_id,
      h.fee,
      h.transfer_time,
      p."Name" AS player_name,
      nullif(btrim(p."Rating"::text), '')::int AS rating
    FROM public."Transfer_History" h
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
    WHERE h.transfer_time >= p_window_start
      AND h.transfer_time < p_window_end
      AND coalesce(h.buyer_club_id, '') <> ''
      AND h.buyer_club_id <> 'FOREIGN'
      AND coalesce(h.fee, 0) > 0
    ORDER BY h.fee DESC NULLS LAST, h.transfer_time DESC
    LIMIT 9
  LOOP
    v_i := v_i + 1;
    v_xfer_count := v_xfer_count + 1;
    v_player_name := coalesce(v_transfer.player_name, 'Unknown player');
    v_player_rating := coalesce(v_transfer.rating, 0);
    v_seller_name := public.gpsl_sport_club_display_name(v_transfer.seller_club_id);
    v_buyer_name := public.gpsl_sport_club_display_name(v_transfer.buyer_club_id);
    v_fee := public.gpsl_sport_format_fee(v_transfer.fee);

    IF v_i = 1 THEN
      v_top_fee := coalesce(v_transfer.fee, 0);
      v_top_buyer := v_buyer_name;
      v_top_player := v_player_name;
    END IF;

    SELECT coalesce(ps.goals, 0), coalesce(ps.assists, 0)
    INTO v_goals, v_assists
    FROM public.competition_player_season_stats_public ps
    WHERE ps.player_id = v_transfer.player_id::text
      AND ps.club_short_name = v_transfer.seller_club_id
    LIMIT 1;

    IF v_i = 1 THEN
      v_tpl := public.gpsl_sport_pick_template(
        p_seed || ':xfer',
        ARRAY[
          E'{{BUYER}} SPLASH {{FEE}} ON {{PLAYER}}',
          E'BLOCKBUSTER DEAL: {{PLAYER}} HEADS TO {{BUYER}} FOR {{FEE}}',
          E'{{BUYER}} LEAD {{MONTH}} SPENDING WITH {{FEE}} MOVE FOR {{PLAYER}}'
        ]
      );
      v_lead_headline := public.gpsl_sport_apply_template(v_tpl, jsonb_build_object(
        'buyer', v_buyer_name,
        'seller', v_seller_name,
        'player', v_player_name,
        'fee', v_fee,
        'month', p_month_label
      ));
      v_lead_body := format(
        E'%s completed the headline signing of %s (rated %s) from %s for %s during %s.\n\nPre-season is about building the squad — and this is the deal everyone is talking about.',
        v_buyer_name,
        v_player_name,
        v_player_rating,
        v_seller_name,
        v_fee,
        p_month_label
      );
      v_back := jsonb_build_object(
        'enabled', true,
        'page_title', 'Transfer special',
        'lead', jsonb_build_object('headline', v_lead_headline, 'body', v_lead_body),
        'stories', '[]'::jsonb
      );
    ELSE
      v_transfer_stories := v_transfer_stories || jsonb_build_array(
        jsonb_build_object(
          'headline', v_buyer_name || ' sign ' || v_player_name || ' (' || v_fee || ')',
          'body', format(
            'Rated %s. Arrives from %s with %s goals and %s assists in GPSL competition.',
            v_player_rating,
            v_seller_name,
            coalesce(v_goals, 0),
            coalesce(v_assists, 0)
          )
        )
      );
    END IF;
  END LOOP;

  IF v_xfer_count = 0 THEN
    v_front := jsonb_build_object(
      'masthead', 'GPSL Sport',
      'edition_label', p_month_label,
      'headline', format('%s PRE-SEASON: OWNERS PLAY THE WAITING GAME', upper(p_month_label)),
      'subhead', 'No major fees yet as clubs plan for the new campaign',
      'lead_paragraph', format(
        E'GPSL Sport''s %s edition finds the market calm. With August on the horizon, squads are taking shape through smaller moves and internal promotion rather than blockbuster fees.\n\nThe back page will fill up soon enough — pre-season never stays quiet for long.',
        p_month_label
      ),
      'stories', '[]'::jsonb,
      'story_type', 'preseason_quiet'
    );
    RETURN jsonb_build_object('front_page', v_front, 'back_page', v_back, 'story_type', 'preseason_quiet');
  END IF;

  v_front := jsonb_build_object(
    'masthead', 'GPSL Sport',
    'edition_label', p_month_label,
    'headline', public.gpsl_sport_pick_template(
      p_seed || ':h',
      ARRAY[
        format('%s PRE-SEASON: TRANSFER MARKET HEATS UP', upper(p_month_label)),
        format('%s WINDOW — %s LEAD THE SPENDERS', upper(p_month_label), v_top_buyer),
        format('DEALS, DEALS, DEALS: %s PRE-SEASON SPECIAL', upper(p_month_label))
      ]
    ),
    'subhead', format('%s completed transfer moves tracked by GPSL Sport', v_xfer_count),
    'lead_paragraph', format(
      E'Performance can wait — %s is about building squads. %s set the pace with a %s move for %s, but they were far from alone.\n\nTurn to the back page for every significant deal of the window so far.',
      p_month_label,
      v_top_buyer,
      public.gpsl_sport_format_fee(v_top_fee),
      v_top_player
    ),
    'stories', '[]'::jsonb,
    'story_type', 'preseason_transfers'
  );

  IF (v_back->>'enabled')::boolean IS TRUE THEN
    v_back := v_back || jsonb_build_object('stories', v_transfer_stories);
  END IF;

  RETURN jsonb_build_object('front_page', v_front, 'back_page', v_back, 'story_type', 'preseason_transfers');
END;
$function$;

-- ---------------------------------------------------------------------------
-- May — end-of-season review
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_may_edition(p_season_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_existing bigint;
  v_month_label text := 'May';
  v_seed text;
  v_front jsonb;
  v_back jsonb := jsonb_build_object('enabled', false);
  v_stories jsonb := '[]'::jsonb;
  v_champion text;
  v_champion_name text;
  v_story record;
  v_award record;
  v_cup record;
  v_club_player record;
  v_headline text;
  v_subhead text;
  v_lead text;
  v_lines text[] := ARRAY[]::text[];
  v_promoted text := '';
  v_relegated text := '';
  v_cup_lines text := '';
  v_award_lines text := '';
  v_season_label text;
BEGIN
  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND e.gpsl_month = 'may';

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT s.label INTO v_season_label
  FROM public.competition_seasons s
  WHERE s.id = p_season_id;

  v_seed := p_season_id::text || ':may:season_review';

  SELECT a.club_short_name, public.gpsl_sport_club_display_name(a.club_short_name)
  INTO v_champion, v_champion_name
  FROM public.competition_club_season_archive a
  WHERE a.season_id = p_season_id
    AND a.division = 'superleague'
    AND a.final_position = 1
  LIMIT 1;

  IF v_champion IS NULL THEN
    SELECT s.club_short_name, public.gpsl_sport_club_display_name(s.club_short_name)
    INTO v_champion, v_champion_name
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id
      AND s.division = 'superleague'
      AND s.table_position = 1
    LIMIT 1;
  END IF;

  SELECT string_agg(public.gpsl_sport_club_display_name(x.club_short_name), ', ' ORDER BY x.division, x.final_position)
  INTO v_promoted
  FROM public.competition_club_season_archive x
  WHERE x.season_id = p_season_id
    AND x.division IN ('championship_a', 'championship_b')
    AND x.final_position <= 2;

  IF v_promoted IS NULL THEN
    SELECT string_agg(public.gpsl_sport_club_display_name(x.club_short_name), ', ' ORDER BY x.division, x.table_position)
    INTO v_promoted
    FROM public.competition_standings_public x
    WHERE x.season_id = p_season_id
      AND x.division IN ('championship_a', 'championship_b')
      AND x.table_position <= 2;
  END IF;

  SELECT string_agg(
    public.gpsl_sport_club_display_name(x.club_short_name) || ' (' || x.final_position::text || 'th)',
    ', ' ORDER BY x.final_position DESC
  )
  INTO v_relegated
  FROM public.competition_club_season_archive x
  WHERE x.season_id = p_season_id
    AND x.division = 'superleague'
    AND x.final_position >= 17;

  IF v_relegated IS NULL THEN
    SELECT string_agg(
      public.gpsl_sport_club_display_name(x.club_short_name) || ' (' || x.table_position::text || 'th)',
      ', ' ORDER BY x.table_position DESC
    )
    INTO v_relegated
    FROM public.competition_standings_public x
    WHERE x.season_id = p_season_id
      AND x.division = 'superleague'
      AND x.table_position >= 17;
  END IF;

  FOR v_cup IN
    SELECT w.cup_code, public.gpsl_sport_club_display_name(w.winner_club_short_name) AS winner_name
    FROM public.competition_cup_season_winner w
    WHERE w.season_id = p_season_id
    ORDER BY w.cup_code
  LOOP
    v_cup_lines := v_cup_lines || CASE WHEN v_cup_lines = '' THEN '' ELSE E'\n' END
      || initcap(replace(v_cup.cup_code, '_', ' ')) || ': ' || v_cup.winner_name;
  END LOOP;

  FOR v_award IN
    SELECT
      a.award_type,
      a.stat_value,
      p."Name" AS player_name,
      public.gpsl_sport_club_display_name(a.club_short_name) AS club_name
    FROM public.competition_season_award a
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = a.player_id
    WHERE a.season_id = p_season_id
      AND a.award_type IN (
        'ballon_dor',
        'golden_boot',
        'golden_playmaker',
        'golden_glove',
        'championship_player_of_season',
        'season_potm'
      )
    ORDER BY CASE a.award_type
      WHEN 'ballon_dor' THEN 1
      WHEN 'championship_player_of_season' THEN 2
      WHEN 'golden_boot' THEN 3
      WHEN 'golden_playmaker' THEN 4
      WHEN 'golden_glove' THEN 5
      ELSE 9
    END
  LOOP
    v_award_lines := v_award_lines || CASE WHEN v_award_lines = '' THEN '' ELSE E'\n' END
      || replace(initcap(replace(v_award.award_type, '_', ' ')), 'Championship Player Of Season', 'Championship Player of the Season')
      || ': ' || coalesce(v_award.player_name, 'TBC')
      || ' (' || coalesce(v_award.club_name, 'GPSL') || ') — ' || v_award.stat_value::text;
  END LOOP;

  v_headline := CASE
    WHEN v_champion_name IS NOT NULL THEN v_champion_name || ' CROWNED GPSL CHAMPIONS'
    ELSE 'SEASON REVIEW: MAY EDITION'
  END;

  v_subhead := coalesce(v_season_label, 'GPSL') || ' honours, heartbreak and history';

  v_lead := concat_ws(
    E'\n\n',
    CASE WHEN v_champion_name IS NOT NULL THEN
      format('%s finish top of the SuperLeague to lift the title. The May edition of GPSL Sport wraps the campaign.', v_champion_name)
    ELSE
      'Another GPSL season reaches its conclusion. GPSL Sport reviews the month that settled the table.'
    END,
    CASE WHEN coalesce(v_promoted, '') <> '' THEN 'Promoted: ' || v_promoted ELSE NULL END,
    CASE WHEN coalesce(v_relegated, '') <> '' THEN 'Relegated from SuperLeague: ' || v_relegated ELSE NULL END,
    CASE WHEN coalesce(v_cup_lines, '') <> '' THEN E'Cup winners:\n' || v_cup_lines ELSE NULL END,
    CASE WHEN coalesce(v_award_lines, '') <> '' THEN E'Season awards:\n' || v_award_lines ELSE NULL END
  );

  FOR v_story IN
    SELECT
      ps.player_id,
      ps.club_short_name,
      p."Name" AS player_name,
      public.gpsl_sport_club_display_name(ps.club_short_name) AS club_name,
      ps.goals,
      ps.assists
    FROM public.competition_player_season_archive ps
    JOIN public."Players" p ON p."Konami_ID"::text = ps.player_id
    WHERE ps.season_id = p_season_id
    ORDER BY ps.goals DESC NULLS LAST, ps.assists DESC NULLS LAST
    LIMIT 3
  LOOP
    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'kicker', 'Golden boot race',
        'headline', v_story.player_name || ' — ' || coalesce(v_story.goals, 0)::text || ' goals',
        'body', format('%s for %s (%s assists).', v_story.player_name, v_story.club_name, coalesce(v_story.assists, 0)),
        'player_id', v_story.player_id,
        'club_short', v_story.club_short_name
      )
    );
  END LOOP;

  FOR v_club_player IN
    SELECT DISTINCT ON (ps.club_short_name)
      ps.club_short_name,
      ps.player_id,
      public.gpsl_sport_club_display_name(ps.club_short_name) AS club_name,
      p."Name" AS player_name,
      ps.ballon_points
    FROM public.competition_player_season_archive ps
    JOIN public."Players" p ON p."Konami_ID"::text = ps.player_id
    WHERE ps.season_id = p_season_id
    ORDER BY ps.club_short_name, ps.ballon_points DESC NULLS LAST, ps.goals DESC NULLS LAST
    LIMIT 6
  LOOP
    EXIT WHEN jsonb_array_length(v_stories) >= 6;
    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'kicker', 'Club player of the season',
        'headline', v_club_player.club_name || ': ' || v_club_player.player_name,
        'body', format('Stand-out performer at %s on Ballon points.', v_club_player.club_name),
        'player_id', v_club_player.player_id,
        'club_short', v_club_player.club_short_name
      )
    );
  END LOOP;

  v_front := jsonb_build_object(
    'masthead', 'GPSL Sport',
    'edition_label', v_month_label,
    'gpsl_month', 'may',
    'headline', v_headline,
    'subhead', v_subhead,
    'lead_paragraph', v_lead,
    'stories', v_stories,
    'story_type', 'season_review',
    'hero', CASE
      WHEN v_champion IS NOT NULL THEN jsonb_build_object(
        'kind', 'champion',
        'club_short', v_champion,
        'trophy', 'superleague',
        'caption', coalesce(v_champion_name, 'GPSL') || ' — SuperLeague champions'
      )
      ELSE jsonb_build_object('kind', 'generic', 'caption', 'Season review')
    END
  );

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    'may',
    v_month_label,
    'season_review',
    v_front,
    v_back,
    jsonb_build_object('generated_at', now(), 'season_label', v_season_label, 'champion_club_short', v_champion)
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

-- ---------------------------------------------------------------------------
-- June / July — pre-season transfer focus
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_preseason_edition(
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
  v_month text := lower(btrim(p_gpsl_month));
  v_month_label text;
  v_win record;
  v_built jsonb;
  v_seed text;
BEGIN
  IF v_month NOT IN ('june', 'july') THEN
    RETURN NULL;
  END IF;

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND e.gpsl_month = v_month;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_win
  FROM public.gpsl_sport_preseason_window(p_season_id);

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_month = 'june' AND NOT coalesce(v_win.include_june, false) THEN
    RETURN NULL;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_seed := p_season_id::text || ':' || v_month || ':preseason';

  v_built := public.gpsl_sport_build_transfer_edition(
    v_seed,
    v_month_label,
    CASE WHEN v_month = 'june' THEN v_win.june_window_start ELSE v_win.july_window_start END,
    CASE WHEN v_month = 'june' THEN v_win.june_window_end ELSE v_win.july_window_end END,
    true
  );

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    v_month,
    v_month_label,
    v_built->>'story_type',
    v_built->'front_page',
    coalesce(v_built->'back_page', '{}'::jsonb),
    jsonb_build_object(
      'generated_at', now(),
      'preseason', true,
      'preseason_weeks', v_win.preseason_weeks
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Dispatcher — route May / June / July before in-season logic
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_edition(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(p_gpsl_month));
BEGIN
  IF p_season_id IS NULL OR v_month IS NULL OR v_month = '' THEN
    RETURN NULL;
  END IF;

  IF v_month IN ('june', 'july') THEN
    RETURN public.gpsl_sport_generate_preseason_edition(p_season_id, v_month);
  END IF;

  IF v_month = 'may' THEN
    RETURN public.gpsl_sport_generate_may_edition(p_season_id);
  END IF;

  -- In-season months (august–april): delegate to legacy body via a renamed copy.
  RETURN public.gpsl_sport_generate_inseason_edition(p_season_id, v_month);
END;
$function$;

-- Preserve existing in-season generator under a new name (same logic as phase1).
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

-- ---------------------------------------------------------------------------
-- Auto-publish: in-season locks + pre-season June/July
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_sport_process_pending_editions(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_win record;
  v_job_key text;
  v_id bigint;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'gpsl_sport:' || v_cal.gpsl_month;
    IF EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_id := public.gpsl_sport_generate_edition(p_season_id, v_cal.gpsl_month);

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id, v_job_key, v_cal.gpsl_month,
      jsonb_build_object('edition_id', v_id, 'ok', v_id IS NOT NULL)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object('gpsl_month', v_cal.gpsl_month, 'edition_id', v_id)
    );
  END LOOP;

  SELECT * INTO v_win FROM public.gpsl_sport_preseason_window(p_season_id);

  IF FOUND AND now() < v_win.august_start THEN
    IF coalesce(v_win.include_june, false) AND now() >= v_win.publish_june_at THEN
      v_job_key := 'gpsl_sport:june';
      IF NOT EXISTS (
        SELECT 1 FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = p_season_id AND j.job_key = v_job_key
      ) THEN
        v_id := public.gpsl_sport_generate_edition(p_season_id, 'june');
        INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
        VALUES (p_season_id, v_job_key, 'june', jsonb_build_object('edition_id', v_id, 'ok', v_id IS NOT NULL))
        ON CONFLICT (season_id, job_key) DO UPDATE SET result = excluded.result, ran_at = now();
        v_results := v_results || jsonb_build_array(jsonb_build_object('gpsl_month', 'june', 'edition_id', v_id));
      END IF;
    END IF;

    IF coalesce(v_win.include_july, false) AND now() >= v_win.publish_july_at THEN
      v_job_key := 'gpsl_sport:july';
      IF NOT EXISTS (
        SELECT 1 FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = p_season_id AND j.job_key = v_job_key
      ) THEN
        v_id := public.gpsl_sport_generate_edition(p_season_id, 'july');
        INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
        VALUES (p_season_id, v_job_key, 'july', jsonb_build_object('edition_id', v_id, 'ok', v_id IS NOT NULL))
        ON CONFLICT (season_id, job_key) DO UPDATE SET result = excluded.result, ran_at = now();
        v_results := v_results || jsonb_build_array(jsonb_build_object('gpsl_month', 'july', 'edition_id', v_id));
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'processed', v_results);
END;
$function$;

-- Sort editions in newspaper order (June → July → Aug … → May)
CREATE OR REPLACE FUNCTION public.gpsl_sport_list_editions()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT coalesce(jsonb_agg(row_data ORDER BY sort_key DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'id', e.id,
        'edition_label', e.edition_label,
        'gpsl_month', e.gpsl_month,
        'headline', e.front_page->>'headline',
        'published_at', e.published_at,
        'unread', NOT EXISTS (
          SELECT 1 FROM public.gpsl_sport_reads r
          WHERE r.owner_id = v_uid AND r.edition_id = e.id
        )
      ) AS row_data,
      (public.gpsl_sport_edition_sort_key(e.gpsl_month)::int * 1000000)
        + extract(epoch FROM e.published_at)::bigint AS sort_key
    FROM public.gpsl_sport_editions e
    JOIN public.competition_seasons s ON s.id = e.season_id AND s.is_current = true
  ) q;

  RETURN jsonb_build_object('ok', true, 'editions', v_rows);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_nav_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_edition public.gpsl_sport_editions;
  v_unread boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT e.* INTO v_edition
  FROM public.gpsl_sport_editions e
  JOIN public.competition_seasons s ON s.id = e.season_id AND s.is_current = true
  ORDER BY
    public.gpsl_sport_edition_sort_key(e.gpsl_month) DESC NULLS LAST,
    e.published_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'has_edition', false);
  END IF;

  SELECT NOT EXISTS (
    SELECT 1 FROM public.gpsl_sport_reads r
    WHERE r.owner_id = v_uid AND r.edition_id = v_edition.id
  ) INTO v_unread;

  RETURN jsonb_build_object(
    'ok', true,
    'has_edition', true,
    'edition_id', v_edition.id,
    'edition_label', v_edition.edition_label,
    'headline', v_edition.front_page->>'headline',
    'unread', v_unread
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_month_label(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_preseason_window(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_may_edition(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_inseason_edition(bigint, text) TO service_role;
