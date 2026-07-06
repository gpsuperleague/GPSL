-- =============================================================================
-- GPSL Sport Phase 3 — club auction owners, manager draft signings, multi-page
-- Run after gpsl_sport_preseason_phase2.sql
-- Regenerate June/July editions after applying (see gpsl_sport_regenerate_edition).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Owner takeovers — club auctions, ledger, welcome inbox, registry
-- ---------------------------------------------------------------------------

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
  auction_wins AS (
    SELECT
      upper(btrim(l.club_short_name)) AS club_short,
      l.updated_at AS assigned_at,
      l.winning_owner_id AS owner_id,
      'club_auction'::text AS assign_source
    FROM public."Club_Auction_Listings" l
    WHERE l.transfer_completed = true
      AND l.winning_owner_id IS NOT NULL
      AND l.updated_at >= p_window_start
      AND l.updated_at < p_window_end
  ),
  ledger AS (
    SELECT
      upper(btrim(l.club_short_name)) AS club_short,
      l.created_at AS assigned_at,
      coalesce(
        nullif(btrim(l.metadata->>'owner_id'), '')::uuid,
        nullif(btrim(l.metadata->>'winning_owner_id'), '')::uuid
      ) AS owner_id,
      coalesce(nullif(btrim(l.metadata->>'source'), ''), 'club_assignment') AS assign_source
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'infra_purchase'
      AND l.created_at >= p_window_start
      AND l.created_at < p_window_end
      AND coalesce(
        nullif(btrim(l.metadata->>'owner_id'), ''),
        nullif(btrim(l.metadata->>'winning_owner_id'), '')
      ) IS NOT NULL
  ),
  registry_active AS (
    SELECT
      upper(btrim(r.last_club_short_name)) AS club_short,
      r.status_changed_at AS assigned_at,
      r.owner_id,
      'owner_assignment'::text AS assign_source
    FROM public.gpsl_owner_registry r
    JOIN public."Clubs" c ON c."ShortName" = upper(btrim(r.last_club_short_name))
    WHERE r.status = 'active'
      AND r.last_club_short_name IS NOT NULL
      AND c.owner_id = r.owner_id
      AND r.status_changed_at >= p_window_start
      AND r.status_changed_at < p_window_end
  ),
  merged AS (
    SELECT * FROM welcomes
    UNION ALL
    SELECT * FROM auction_wins
    UNION ALL
    SELECT * FROM ledger
    UNION ALL
    SELECT * FROM registry_active
  ),
  deduped AS (
    SELECT DISTINCT ON (m.club_short)
      m.club_short,
      m.assigned_at,
      m.owner_id,
      m.assign_source
    FROM merged m
    WHERE m.owner_id IS NOT NULL
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

-- ---------------------------------------------------------------------------
-- Manager draft / signing arrivals
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_sport_list_manager_signings(
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

  WITH ledger_rows AS (
    SELECT
      l.created_at AS signed_at,
      upper(btrim(l.club_short_name)) AS club_short,
      nullif(btrim(l.metadata->>'manager_id'), '')::bigint AS manager_id,
      abs(coalesce(l.amount, 0)) AS fee,
      coalesce(l.metadata->>'manager_draft', '') IN ('true', 't', '1') AS from_draft
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'contract_signing_offer'
      AND nullif(btrim(l.metadata->>'manager_id'), '') IS NOT NULL
      AND l.created_at >= p_window_start
      AND l.created_at < p_window_end
  ),
  listing_rows AS (
    SELECT
      l.updated_at AS signed_at,
      upper(btrim(l.current_highest_bidder)) AS club_short,
      l.manager_id,
      coalesce(l.current_highest_bid, 0) AS fee,
      true AS from_draft
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.transfer_completed = true
      AND l.manager_id IS NOT NULL
      AND nullif(btrim(l.current_highest_bidder), '') IS NOT NULL
      AND l.updated_at >= p_window_start
      AND l.updated_at < p_window_end
  ),
  merged AS (
    SELECT signed_at, club_short, manager_id, fee, from_draft FROM ledger_rows
    UNION ALL
    SELECT signed_at, club_short, manager_id, fee, from_draft FROM listing_rows
  ),
  deduped AS (
    SELECT DISTINCT ON (m.manager_id, m.club_short)
      m.signed_at,
      m.club_short,
      m.manager_id,
      m.fee,
      m.from_draft
    FROM merged m
    WHERE m.manager_id IS NOT NULL
      AND m.club_short IS NOT NULL
    ORDER BY m.manager_id, m.club_short, m.signed_at DESC
  )
  SELECT coalesce(jsonb_agg(row_data ORDER BY sort_key), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'manager_id', d.manager_id,
        'manager_name', mgr.name,
        'manager_slug', mgr.slug,
        'manager_rating', mgr.rating,
        'club_short', d.club_short,
        'club_name', public.gpsl_sport_club_display_name(d.club_short),
        'fee', d.fee,
        'from_draft', d.from_draft,
        'signed_at', d.signed_at
      ) AS row_data,
      (coalesce(mgr.rating, 0) * 1000000 + coalesce(d.fee, 0))::numeric AS sort_key
    FROM deduped d
    JOIN public."Managers" mgr ON mgr.id = d.manager_id
  ) q;

  RETURN v_rows;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_manager_story(
  p_seed text,
  p_signing jsonb,
  p_month_label text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text := coalesce(p_signing->>'manager_name', 'Manager');
  v_club text := coalesce(p_signing->>'club_name', p_signing->>'club_short', 'GPSL');
  v_club_short text := p_signing->>'club_short';
  v_rating int := coalesce((p_signing->>'manager_rating')::int, 0);
  v_fee text := public.gpsl_sport_format_fee(coalesce((p_signing->>'fee')::numeric, 0));
  v_from_draft boolean := coalesce(p_signing->>'from_draft', 'false') IN ('true', 't', '1');
  v_headline text;
  v_body text;
  v_pull text;
BEGIN
  v_headline := public.gpsl_sport_apply_template(
    public.gpsl_sport_pick_template(p_seed || ':mh', ARRAY[
      upper(v_name) || ' TAKES CHARGE AT ' || upper(v_club),
      upper(v_club) || ' WIN MANAGER DRAFT RACE FOR ' || upper(v_name),
      upper(v_name) || ' LANDS AT ' || upper(v_club) || ' AFTER AUCTION BATTLE'
    ]),
    jsonb_build_object('manager', v_name, 'club', v_club, 'month', p_month_label)
  );

  v_body := CASE
    WHEN v_from_draft THEN format(
      E'%s won the manager draft auction for %s, securing %s (rated %s) for %s.\n\nThe touchline appointment is one of the busiest plots of %s pre-season — rivals know a strong coach can shift the mood before a ball is kicked.',
      v_club, v_name, v_name, v_rating, v_fee, p_month_label
    )
    ELSE format(
      E'%s have appointed %s (rated %s) in a %s signing.\n\nThe dugout move underlines how seriously %s are taking the build-up to August.',
      v_club, v_name, v_rating, v_fee, v_club
    )
  END;

  v_pull := public.gpsl_sport_pick_template(p_seed || ':mp', ARRAY[
    '"I know this league. Now I get to lead a club with real ambition."',
    '"The board backed me in the auction — I will repay that faith."',
    '"We have talent in the squad. My job is to coach it into something special."',
    '"Pre-season is when habits are built. We start now."'
  ]);

  RETURN jsonb_build_object(
    'kicker', CASE WHEN v_from_draft THEN 'Manager draft' ELSE 'Dugout' END,
    'headline', v_headline,
    'body', v_body,
    'pull_quote', v_pull,
    'byline', 'By GPSL Sport dugout desk · ' || v_club,
    'story_kind', 'manager_signing',
    'manager_id', p_signing->>'manager_id',
    'manager_slug', p_signing->>'manager_slug',
    'manager_name', v_name,
    'manager_rating', v_rating,
    'club_short', v_club_short,
    'fee', p_signing->>'fee'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Pre-season edition builder — front + managers + owners + transfer back
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
  v_managers_page jsonb := jsonb_build_object('enabled', false);
  v_owners_page jsonb := jsonb_build_object('enabled', false);
  v_transfer record;
  v_transfer_stories jsonb := '[]'::jsonb;
  v_owner_stories jsonb := '[]'::jsonb;
  v_manager_stories jsonb := '[]'::jsonb;
  v_sidebar_stories jsonb := '[]'::jsonb;
  v_owners jsonb;
  v_managers jsonb;
  v_owner jsonb;
  v_manager jsonb;
  v_i int := 0;
  v_o int := 0;
  v_m int := 0;
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
  v_manager_count int := 0;
  v_hero jsonb;
  v_lead_kind text := 'transfer';
  v_owner_story jsonb;
  v_manager_story jsonb;
  v_owner_score numeric := 0;
  v_transfer_score numeric := 0;
  v_manager_score numeric := 0;
  v_lead_manager jsonb;
BEGIN
  IF p_window_start IS NULL OR p_window_end IS NULL OR p_window_end <= p_window_start THEN
    IF p_preseason THEN
      v_front := jsonb_build_object(
        'masthead', 'GPSL Sport',
        'edition_label', p_month_label,
        'headline', format('%s PRE-SEASON SPECIAL', upper(p_month_label)),
        'subhead', 'Edition pending — pre-season window not configured yet',
        'lead_paragraph', format(
          E'GPSL Sport will publish %s pre-season coverage once the calendar window is set. Check back after the season schedule is confirmed.',
          p_month_label
        ),
        'stories', '[]'::jsonb,
        'owner_stories', '[]'::jsonb,
        'manager_stories', '[]'::jsonb,
        'story_type', 'preseason_pending',
        'hero', jsonb_build_object('kind', 'generic', 'caption', 'Pre-season watch')
      );
      RETURN jsonb_build_object(
        'front_page', v_front,
        'back_page', v_back,
        'managers_page', v_managers_page,
        'owners_page', v_owners_page,
        'story_type', 'preseason_pending'
      );
    END IF;

    v_front := jsonb_build_object(
      'masthead', 'GPSL Sport',
      'edition_label', p_month_label,
      'headline', format('GPSL Sport — %s quiet so far', p_month_label),
      'subhead', 'No deals in this window',
      'lead_paragraph', format('The %s transfer window has been quiet.', p_month_label),
      'stories', '[]'::jsonb,
      'story_type', 'transfer_quiet'
    );
    RETURN jsonb_build_object('front_page', v_front, 'back_page', v_back, 'story_type', 'transfer_quiet');
  END IF;

  v_owners := public.gpsl_sport_list_owner_takeovers(p_window_start, p_window_end);
  v_owner_count := coalesce(jsonb_array_length(v_owners), 0);

  v_managers := public.gpsl_sport_list_manager_signings(p_window_start, p_window_end);
  v_manager_count := coalesce(jsonb_array_length(v_managers), 0);

  IF v_owner_count > 0 THEN
    FOR v_o IN 0..(v_owner_count - 1) LOOP
      v_owner := v_owners->v_o;
      v_owner_story := public.gpsl_sport_build_owner_story(
        p_seed || ':o' || v_o::text,
        v_owner,
        p_month_label
      );
      v_owner_stories := v_owner_stories || jsonb_build_array(v_owner_story);
    END LOOP;
    v_owner_score := 40 + greatest(0, 30 - coalesce((v_owners->0->>'prestige_rank')::int, 30));
  END IF;

  IF v_manager_count > 0 THEN
    FOR v_m IN 0..(v_manager_count - 1) LOOP
      v_manager := v_managers->v_m;
      v_manager_story := public.gpsl_sport_build_manager_story(
        p_seed || ':m' || v_m::text,
        v_manager,
        p_month_label
      );
      v_manager_stories := v_manager_stories || jsonb_build_array(v_manager_story);
    END LOOP;
    v_lead_manager := v_managers->0;
    v_manager_score := coalesce((v_lead_manager->>'manager_rating')::int, 0) * 1.5
      + coalesce((v_lead_manager->>'fee')::numeric, 0) / 1500000.0;
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
    LIMIT 20
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

  IF v_xfer_count = 0 AND v_owner_count = 0 AND v_manager_count = 0 THEN
    v_front := jsonb_build_object(
      'masthead', 'GPSL Sport',
      'edition_label', p_month_label,
      'headline', format('%s PRE-SEASON: MARKET YET TO IGNITE', upper(p_month_label)),
      'subhead', 'No settled deals in this calendar slice',
      'lead_paragraph', format(
        E'GPSL Sport''s %s edition finds no completed manager auctions, owner takeovers or transfer fees in this window yet.\n\nThe wire will fill as pre-season accelerates toward August.',
        p_month_label
      ),
      'stories', '[]'::jsonb,
      'owner_stories', '[]'::jsonb,
      'manager_stories', '[]'::jsonb,
      'story_type', 'preseason_quiet',
      'hero', jsonb_build_object('kind', 'generic', 'caption', 'Pre-season watch')
    );
    RETURN jsonb_build_object(
      'front_page', v_front,
      'back_page', v_back,
      'managers_page', v_managers_page,
      'owners_page', v_owners_page,
      'story_type', 'preseason_quiet'
    );
  END IF;

  -- Pick lead story: transfer vs manager vs owner
  IF v_transfer_score >= v_manager_score AND v_transfer_score >= v_owner_score AND v_xfer_count > 0 THEN
    v_lead_kind := 'transfer';
    v_tpl := public.gpsl_sport_pick_template(
      p_seed || ':xfer',
      ARRAY[
        E'{{BUYER}} SPLASH {{FEE}} ON {{PLAYER}}',
        E'BLOCKBUSTER DEAL: {{PLAYER}} HEADS TO {{BUYER}} FOR {{FEE}}',
        E'{{BUYER}} LEAD {{MONTH}} SPENDING WITH {{FEE}} MOVE FOR {{PLAYER}}'
      ]
    );
    v_lead_headline := public.gpsl_sport_apply_template(v_tpl, jsonb_build_object(
      'buyer', v_top_buyer,
      'seller', v_seller_name,
      'player', v_top_player,
      'fee', public.gpsl_sport_format_fee(v_top_fee),
      'month', p_month_label
    ));
    v_lead_body := format(
      E'%s completed the headline signing of %s from the transfer market for %s during %s.\n\nTurn inside for every manager draft arrival and new owner at the wheel.',
      v_top_buyer,
      v_top_player,
      public.gpsl_sport_format_fee(v_top_fee),
      p_month_label
    );
    v_lead_pull := public.gpsl_sport_pick_template(p_seed || ':tp', ARRAY[
      '"We identified him early. The fee reflects his quality."',
      '"He is the missing piece — the board backed us."',
      '"Rivals strengthened. We had to act."'
    ]);
    v_lead_byline := 'By GPSL Sport transfer desk';
    v_hero := jsonb_build_object(
      'kind', 'transfer',
      'club_short', v_top_buyer_short,
      'player_id', v_top_player_id,
      'caption', coalesce(v_top_buyer, 'GPSL') || ' — pre-season business heats up'
    );
  ELSIF v_manager_score >= v_owner_score AND v_manager_count > 0 THEN
    v_lead_kind := 'manager';
    v_manager_story := v_manager_stories->0;
    v_lead_headline := v_manager_story->>'headline';
    v_lead_body := v_manager_story->>'body';
    v_lead_pull := v_manager_story->>'pull_quote';
    v_lead_byline := v_manager_story->>'byline';
    v_hero := jsonb_build_object(
      'kind', 'manager_signing',
      'club_short', v_manager_story->>'club_short',
      'manager_slug', v_manager_story->>'manager_slug',
      'manager_name', v_manager_story->>'manager_name',
      'caption', coalesce(v_manager_story->>'manager_name', 'Manager') || ' takes the dugout'
    );
  ELSIF v_owner_count > 0 THEN
    v_lead_kind := 'owner';
    v_owner_story := v_owner_stories->0;
    v_lead_headline := v_owner_story->>'headline';
    v_lead_body := v_owner_story->>'body';
    v_lead_pull := v_owner_story->>'pull_quote';
    v_lead_byline := v_owner_story->>'byline';
    v_hero := jsonb_build_object(
      'kind', 'owner_takeover',
      'club_short', v_owner_story->>'club_short',
      'owner_tag', v_owner_story->>'owner_tag',
      'caption', coalesce(v_owner_story->>'owner_tag', 'New owner') || ' at the wheel'
    );
  END IF;

  v_lead_subhead := trim(both ' · ' from concat_ws(' · ',
    CASE WHEN v_xfer_count > 0 THEN v_xfer_count::text || ' transfer deal' || CASE WHEN v_xfer_count = 1 THEN '' ELSE 's' END END,
    CASE WHEN v_manager_count > 0 THEN v_manager_count::text || ' manager arrival' || CASE WHEN v_manager_count = 1 THEN '' ELSE 's' END END,
    CASE WHEN v_owner_count > 0 THEN v_owner_count::text || ' new owner' || CASE WHEN v_owner_count = 1 THEN '' ELSE 's' END END
  ));

  v_sidebar_stories := public.gpsl_sport_jsonb_array_tail(v_manager_stories)
    || public.gpsl_sport_jsonb_array_tail(v_owner_stories)
    || public.gpsl_sport_jsonb_array_tail(v_transfer_stories);

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
    'manager_stories', v_manager_stories,
    'transfer_count', v_xfer_count,
    'owner_count', v_owner_count,
    'manager_count', v_manager_count,
    'story_type', CASE
      WHEN v_xfer_count > 0 AND v_owner_count > 0 AND v_manager_count > 0 THEN 'preseason_full'
      WHEN v_xfer_count > 0 AND (v_owner_count > 0 OR v_manager_count > 0) THEN 'preseason_owners_and_transfers'
      WHEN v_manager_count > 0 AND v_owner_count > 0 THEN 'preseason_managers_and_owners'
      WHEN v_manager_count > 0 THEN 'preseason_managers'
      WHEN v_owner_count > 0 THEN 'preseason_owners'
      ELSE 'preseason_transfers'
    END,
    'hero', v_hero,
    'lead_kind', v_lead_kind
  );

  IF v_manager_count > 0 THEN
    v_manager_story := v_manager_stories->0;
    v_managers_page := jsonb_build_object(
      'enabled', true,
      'page_title', 'Manager draft special',
      'lead', CASE WHEN v_lead_kind = 'manager' THEN v_manager_story ELSE NULL END,
      'stories', CASE
        WHEN v_lead_kind = 'manager' THEN public.gpsl_sport_jsonb_array_tail(v_manager_stories)
        ELSE v_manager_stories
      END
    );
  END IF;

  IF v_owner_count > 0 THEN
    v_owner_story := v_owner_stories->0;
    v_owners_page := jsonb_build_object(
      'enabled', true,
      'page_title', 'New owners',
      'lead', CASE WHEN v_lead_kind = 'owner' THEN v_owner_story ELSE NULL END,
      'stories', CASE
        WHEN v_lead_kind = 'owner' THEN public.gpsl_sport_jsonb_array_tail(v_owner_stories)
        ELSE v_owner_stories
      END
    );
  END IF;

  IF v_xfer_count > 0 THEN
    v_back := jsonb_build_object(
      'enabled', true,
      'page_title', 'Transfer special',
      'lead', jsonb_build_object(
        'headline', coalesce(
          v_lead_headline,
          format('%s PRE-SEASON TRANSFER WIRE', upper(p_month_label))
        ),
        'body', format(
          E'GPSL Sport logs %s completed transfer fee(s) in the %s window. Every deal below.',
          v_xfer_count, p_month_label
        ),
        'byline', 'GPSL Sport transfer desk',
        'player_id', v_top_player_id,
        'buyer_club_short', v_top_buyer_short,
        'fee', v_top_fee
      ),
      'stories', v_transfer_stories,
      'owner_stories', '[]'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'front_page', v_front,
    'back_page', v_back,
    'managers_page', v_managers_page,
    'owners_page', v_owners_page,
    'story_type', v_front->>'story_type'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Generate / regenerate — July scans full pre-season window
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
  v_data_start timestamptz;
  v_data_end timestamptz;
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

  IF v_month = 'july' THEN
    v_data_start := v_win.preseason_start;
    v_data_end := v_win.august_start;
  ELSE
    v_data_start := v_win.june_window_start;
    v_data_end := v_win.june_window_end;
  END IF;

  IF v_data_start IS NULL OR v_data_end IS NULL OR v_data_end <= v_data_start THEN
    v_data_start := v_win.preseason_start;
    v_data_end := v_win.august_start;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_seed := p_season_id::text || ':' || v_month || ':preseason';

  v_built := public.gpsl_sport_build_transfer_edition(
    v_seed,
    v_month_label,
    v_data_start,
    v_data_end,
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
      'preseason_weeks', v_win.preseason_weeks,
      'data_window_start', v_data_start,
      'data_window_end', v_data_end,
      'managers_page', coalesce(v_built->'managers_page', '{}'::jsonb),
      'owners_page', coalesce(v_built->'owners_page', '{}'::jsonb)
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_regenerate_edition(
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
  v_role text := coalesce(auth.jwt() ->> 'role', '');
BEGIN
  IF auth.uid() IS NULL
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.gpsl_sport_reads r
  WHERE r.edition_id IN (
    SELECT e.id FROM public.gpsl_sport_editions e
    WHERE e.season_id = p_season_id AND e.gpsl_month = v_month
  );

  DELETE FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND e.gpsl_month = v_month;

  RETURN public.gpsl_sport_generate_edition(p_season_id, v_month);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_get_edition(p_edition_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_edition public.gpsl_sport_editions;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT * INTO v_edition FROM public.gpsl_sport_editions WHERE id = p_edition_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'edition', jsonb_build_object(
      'id', v_edition.id,
      'edition_label', v_edition.edition_label,
      'gpsl_month', v_edition.gpsl_month,
      'published_at', v_edition.published_at,
      'story_type', v_edition.story_type,
      'front_page', v_edition.front_page,
      'back_page', v_edition.back_page,
      'managers_page', coalesce(v_edition.detail->'managers_page', '{}'::jsonb),
      'owners_page', coalesce(v_edition.detail->'owners_page', '{}'::jsonb),
      'detail', v_edition.detail
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_list_manager_signings(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_manager_story(text, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_regenerate_edition(bigint, text) TO authenticated;
