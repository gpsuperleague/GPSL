-- =============================================================================
-- GPSL Sport Phase 2 — pre-season owner takeovers + richer June/July editions
-- Run after gpsl_sport_may_preseason.sql (and gpsl_sport_visual_heroes.sql if applied)
-- Safe to re-run. Regenerate June/July editions after applying.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_jsonb_array_tail(p_arr jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(jsonb_agg(elem ORDER BY ord), '[]'::jsonb)
  FROM jsonb_array_elements(coalesce(p_arr, '[]'::jsonb)) WITH ORDINALITY t(elem, ord)
  WHERE ord > 1;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_list_owner_takeovers(
  p_window_start timestamptz,
  p_window_end timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF p_window_start IS NULL OR p_window_end IS NULL OR p_window_end <= p_window_start THEN
    RETURN '[]'::jsonb;
  END IF;

  WITH welcomes AS (
    SELECT
      upper(btrim(i.recipient_club_short_name)) AS club_short,
      i.created_at AS assigned_at,
      c.owner_id,
      'club_welcome'::text AS assign_source
    FROM public.competition_inbox i
    JOIN public."Clubs" c ON c."ShortName" = upper(btrim(i.recipient_club_short_name))
    WHERE i.message_type = 'welcome_gpsl'
      AND i.recipient_club_short_name IS NOT NULL
      AND i.dedupe_key LIKE 'welcome:%'
      AND i.created_at >= p_window_start
      AND i.created_at < p_window_end
      AND c.owner_id IS NOT NULL
  ),
  ledger AS (
    SELECT
      upper(btrim(l.club_short_name)) AS club_short,
      l.created_at AS assigned_at,
      nullif(btrim(l.metadata->>'owner_id'), '')::uuid AS owner_id,
      coalesce(nullif(btrim(l.metadata->>'source'), ''), 'club_assignment') AS assign_source
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'infra_purchase'
      AND l.created_at >= p_window_start
      AND l.created_at < p_window_end
      AND nullif(btrim(l.metadata->>'owner_id'), '') IS NOT NULL
  ),
  merged AS (
    SELECT * FROM welcomes
    UNION ALL
    SELECT * FROM ledger
  ),
  deduped AS (
    SELECT DISTINCT ON (m.club_short)
      m.club_short,
      m.assigned_at,
      m.owner_id,
      m.assign_source
    FROM merged m
    ORDER BY m.club_short, m.assigned_at DESC
  )
  SELECT coalesce(jsonb_agg(row_data ORDER BY sort_key), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'club_short', d.club_short,
        'club_name', public.gpsl_sport_club_display_name(d.club_short),
        'owner_id', d.owner_id,
        'owner_tag', coalesce(
          nullif(btrim(public.owner_registry_resolve_tag(d.owner_id)), ''),
          'New owner'
        ),
        'assigned_at', d.assigned_at,
        'assign_source', d.assign_source,
        'prestige_rank', pr.prestige_rank
      ) AS row_data,
      coalesce(pr.prestige_rank, 999) AS sort_key
    FROM deduped d
    LEFT JOIN public.competition_club_prestige_public pr ON pr.club_short_name = d.club_short
  ) q;

  RETURN v_rows;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_owner_story(
  p_seed text,
  p_owner jsonb,
  p_month_label text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_short text := p_owner->>'club_short';
  v_club_name text := coalesce(p_owner->>'club_name', v_club_short);
  v_owner_tag text := coalesce(p_owner->>'owner_tag', 'New owner');
  v_headline text;
  v_body text;
  v_pull text;
  v_byline text;
  v_source text := coalesce(p_owner->>'assign_source', 'club_assignment');
BEGIN
  v_headline := public.gpsl_sport_apply_template(
    public.gpsl_sport_pick_template(p_seed || ':oh', ARRAY[
      upper(v_owner_tag) || ' TAKES THE HELM AT ' || upper(v_club_name),
      'NEW ERA DAWNS AS ' || upper(v_owner_tag) || ' ASSIGNED TO ' || upper(v_club_name),
      upper(v_club_name) || ' WELCOME NEW OWNER ' || upper(v_owner_tag)
    ]),
    jsonb_build_object('owner', v_owner_tag, 'club', v_club_name, 'month', p_month_label)
  );

  v_body := CASE v_source
    WHEN 'club_auction' THEN format(
      E'%s won the club auction and has been formally installed at %s. The GPSL inbox confirms the link — stadium infrastructure charged, squad inherited, expectations set.\n\nGPSL Sport understands the new incumbent has already been studying the Learning GPSL guide and scouting the transfer market.',
      v_owner_tag, v_club_name
    )
    WHEN 'admin_assign' THEN format(
      E'%s has been appointed to run %s ahead of the new campaign. The league office confirmed the assignment; finances and stadium infrastructure are in place.\n\nRivals will be watching how quickly the new owner stamps their authority on the squad.',
      v_owner_tag, v_club_name
    )
    ELSE format(
      E'%s is the new owner of %s — confirmed via the league''s official welcome this %s. The takeover is complete: boardroom seat taken, inbox open, transfer budget live.\n\nPre-season is when identities are forged. %s will want a fast start.',
      v_owner_tag, v_club_name, p_month_label, v_club_name
    )
  END;

  v_pull := public.gpsl_sport_pick_template(p_seed || ':op', ARRAY[
    '"This is a special club — I cannot wait to get started."',
    '"The squad has quality. My job is to unlock it."',
    '"I have followed GPSL for years. Now it is my turn."',
    '"Expect ambition. I did not come here to finish mid-table."'
  ]);

  v_byline := 'By GPSL Sport owner desk · ' || v_club_name;

  RETURN jsonb_build_object(
    'kicker', 'New owner',
    'headline', v_headline,
    'body', v_body,
    'pull_quote', v_pull,
    'byline', v_byline,
    'story_kind', 'owner_takeover',
    'club_short', v_club_short,
    'owner_tag', v_owner_tag,
    'owner_id', p_owner->>'owner_id'
  );
END;
$function$;

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
  v_owner_stories jsonb := '[]'::jsonb;
  v_sidebar_stories jsonb := '[]'::jsonb;
  v_owners jsonb;
  v_owner jsonb;
  v_i int := 0;
  v_o int := 0;
  v_player_name text;
  v_player_rating int;
  v_seller_name text;
  v_buyer_name text;
  v_fee text;
  v_goals int;
  v_assists int;
  v_tpl text;
  v_lead_headline text;
  v_lead_subhead text;
  v_lead_body text;
  v_lead_byline text;
  v_lead_pull text;
  v_top_fee numeric := 0;
  v_top_buyer text;
  v_top_player text;
  v_top_buyer_short text;
  v_top_player_id text;
  v_xfer_count int := 0;
  v_owner_count int := 0;
  v_hero jsonb;
  v_lead_kind text := 'transfer';
  v_lead_owner jsonb;
  v_owner_score numeric := 0;
  v_transfer_score numeric := 0;
  v_owner_story jsonb;
BEGIN
  IF p_window_start IS NOT NULL AND p_window_end IS NOT NULL AND p_window_end > p_window_start THEN
    v_owners := public.gpsl_sport_list_owner_takeovers(p_window_start, p_window_end);
    v_owner_count := coalesce(jsonb_array_length(v_owners), 0);

    IF v_owner_count > 0 THEN
      v_lead_owner := v_owners->0;
      v_owner_score := 40 + greatest(0, 30 - coalesce((v_lead_owner->>'prestige_rank')::int, 30));

      FOR v_o IN 0..(v_owner_count - 1) LOOP
        v_owner := v_owners->v_o;
        v_owner_story := public.gpsl_sport_build_owner_story(
          p_seed || ':o' || v_o::text,
          v_owner,
          p_month_label
        );
        v_owner_stories := v_owner_stories || jsonb_build_array(v_owner_story);
      END LOOP;
    END IF;
  ELSE
    v_owners := '[]'::jsonb;
    v_owner_count := 0;
  END IF;

  IF p_window_start IS NULL OR p_window_end IS NULL OR p_window_end <= p_window_start THEN
    IF v_owner_count > 0 THEN
      v_owner_story := v_owner_stories->0;
      v_front := jsonb_build_object(
        'masthead', 'GPSL Sport',
        'edition_label', p_month_label,
        'headline', v_owner_story->>'headline',
        'subhead', format('%s new owner(s) take charge ahead of the campaign', v_owner_count),
        'lead_paragraph', v_owner_story->>'body',
        'pull_quote', v_owner_story->>'pull_quote',
        'byline', v_owner_story->>'byline',
        'stories', public.gpsl_sport_jsonb_array_tail(v_owner_stories),
        'owner_stories', v_owner_stories,
        'story_type', 'preseason_owners',
        'hero', jsonb_build_object(
          'kind', 'owner_takeover',
          'club_short', v_owner_story->>'club_short',
          'owner_tag', v_owner_story->>'owner_tag',
          'caption', coalesce(v_owner_story->>'club_name', 'GPSL') || ' — new owner installed'
        )
      );
      RETURN jsonb_build_object('front_page', v_front, 'back_page', v_back, 'story_type', 'preseason_owners');
    END IF;

    v_front := jsonb_build_object(
      'masthead', 'GPSL Sport',
      'edition_label', p_month_label,
      'headline', format('%s PRE-SEASON: OWNERS HOLD THEIR NERVE', upper(p_month_label)),
      'subhead', 'Quiet window so far as August approaches',
      'lead_paragraph', format(
        E'The %s edition of GPSL Sport finds the market subdued. With the new campaign on the horizon, clubs are weighing moves and new owners settling in.\n\nThe transfer wire and boardroom will not stay quiet for long.',
        p_month_label
      ),
      'stories', '[]'::jsonb,
      'owner_stories', '[]'::jsonb,
      'story_type', CASE WHEN p_preseason THEN 'preseason_quiet' ELSE 'transfer_quiet' END,
      'hero', jsonb_build_object('kind', 'generic', 'caption', 'Pre-season watch')
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
    LIMIT 12
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
      v_transfer_score := v_top_fee / 1000000.0;
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
      v_lead_pull := public.gpsl_sport_pick_template(p_seed || ':tp', ARRAY[
        '"We identified him early. The fee reflects his quality."',
        '"He is the missing piece — the board backed us."',
        '"Rivals strengthened. We had to act."'
      ]);
      v_lead_byline := 'By GPSL Sport transfer desk';
      v_back := jsonb_build_object(
        'enabled', true,
        'page_title', 'Transfer special',
        'lead', jsonb_build_object(
          'headline', v_lead_headline,
          'body', v_lead_body,
          'pull_quote', v_lead_pull,
          'byline', v_lead_byline,
          'player_id', v_transfer.player_id,
          'buyer_club_short', v_transfer.buyer_club_id,
          'seller_club_short', v_transfer.seller_club_id,
          'fee', v_transfer.fee
        ),
        'stories', '[]'::jsonb
      );
    END IF;

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
        'club_short', v_transfer.buyer_club_id,
        'story_kind', 'transfer',
        'kicker', 'Done deal'
      )
    );
  END LOOP;

  -- Lead: owner takeover vs blockbuster transfer
  IF v_owner_count > 0 AND (v_xfer_count = 0 OR v_owner_score >= v_transfer_score) THEN
    v_lead_kind := 'owner';
    v_owner_story := v_owner_stories->0;
    v_lead_headline := v_owner_story->>'headline';
    v_lead_subhead := CASE
      WHEN v_xfer_count > 0 THEN format(
        '%s owner change(s) and %s transfer(s) shape %s pre-season',
        v_owner_count, v_xfer_count, p_month_label
      )
      ELSE format('%s new owner(s) take charge in %s', v_owner_count, p_month_label)
    END;
    v_lead_body := v_owner_story->>'body';
    v_lead_pull := v_owner_story->>'pull_quote';
    v_lead_byline := v_owner_story->>'byline';
    v_hero := jsonb_build_object(
      'kind', 'owner_takeover',
      'club_short', v_owner_story->>'club_short',
      'owner_tag', v_owner_story->>'owner_tag',
      'caption', coalesce(v_owner_story->>'owner_tag', 'New owner') || ' at ' || coalesce(v_owner_story->>'club_name', 'GPSL')
    );
    v_sidebar_stories := public.gpsl_sport_jsonb_array_tail(v_owner_stories);
    IF v_xfer_count > 0 THEN
      v_sidebar_stories := v_sidebar_stories || public.gpsl_sport_jsonb_array_tail(v_transfer_stories);
    END IF;
  ELSIF v_xfer_count > 0 THEN
    v_lead_kind := 'transfer';
    v_lead_subhead := CASE
      WHEN v_owner_count > 0 THEN format(
        '%s transfer moves and %s new owner(s) — %s pre-season special',
        v_xfer_count, v_owner_count, p_month_label
      )
      ELSE format('%s completed deals tracked by GPSL Sport', v_xfer_count)
    END;
    v_hero := jsonb_build_object(
      'kind', 'transfer',
      'club_short', v_top_buyer_short,
      'player_id', v_top_player_id,
      'caption', coalesce(v_top_buyer, 'GPSL') || ' — pre-season business heats up'
    );
    v_sidebar_stories := v_owner_stories;
    IF jsonb_array_length(v_transfer_stories) > 1 THEN
      v_sidebar_stories := v_sidebar_stories || public.gpsl_sport_jsonb_array_tail(v_transfer_stories);
    END IF;
  ELSIF v_owner_count > 0 THEN
    v_lead_kind := 'owner';
    v_owner_story := v_owner_stories->0;
    v_lead_headline := v_owner_story->>'headline';
    v_lead_subhead := format('%s new owner(s) take charge in %s', v_owner_count, p_month_label);
    v_lead_body := v_owner_story->>'body';
    v_lead_pull := v_owner_story->>'pull_quote';
    v_lead_byline := v_owner_story->>'byline';
    v_hero := jsonb_build_object(
      'kind', 'owner_takeover',
      'club_short', v_owner_story->>'club_short',
      'owner_tag', v_owner_story->>'owner_tag',
      'caption', 'New owner installed'
    );
    v_sidebar_stories := public.gpsl_sport_jsonb_array_tail(v_owner_stories);
  ELSE
    v_front := jsonb_build_object(
      'masthead', 'GPSL Sport',
      'edition_label', p_month_label,
      'headline', format('%s PRE-SEASON: OWNERS PLAY THE WAITING GAME', upper(p_month_label)),
      'subhead', 'No major fees or boardroom moves in this window',
      'lead_paragraph', format(
        E'GPSL Sport''s %s edition finds the market calm. With August on the horizon, squads are taking shape through smaller moves rather than blockbuster fees.\n\nThe back page will fill up soon enough — pre-season never stays quiet for long.',
        p_month_label
      ),
      'stories', '[]'::jsonb,
      'owner_stories', '[]'::jsonb,
      'story_type', 'preseason_quiet',
      'hero', jsonb_build_object('kind', 'generic', 'caption', 'Transfer market watch')
    );
    RETURN jsonb_build_object('front_page', v_front, 'back_page', v_back, 'story_type', 'preseason_quiet');
  END IF;

  IF v_lead_kind = 'owner' AND v_lead_headline IS NULL THEN
    v_owner_story := v_owner_stories->0;
    v_lead_headline := v_owner_story->>'headline';
    v_lead_body := v_owner_story->>'body';
  END IF;

  IF v_lead_kind = 'transfer' AND v_lead_headline IS NULL THEN
    v_lead_headline := format('%s PRE-SEASON: TRANSFER MARKET HEATS UP', upper(p_month_label));
    v_lead_body := format(
      E'%s set the pace in %s. Turn to the back page for every significant deal.',
      coalesce(v_top_buyer, 'GPSL clubs'), p_month_label
    );
  END IF;

  v_front := jsonb_build_object(
    'masthead', 'GPSL Sport',
    'edition_label', p_month_label,
    'headline', v_lead_headline,
    'subhead', v_lead_subhead,
    'lead_paragraph', v_lead_body,
    'pull_quote', v_lead_pull,
    'byline', v_lead_byline,
    'stories', v_sidebar_stories,
    'owner_stories', v_owner_stories,
    'transfer_count', v_xfer_count,
    'owner_count', v_owner_count,
    'story_type', CASE
      WHEN v_owner_count > 0 AND v_xfer_count > 0 THEN 'preseason_owners_and_transfers'
      WHEN v_owner_count > 0 THEN 'preseason_owners'
      ELSE 'preseason_transfers'
    END,
    'hero', v_hero
  );

  IF (v_back->>'enabled')::boolean IS TRUE THEN
    v_back := v_back || jsonb_build_object(
      'stories', v_transfer_stories,
      'owner_stories', v_owner_stories
    );
  ELSIF v_xfer_count > 0 OR v_owner_count > 0 THEN
    v_back := jsonb_build_object(
      'enabled', true,
      'page_title', 'Pre-season notebook',
      'lead', jsonb_build_object(
        'headline', 'Every deal · every new owner',
        'body', format(
          E'GPSL Sport logs %s transfer(s) and %s owner takeover(s) in the %s window. Below: the complete wire.',
          v_xfer_count, v_owner_count, p_month_label
        ),
        'byline', 'GPSL Sport desk'
      ),
      'stories', v_transfer_stories,
      'owner_stories', v_owner_stories
    );
  END IF;

  RETURN jsonb_build_object(
    'front_page', v_front,
    'back_page', v_back,
    'story_type', v_front->>'story_type'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_list_owner_takeovers(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_owner_story(text, jsonb, text) TO service_role;
