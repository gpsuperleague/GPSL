-- GPSL Sport — hero / image metadata for immersive newspaper layout
-- Run after gpsl_sport_may_preseason.sql. Regenerate editions to pick up heroes.

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
  v_top_buyer_short text;
  v_top_player_id text;
  v_xfer_count int := 0;
  v_hero jsonb;
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
      'story_type', CASE WHEN p_preseason THEN 'preseason_quiet' ELSE 'transfer_quiet' END,
      'hero', jsonb_build_object('kind', 'generic', 'caption', 'Pre-season transfer watch')
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
      v_top_buyer_short := v_transfer.buyer_club_id;
      v_top_player_id := v_transfer.player_id::text;
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
        'lead', jsonb_build_object(
          'headline', v_lead_headline,
          'body', v_lead_body,
          'player_id', v_transfer.player_id,
          'buyer_club_short', v_transfer.buyer_club_id,
          'seller_club_short', v_transfer.seller_club_id,
          'fee', v_transfer.fee
        ),
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
          ),
          'player_id', v_transfer.player_id,
          'club_short', v_transfer.buyer_club_id
        )
      );
    END IF;
  END LOOP;

  v_hero := jsonb_build_object(
    'kind', 'transfer',
    'club_short', v_top_buyer_short,
    'player_id', v_top_player_id,
    'caption', coalesce(v_top_buyer, 'GPSL') || ' — pre-season business heats up'
  );

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
      'story_type', 'preseason_quiet',
      'hero', jsonb_build_object('kind', 'generic', 'caption', 'Transfer market watch')
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
    'story_type', 'preseason_transfers',
    'hero', v_hero
  );

  IF (v_back->>'enabled')::boolean IS TRUE THEN
    v_back := v_back || jsonb_build_object('stories', v_transfer_stories);
  END IF;

  RETURN jsonb_build_object('front_page', v_front, 'back_page', v_back, 'story_type', 'preseason_transfers');
END;
$function$;
