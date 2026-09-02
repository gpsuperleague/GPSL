-- =============================================================================
-- GPSL Sport — June/July voice + slim front + richer transfers + human intl
--
-- • Front page: one teaser each for top manager / owner / transfer (with page_link)
-- • Front mentions: one standout friendly + one top international
-- • Internationals splash: human prematch buildup (no flag codes in headline)
-- • Transfer blurbs: skip empty GPSL stats; rating/star/nation/HG/fit/OooO/FF
--
-- Run in Supabase SQL Editor, then:
--   SELECT public.competition_admin_regenerate_gpsl_sport('july', NULL);
--   SELECT public.competition_admin_regenerate_gpsl_sport('june', NULL);
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Transfer blurb: rating-first when no GPSL history
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_sport_compose_transfer_blurb(
  p_player_id text,
  p_buyer_club text,
  p_seller_club text,
  p_rating int DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rating int := coalesce(p_rating, 0);
  v_potential int := 0;
  v_nation text := '';
  v_pos text := '';
  v_seller_name text;
  v_buyer_name text;
  v_apps int := 0;
  v_goals int := 0;
  v_assists int := 0;
  v_hg boolean := false;
  v_desig text := '';
  v_slot_kind text;
  v_pitch_label text;
  v_formation text;
  v_parts text[] := '{}';
  v_fit text := '';
  v_star boolean := false;
BEGIN
  v_seller_name := public.gpsl_sport_club_display_name(p_seller_club);
  v_buyer_name := public.gpsl_sport_club_display_name(p_buyer_club);

  SELECT
    coalesce(nullif(btrim(p."Rating"::text), '')::int, v_rating, 0),
    greatest(
      coalesce(nullif(btrim(p."Calc_Potential"::text), '')::int, 0),
      coalesce(nullif(btrim(p."Potential"::text), '')::int, 0)
    ),
    nullif(btrim(coalesce(p."Nation"::text, '')), ''),
    nullif(btrim(coalesce(p."Position"::text, '')), '')
  INTO v_rating, v_potential, v_nation, v_pos
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id
  LIMIT 1;

  v_rating := coalesce(v_rating, 0);
  v_star := v_rating >= 79;

  SELECT
    coalesce(sum(CASE WHEN m.appeared THEN 1 ELSE 0 END), 0)::int,
    coalesce(sum(m.goals), 0)::int,
    coalesce(sum(m.assists), 0)::int
  INTO v_apps, v_goals, v_assists
  FROM public.competition_match_player_stats m
  WHERE m.player_id = p_player_id;

  IF to_regprocedure('public.is_player_homegrown(text, text)') IS NOT NULL
     AND coalesce(p_buyer_club, '') <> '' THEN
    BEGIN
      v_hg := public.is_player_homegrown(p_player_id, p_buyer_club);
    EXCEPTION WHEN OTHERS THEN
      v_hg := false;
    END;
  END IF;

  IF to_regclass('public.club_squad_player_designations') IS NOT NULL THEN
    SELECT d.designation INTO v_desig
    FROM public.club_squad_player_designations d
    WHERE d.club_short_name = p_buyer_club
      AND d.player_id = p_player_id
      AND d.designation IN ('one_of_our_own', 'fan_favourite')
    LIMIT 1;
  END IF;

  IF to_regclass('public.club_matchday_squad_player') IS NOT NULL THEN
    SELECT sp.slot_kind,
           upper(nullif(btrim(coalesce(ms.pitch_layout -> sp.pitch_slot ->> 'label', '')), '')),
           nullif(btrim(coalesce(ms.pitch_layout->>'formation_id', '')), '')
    INTO v_slot_kind, v_pitch_label, v_formation
    FROM public.club_matchday_squad_player sp
    LEFT JOIN public.club_matchday_squad ms
      ON ms.club_short_name = sp.club_short_name
    WHERE sp.club_short_name = p_buyer_club
      AND sp.player_id = p_player_id
    LIMIT 1;
  END IF;

  -- Opening: rating / star / arrival
  IF v_star THEN
    v_parts := array_append(
      v_parts,
      format(
        'A rated-%s star signing — 79+ territory — arriving at %s from %s.',
        v_rating, v_buyer_name, v_seller_name
      )
    );
  ELSIF v_rating >= 76 THEN
    v_parts := array_append(
      v_parts,
      format(
        'Rated %s and knocking on the star door, he lands at %s from %s.',
        v_rating, v_buyer_name, v_seller_name
      )
    );
  ELSIF v_rating > 0 THEN
    v_parts := array_append(
      v_parts,
      format('Rated %s. %s pick him up from %s.', v_rating, v_buyer_name, v_seller_name)
    );
  ELSE
    v_parts := array_append(
      v_parts,
      format('%s complete the deal from %s.', v_buyer_name, v_seller_name)
    );
  END IF;

  -- GPSL history only when real
  IF coalesce(v_apps, 0) > 0 THEN
    v_parts := array_append(
      v_parts,
      format(
        'GPSL ledger so far: %s appearance%s, %s goal%s and %s assist%s.',
        v_apps, CASE WHEN v_apps = 1 THEN '' ELSE 's' END,
        v_goals, CASE WHEN v_goals = 1 THEN '' ELSE 's' END,
        v_assists, CASE WHEN v_assists = 1 THEN '' ELSE 's' END
      )
    );
  ELSE
    v_parts := array_append(
      v_parts,
      'No GPSL minutes on the board yet — this is a fresh name for league watchers.'
    );
  END IF;

  -- Nation / HG / potential / designation
  IF v_nation IS NOT NULL THEN
    IF v_hg THEN
      v_parts := array_append(
        v_parts,
        format('%s international and home-grown for %s — the boardroom loves that paperwork.', v_nation, v_buyer_name)
      );
    ELSE
      v_parts := array_append(v_parts, format('Nationality: %s.', v_nation));
    END IF;
  ELSIF v_hg THEN
    v_parts := array_append(v_parts, format('Home-grown for %s.', v_buyer_name));
  END IF;

  IF v_potential >= 85 AND v_potential > v_rating THEN
    v_parts := array_append(
      v_parts,
      format('Potential peeks at %s — development room if the owner plays the long game.', v_potential)
    );
  ELSIF v_potential > v_rating AND v_potential >= 80 THEN
    v_parts := array_append(
      v_parts,
      format('Upside to %s on the card.', v_potential)
    );
  END IF;

  IF v_desig = 'one_of_our_own' THEN
    v_parts := array_append(
      v_parts,
      'Already tagged One of Our Own (OooO) — the dressing-room favourite with the HG badge.'
    );
  ELSIF v_desig = 'fan_favourite' THEN
    v_parts := array_append(
      v_parts,
      'Marked Fan Favourite already — the terrace pick before a ball is kicked.'
    );
  ELSIF v_hg AND v_star AND v_desig IS NULL THEN
    v_parts := array_append(
      v_parts,
      'HG and 79+: textbook OooO candidate if the owner has not locked designations yet.'
    );
  ELSIF (NOT coalesce(v_hg, false)) AND v_rating BETWEEN 76 AND 78 AND v_desig IS NULL THEN
    v_parts := array_append(
      v_parts,
      'That 76–78 band is classic Fan Favourite territory if the club still has the slot free.'
    );
  END IF;

  -- Squad / formation fit
  IF v_slot_kind = 'pitch' THEN
    v_fit := format(
      'Already inked into the matchday XI%s%s.',
      CASE WHEN v_pitch_label IS NOT NULL THEN ' at ' || v_pitch_label ELSE coalesce(' as ' || v_pos, '') END,
      CASE
        WHEN v_formation IS NOT NULL AND v_formation <> 'banks'
          THEN ' (' || v_formation || ')'
        WHEN v_formation = 'banks' THEN ' (banks XI)'
        ELSE ''
      END
    );
  ELSIF v_slot_kind = 'bench' THEN
    v_fit := format(
      'Named on the matchday bench for now%s — depth with a route into the side.',
      CASE WHEN v_pos IS NOT NULL THEN ' (' || v_pos || ')' ELSE '' END
    );
  ELSIF v_slot_kind = 'reserve' THEN
    v_fit := format(
      'Parked in the reserves for the opening sketch%s.',
      CASE WHEN v_pos IS NOT NULL THEN ' as a ' || v_pos ELSE '' END
    );
  ELSIF v_pos IS NOT NULL AND to_regclass('public.club_matchday_squad') IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.club_matchday_squad ms
          WHERE ms.club_short_name = p_buyer_club
            AND ms.pitch_layout IS NOT NULL
            AND ms.pitch_layout <> '{}'::jsonb
        ) THEN
    v_fit := format(
      'Natural %s — useful once the owner finishes shaping the %s squad.',
      v_pos, v_buyer_name
    );
  ELSIF v_pos IS NOT NULL THEN
    v_fit := format('Profiles as a %s; matchday layout still to settle.', v_pos);
  END IF;

  IF v_fit <> '' THEN
    v_parts := array_append(v_parts, v_fit);
  END IF;

  RETURN array_to_string(v_parts, E'\n\n');
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_enrich_transfer_stories(p_stories jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb := '[]'::jsonb;
  v_s jsonb;
  v_pid text;
  v_buyer text;
  v_seller text;
  v_rating int;
  v_body text;
BEGIN
  IF p_stories IS NULL OR jsonb_typeof(p_stories) <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;

  FOR v_s IN SELECT value FROM jsonb_array_elements(p_stories)
  LOOP
    IF coalesce(v_s->>'story_kind', 'transfer') IS DISTINCT FROM 'transfer' THEN
      v_out := v_out || jsonb_build_array(v_s);
      CONTINUE;
    END IF;

    v_pid := nullif(btrim(coalesce(v_s->>'player_id', '')), '');
    IF v_pid IS NULL THEN
      v_out := v_out || jsonb_build_array(v_s);
      CONTINUE;
    END IF;

    v_buyer := coalesce(
      nullif(v_s->>'club_short', ''),
      nullif(v_s->>'buyer_club_short', ''),
      nullif(v_s->>'buyer_club_id', '')
    );
    v_seller := coalesce(
      nullif(v_s->>'seller_club', ''),
      nullif(v_s->>'seller_club_id', '')
    );
    v_rating := nullif(v_s->>'rating', '')::int;

    IF v_seller IS NULL THEN
      BEGIN
        SELECT h.seller_club_id INTO v_seller
        FROM public."Transfer_History" h
        WHERE h.player_id::text = v_pid
          AND (v_buyer IS NULL OR h.buyer_club_id = v_buyer)
        ORDER BY h.transfer_time DESC NULLS LAST
        LIMIT 1;
      EXCEPTION WHEN undefined_table THEN
        v_seller := NULL;
      END;
    END IF;

    BEGIN
      v_body := public.gpsl_sport_compose_transfer_blurb(
        v_pid, v_buyer, v_seller, v_rating
      );
    EXCEPTION WHEN OTHERS THEN
      v_body := v_s->>'body';
    END;

    v_out := v_out || jsonb_build_array(
      v_s || jsonb_build_object(
        'body', coalesce(v_body, v_s->>'body'),
        'seller_club', v_seller
      )
    );
  END LOOP;

  RETURN v_out;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Slim front: one teaser per section, linked to dedicated tab
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_sport_slim_preseason_front(
  p_front jsonb,
  p_back jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_front jsonb := coalesce(p_front, '{}'::jsonb);
  v_back jsonb := coalesce(p_back, '{}'::jsonb);
  v_lead text := lower(coalesce(v_front->>'lead_kind', ''));
  v_teasers jsonb := '[]'::jsonb;
  v_s jsonb;
  v_body text;
BEGIN
  -- Top manager (if not already the splash)
  IF v_lead NOT IN ('manager', 'manager_signing') THEN
    SELECT value INTO v_s
    FROM jsonb_array_elements(coalesce(v_front->'manager_stories', '[]'::jsonb))
    LIMIT 1;
    IF v_s IS NOT NULL AND nullif(v_s->>'headline', '') IS NOT NULL THEN
      v_body := split_part(coalesce(v_s->>'body', ''), E'\n\n', 1);
      IF length(v_body) > 160 THEN
        v_body := left(v_body, 157) || '…';
      END IF;
      v_teasers := v_teasers || jsonb_build_array(
        v_s || jsonb_build_object(
          'kicker', 'Managers →',
          'page_link', 'managers',
          'body', coalesce(nullif(v_body, ''), v_s->>'body')
            || E'\n\nFull manager draft coverage on the Managers tab.'
        )
      );
    END IF;
  END IF;

  -- Top owner
  IF v_lead NOT IN ('owner', 'owner_takeover') THEN
    v_s := NULL;
    SELECT value INTO v_s
    FROM jsonb_array_elements(coalesce(v_front->'owner_stories', '[]'::jsonb))
    LIMIT 1;
    IF v_s IS NOT NULL AND nullif(v_s->>'headline', '') IS NOT NULL THEN
      v_body := split_part(coalesce(v_s->>'body', ''), E'\n\n', 1);
      IF length(v_body) > 160 THEN
        v_body := left(v_body, 157) || '…';
      END IF;
      v_teasers := v_teasers || jsonb_build_array(
        v_s || jsonb_build_object(
          'kicker', 'Owners →',
          'page_link', 'owners',
          'body', coalesce(nullif(v_body, ''), v_s->>'body')
            || E'\n\nEvery new owner story lives on the Owners tab.'
        )
      );
    END IF;
  END IF;

  -- Top transfer (if splash is not the blockbuster)
  IF v_lead <> 'transfer' THEN
    v_s := NULL;
    SELECT value INTO v_s
    FROM jsonb_array_elements(coalesce(v_back->'stories', '[]'::jsonb))
    LIMIT 1;
    IF v_s IS NOT NULL AND nullif(v_s->>'headline', '') IS NOT NULL THEN
      v_body := split_part(coalesce(v_s->>'body', ''), E'\n\n', 1);
      IF length(v_body) > 160 THEN
        v_body := left(v_body, 157) || '…';
      END IF;
      v_teasers := v_teasers || jsonb_build_array(
        v_s || jsonb_build_object(
          'kicker', 'Transfers →',
          'page_link', 'back',
          'story_kind', coalesce(v_s->>'story_kind', 'transfer'),
          'body', coalesce(nullif(v_body, ''), v_s->>'body')
            || E'\n\nThe full transfer special is on the Transfers tab.'
        )
      );
    END IF;
  ELSIF jsonb_array_length(coalesce(v_back->'stories', '[]'::jsonb)) > 1 THEN
    -- Splash is a transfer — tease the second-biggest deal toward Transfers
    SELECT t.value INTO v_s
    FROM jsonb_array_elements(coalesce(v_back->'stories', '[]'::jsonb))
      WITH ORDINALITY AS t(value, ord)
    WHERE t.ord = 2
    LIMIT 1;
    IF v_s IS NOT NULL AND nullif(v_s->>'headline', '') IS NOT NULL THEN
      v_body := split_part(coalesce(v_s->>'body', ''), E'\n\n', 1);
      IF length(v_body) > 160 THEN
        v_body := left(v_body, 157) || '…';
      END IF;
      v_teasers := v_teasers || jsonb_build_array(
        v_s || jsonb_build_object(
          'kicker', 'Transfers →',
          'page_link', 'back',
          'story_kind', coalesce(v_s->>'story_kind', 'transfer'),
          'body', coalesce(nullif(v_body, ''), v_s->>'body')
            || E'\n\nMore deals on the Transfers tab.'
        )
      );
    END IF;
  END IF;

  RETURN v_front || jsonb_build_object('stories', coalesce(v_teasers, '[]'::jsonb));
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_polish_preseason_built(p_built jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_built jsonb := coalesce(p_built, '{}'::jsonb);
  v_back jsonb;
  v_front jsonb;
  v_stories jsonb;
BEGIN
  v_back := coalesce(v_built->'back_page', '{}'::jsonb);
  IF coalesce((v_back->>'enabled')::boolean, false)
     AND jsonb_typeof(v_back->'stories') = 'array' THEN
    v_stories := public.gpsl_sport_enrich_transfer_stories(v_back->'stories');
    v_back := v_back || jsonb_build_object('stories', v_stories);
  END IF;

  v_front := public.gpsl_sport_slim_preseason_front(v_built->'front_page', v_back);
  RETURN v_built || jsonb_build_object('front_page', v_front, 'back_page', v_back);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Front mentions: ONE friendly splash + ONE intl
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_sport_build_preseason_front_mentions(
  p_friendlies jsonb,
  p_internationals jsonb,
  p_month_label text
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_stories jsonb := '[]'::jsonb;
  v_row jsonb;
  v_goals int;
  v_margin int;
  v_home text;
  v_away text;
  v_score text;
  v_f_count int;
  v_i_count int;
  v_blurb text := '';
  v_friendly_ok boolean := false;
BEGIN
  v_f_count := coalesce((p_friendlies->>'played_count')::int, 0);
  v_i_count := coalesce((p_internationals->>'played_count')::int, 0);

  -- Single standout friendly (goal fest / thrashing / best scoreline)
  IF coalesce((p_friendlies->>'enabled')::boolean, false) THEN
    SELECT value INTO v_row
    FROM jsonb_array_elements(coalesce(p_friendlies->'results', '[]'::jsonb))
    ORDER BY
      CASE
        WHEN (value->>'total_goals')::int >= 5 OR (value->>'margin')::int >= 4 THEN 0
        ELSE 1
      END,
      (value->>'total_goals')::int DESC,
      (value->>'margin')::int DESC
    LIMIT 1;

    IF v_row IS NOT NULL THEN
      v_goals := coalesce((v_row->>'total_goals')::int, 0);
      v_margin := coalesce((v_row->>'margin')::int, 0);
      v_home := coalesce(v_row->>'home_name', 'Home');
      v_away := coalesce(v_row->>'away_name', 'Away');
      v_score := coalesce(v_row->>'score', '?-?');
      v_friendly_ok := (v_goals >= 4 OR v_margin >= 3 OR v_f_count <= 3);

      IF v_friendly_ok THEN
        IF v_goals >= 6 THEN
          v_stories := v_stories || jsonb_build_array(jsonb_build_object(
            'headline', format('FRIENDLY GOAL FEST: %s %s %s', v_home, v_score, v_away),
            'body', format(
              E'%s goals in a %s kickabout — the sort of scoreline that fills Discord before breakfast. Friendly or not, that run deserves the front. Full sheet on the Friendlies tab.',
              v_goals, p_month_label
            ),
            'club_short', v_row->>'home_club',
            'story_kind', 'friendly_highlight',
            'page_link', 'friendlies',
            'kicker', 'Friendlies →'
          ));
        ELSIF v_margin >= 4 THEN
          v_stories := v_stories || jsonb_build_array(jsonb_build_object(
            'headline', format('FRIENDLY THRASHING: %s %s %s', v_home, v_score, v_away),
            'body', format(
              E'A %s-goal swing in pre-season. Screenshots flew. See every confirmed friendly on the Friendlies tab.',
              v_margin
            ),
            'club_short', CASE
              WHEN coalesce((v_row->>'home_goals')::int, 0) > coalesce((v_row->>'away_goals')::int, 0)
                THEN v_row->>'home_club'
              ELSE v_row->>'away_club'
            END,
            'story_kind', 'friendly_highlight',
            'page_link', 'friendlies',
            'kicker', 'Friendlies →'
          ));
        ELSE
          v_stories := v_stories || jsonb_build_array(jsonb_build_object(
            'headline', format('FRIENDLY WATCH: %s %s %s', v_home, v_score, v_away),
            'body', format(
              E'Best of the %s friendlies on the wire — a tidy %s. The Friendlies tab has the rest of the pre-season chatter.',
              p_month_label, v_score
            ),
            'club_short', v_row->>'home_club',
            'story_kind', 'friendly_highlight',
            'page_link', 'friendlies',
            'kicker', 'Friendlies →'
          ));
        END IF;
      END IF;
    END IF;
  END IF;

  -- Single top international
  IF coalesce((p_internationals->>'enabled')::boolean, false) THEN
    SELECT value INTO v_row
    FROM jsonb_array_elements(
      coalesce(
        nullif(p_internationals->'shocks', '[]'::jsonb),
        p_internationals->'results',
        '[]'::jsonb
      )
    )
    ORDER BY coalesce((value->>'sort_score')::numeric, 0) DESC
    LIMIT 1;

    IF v_row IS NOT NULL THEN
      v_home := coalesce(v_row->>'home_name', 'Home');
      v_away := coalesce(v_row->>'away_name', 'Away');
      v_score := coalesce(v_row->>'score', '?-?');
      v_stories := v_stories || jsonb_build_array(jsonb_build_object(
        'headline', format('WORLD STAGE: %s %s %s', v_home, v_score, v_away),
        'body', format(
          E'The international splash of %s. Flags, tables and every other scoreline live on the Internationals tab.',
          p_month_label
        ),
        'story_kind', 'intl_highlight',
        'page_link', 'internationals',
        'kicker', 'Internationals →',
        'home_nation', v_row->>'home_nation',
        'away_nation', v_row->>'away_nation',
        'home_name', v_home,
        'away_name', v_away,
        'home_flag', v_row->>'home_flag',
        'away_flag', v_row->>'away_flag'
      ));
    END IF;
  END IF;

  IF v_f_count > 0 OR v_i_count > 0 THEN
    v_blurb := format(
      E'\n\nAlso in %s: %s confirmed club friendlies%s.',
      p_month_label,
      v_f_count,
      CASE
        WHEN v_i_count > 0 THEN format(' and %s international matches on the world stage', v_i_count)
        ELSE ''
      END
    );
  END IF;

  RETURN jsonb_build_object(
    'stories', coalesce(v_stories, '[]'::jsonb),
    'section_title', CASE
      WHEN jsonb_array_length(coalesce(v_stories, '[]'::jsonb)) > 0
        THEN 'Pre-season scorelines worth mentioning'
      ELSE NULL
    END,
    'lead_appendix', nullif(v_blurb, '')
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Internationals page: human splash, nation codes for flag images (no codes in headline)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_sport_build_internationals_page(
  p_season_id bigint,
  p_club_month text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_intl_month text;
  v_month_label text;
  v_played int := 0;
  v_results jsonb := '[]'::jsonb;
  v_shocks jsonb := '[]'::jsonb;
  v_groups jsonb := '[]'::jsonb;
  v_feats jsonb := '[]'::jsonb;
  v_lead_headline text;
  v_lead_subhead text;
  v_lead_body text;
  v_top jsonb;
  v_phase text;
  v_home text;
  v_away text;
  v_score text;
  v_margin int;
  v_home_seed int;
  v_away_seed int;
  v_group text;
  v_ko text;
  v_winner text;
  v_loser text;
  v_upset boolean := false;
  v_pre text;
  v_mid text;
  v_post text;
BEGIN
  IF to_regclass('public.international_fixtures') IS NULL THEN
    RETURN jsonb_build_object('enabled', false, 'reason', 'no_intl_tables');
  END IF;

  v_intl_month := public.gpsl_sport_resolve_intl_source_month(p_season_id, p_club_month);
  IF v_intl_month IS NULL THEN
    RETURN jsonb_build_object('enabled', false, 'reason', 'no_played_intl');
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_intl_month);

  SELECT count(*)::int INTO v_played
  FROM public.international_fixtures f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_intl_month
    AND f.played IS TRUE;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_score DESC, x.id), '[]'::jsonb)
  INTO v_results
  FROM (
    SELECT
      f.id,
      f.phase,
      f.home_nation,
      f.away_nation,
      hn.name AS home_name,
      an.name AS away_name,
      coalesce(hn.flag_emoji, '') AS home_flag,
      coalesce(an.flag_emoji, '') AS away_flag,
      hn.seed_rank AS home_seed,
      an.seed_rank AS away_seed,
      f.home_goals,
      f.away_goals,
      format('%s-%s', f.home_goals, f.away_goals) AS score,
      abs(coalesce(f.home_goals, 0) - coalesce(f.away_goals, 0)) AS margin,
      coalesce(qg.group_code, fg.group_code) AS group_code,
      kn.stage AS knockout_stage,
      (
        abs(coalesce(f.home_goals, 0) - coalesce(f.away_goals, 0)) * 10
        + greatest(0, coalesce(hn.seed_rank, 50) - coalesce(an.seed_rank, 50))
          * CASE WHEN f.home_goals > f.away_goals THEN 1 ELSE 0 END
        + greatest(0, coalesce(an.seed_rank, 50) - coalesce(hn.seed_rank, 50))
          * CASE WHEN f.away_goals > f.home_goals THEN 1 ELSE 0 END
      )::numeric AS sort_score
    FROM public.international_fixtures f
    JOIN public.international_nations hn ON hn.code = f.home_nation
    JOIN public.international_nations an ON an.code = f.away_nation
    LEFT JOIN public.international_qual_groups qg
      ON qg.id = f.group_id AND f.phase = 'qualifying'
    LEFT JOIN public.international_finals_groups fg
      ON fg.id = f.group_id AND f.phase = 'finals_group'
    LEFT JOIN public.international_knockout_nodes kn ON kn.id = f.knockout_node_id
    WHERE f.season_id = p_season_id
      AND lower(f.gpsl_month) = v_intl_month
      AND f.played IS TRUE
  ) x;

  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'sort_score')::numeric DESC), '[]'::jsonb)
  INTO v_shocks
  FROM (
    SELECT value AS r
    FROM jsonb_array_elements(v_results)
    WHERE (value->>'home_goals')::int <> (value->>'away_goals')::int
    ORDER BY (value->>'sort_score')::numeric DESC
    LIMIT 5
  ) s;

  IF to_regclass('public.international_qual_group_members') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(g ORDER BY g->>'group_code'), '[]'::jsonb)
    INTO v_groups
    FROM (
      SELECT jsonb_build_object(
        'phase', 'qualifying',
        'group_code', qg.group_code,
        'table', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
            'nation_code', m.nation_code,
            'nation_name', n.name,
            'flag', coalesce(n.flag_emoji, ''),
            'played', m.played,
            'won', m.won,
            'drawn', m.drawn,
            'lost', m.lost,
            'gf', m.goals_for,
            'ga', m.goals_against,
            'gd', m.goals_for - m.goals_against,
            'pts', m.points
          ) ORDER BY m.points DESC, (m.goals_for - m.goals_against) DESC, m.goals_for DESC, n.name), '[]'::jsonb)
          FROM public.international_qual_group_members m
          JOIN public.international_nations n ON n.code = m.nation_code
          WHERE m.group_id = qg.id
        )
      ) AS g
      FROM public.international_qual_groups qg
      WHERE EXISTS (
        SELECT 1 FROM public.international_fixtures f
        WHERE f.group_id = qg.id
          AND f.phase = 'qualifying'
          AND f.season_id = p_season_id
          AND lower(f.gpsl_month) = v_intl_month
          AND f.played IS TRUE
      )
    ) q;
  END IF;

  IF to_regclass('public.international_finals_group_members') IS NOT NULL THEN
    SELECT coalesce(v_groups, '[]'::jsonb) || coalesce(jsonb_agg(g ORDER BY g->>'group_code'), '[]'::jsonb)
    INTO v_groups
    FROM (
      SELECT jsonb_build_object(
        'phase', 'finals_group',
        'group_code', fg.group_code,
        'table', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
            'nation_code', m.nation_code,
            'nation_name', n.name,
            'flag', coalesce(n.flag_emoji, ''),
            'played', m.played,
            'won', m.won,
            'drawn', m.drawn,
            'lost', m.lost,
            'gf', m.goals_for,
            'ga', m.goals_against,
            'gd', m.goals_for - m.goals_against,
            'pts', m.points
          ) ORDER BY m.points DESC, (m.goals_for - m.goals_against) DESC, m.goals_for DESC, n.name), '[]'::jsonb)
          FROM public.international_finals_group_members m
          JOIN public.international_nations n ON n.code = m.nation_code
          WHERE m.group_id = fg.id
        )
      ) AS g
      FROM public.international_finals_groups fg
      WHERE EXISTS (
        SELECT 1 FROM public.international_fixtures f
        WHERE f.group_id = fg.id
          AND f.phase = 'finals_group'
          AND f.season_id = p_season_id
          AND lower(f.gpsl_month) = v_intl_month
          AND f.played IS TRUE
      )
    ) q;
  END IF;

  IF to_regclass('public.international_result_submissions') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.feat_score DESC, t.player_name), '[]'::jsonb)
    INTO v_feats
    FROM (
      SELECT
        p."Name" AS player_name,
        p."Konami_ID"::text AS player_id,
        sum(coalesce((item->>'goals')::int, 0)) AS goals,
        sum(coalesce((item->>'assists')::int, 0)) AS assists,
        max(coalesce((item->>'rating')::numeric, 0)) AS best_rating,
        bool_or(
          coalesce((item->>'potm')::boolean, false)
          OR coalesce((item->>'potm')::int, 0) > 0
        ) AS potm,
        (
          sum(coalesce((item->>'goals')::int, 0)) * 5
          + sum(coalesce((item->>'assists')::int, 0)) * 3
          + CASE WHEN bool_or(
              coalesce((item->>'potm')::boolean, false)
              OR coalesce((item->>'potm')::int, 0) > 0
            ) THEN 8 ELSE 0 END
          + max(coalesce((item->>'rating')::numeric, 0))
        ) AS feat_score
      FROM public.international_result_submissions s
      JOIN public.international_fixtures f ON f.id = s.fixture_id
      CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.player_stats, '[]'::jsonb)) item
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = item->>'player_id'
      WHERE s.status = 'confirmed'
        AND f.season_id = p_season_id
        AND lower(f.gpsl_month) = v_intl_month
        AND f.played IS TRUE
        AND nullif(item->>'player_id', '') IS NOT NULL
      GROUP BY p."Name", p."Konami_ID"
      HAVING
        sum(coalesce((item->>'goals')::int, 0)) > 0
        OR sum(coalesce((item->>'assists')::int, 0)) > 0
        OR bool_or(
          coalesce((item->>'potm')::boolean, false)
          OR coalesce((item->>'potm')::int, 0) > 0
        )
        OR max(coalesce((item->>'rating')::numeric, 0)) >= 8.5
      ORDER BY feat_score DESC, player_name
      LIMIT 10
    ) t;
  END IF;

  SELECT value INTO v_top
  FROM jsonb_array_elements(v_shocks)
  LIMIT 1;

  IF v_top IS NULL THEN
    SELECT value INTO v_top
    FROM jsonb_array_elements(v_results)
    LIMIT 1;
  END IF;

  SELECT f.phase INTO v_phase
  FROM public.international_fixtures f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_intl_month
    AND f.played IS TRUE
  GROUP BY f.phase
  ORDER BY count(*) DESC
  LIMIT 1;

  IF v_top IS NOT NULL THEN
    v_home := coalesce(v_top->>'home_name', 'Home');
    v_away := coalesce(v_top->>'away_name', 'Away');
    v_score := coalesce(v_top->>'score', '?-?');
    v_margin := coalesce((v_top->>'margin')::int, abs(
      coalesce((v_top->>'home_goals')::int, 0) - coalesce((v_top->>'away_goals')::int, 0)
    ));
    v_home_seed := nullif(v_top->>'home_seed', '')::int;
    v_away_seed := nullif(v_top->>'away_seed', '')::int;
    v_group := nullif(v_top->>'group_code', '');
    v_ko := nullif(v_top->>'knockout_stage', '');

    IF coalesce((v_top->>'home_goals')::int, 0) > coalesce((v_top->>'away_goals')::int, 0) THEN
      v_winner := v_home;
      v_loser := v_away;
      v_upset := (v_home_seed IS NOT NULL AND v_away_seed IS NOT NULL AND v_home_seed > v_away_seed + 4);
    ELSIF coalesce((v_top->>'away_goals')::int, 0) > coalesce((v_top->>'home_goals')::int, 0) THEN
      v_winner := v_away;
      v_loser := v_home;
      v_upset := (v_away_seed IS NOT NULL AND v_home_seed IS NOT NULL AND v_away_seed > v_home_seed + 4);
    ELSE
      v_winner := NULL;
      v_loser := NULL;
    END IF;

    v_lead_headline := format('%s %s %s — WORLD STAGE', v_home, v_score, v_away);
    v_lead_subhead := format(
      '%s internationals · %s played · %s',
      v_month_label,
      v_played,
      coalesce(v_ko, CASE WHEN v_group IS NOT NULL THEN 'Group ' || v_group ELSE coalesce(v_phase, 'window') END)
    );

    -- Prematch buildup
    v_pre := format(
      E'The %s window had the usual mix of call-ups, late fitness doubts and owners refreshing Discord an hour before kick-off. '
      || E'%s against %s was the fixture people circled%s%s.',
      v_month_label,
      v_home,
      v_away,
      CASE
        WHEN v_home_seed IS NOT NULL AND v_away_seed IS NOT NULL
          THEN format(' — seeds %s and %s on paper', v_home_seed, v_away_seed)
        ELSE ''
      END,
      CASE
        WHEN v_group IS NOT NULL THEN format(', with Group %s still taking shape', v_group)
        WHEN v_ko IS NOT NULL THEN format(' in the %s', v_ko)
        ELSE ''
      END
    );

    IF v_winner IS NOT NULL THEN
      IF v_upset THEN
        v_mid := format(
          E'Then the scoreboard told a different story: %s. %s did a number on %s%s — the kind of result that turns a quiet international break into a group-chat event.',
          v_score,
          v_winner,
          v_loser,
          CASE WHEN v_margin >= 3 THEN format(' by %s', v_margin) ELSE '' END
        );
      ELSIF v_margin >= 3 THEN
        v_mid := format(
          E'Ninety minutes later it was a thrashing: %s. %s never let %s settle; by the time the third went in, the chat had already moved from nerves to memes.',
          v_score, v_winner, v_loser
        );
      ELSE
        v_mid := format(
          E'It stayed tight until it did not — final score %s, %s edging %s in a proper international scrap.',
          v_score, v_winner, v_loser
        );
      END IF;
    ELSE
      v_mid := format(
        E'They cancelled each other out: %s. A share of the points, and plenty still to argue about in the tables below.',
        v_score
      );
    END IF;

    v_post := format(
      E'That is our splash from %s internationals across the window. Nation tables, shocks and every other scoreline are filed in this pullout — filed beside the %s club edition so you get league and country in one paper.',
      v_played,
      public.gpsl_sport_month_label(lower(btrim(p_club_month)))
    );

    v_lead_body := v_pre || E'\n\n' || v_mid || E'\n\n' || v_post;
  ELSE
    v_lead_headline := format('%s INTERNATIONALS ROUND-UP', upper(v_month_label));
    v_lead_subhead := format('%s fixtures on the world stage', v_played);
    v_lead_body := format(
      E'The %s international window is in the books — %s matches done. GPSL Sport has the results and nation tables in this pullout.',
      v_month_label, v_played
    );
  END IF;

  RETURN jsonb_build_object(
    'enabled', true,
    'page_title', 'Internationals',
    'source_month', v_intl_month,
    'source_month_label', v_month_label,
    'club_month', lower(btrim(p_club_month)),
    'played_count', v_played,
    'phase', v_phase,
    'lead', jsonb_build_object(
      'headline', v_lead_headline,
      'subhead', v_lead_subhead,
      'byline', 'GPSL Sport · Internationals desk',
      'body', v_lead_body,
      'home_nation', v_top->>'home_nation',
      'away_nation', v_top->>'away_nation',
      'home_name', v_top->>'home_name',
      'away_name', v_top->>'away_name',
      'home_flag', v_top->>'home_flag',
      'away_flag', v_top->>'away_flag',
      'score', v_top->>'score'
    ),
    'shocks', coalesce(v_shocks, '[]'::jsonb),
    'results', coalesce(v_results, '[]'::jsonb),
    'groups', coalesce(v_groups, '[]'::jsonb),
    'brilliant_performances', coalesce(v_feats, '[]'::jsonb)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Generate preseason: polish built edition before save / attach
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
  v_bounds record;
  v_built jsonb;
  v_intl jsonb;
  v_friendlies jsonb;
  v_mentions jsonb;
  v_front jsonb;
  v_back jsonb;
  v_seed text;
BEGIN
  IF v_month NOT IN ('june', 'july') THEN
    RETURN NULL;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND lower(e.gpsl_month) = v_month
  ORDER BY e.id DESC
  LIMIT 1;

  IF to_regprocedure('public.gpsl_sport_build_internationals_page(bigint, text)') IS NOT NULL THEN
    v_intl := public.gpsl_sport_build_internationals_page(p_season_id, v_month);
  ELSE
    v_intl := jsonb_build_object('enabled', false);
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_friendlies_page(bigint, text)') IS NOT NULL THEN
    v_friendlies := public.gpsl_sport_build_friendlies_page(p_season_id, v_month);
  ELSE
    v_friendlies := jsonb_build_object('enabled', false);
  END IF;

  v_mentions := public.gpsl_sport_build_preseason_front_mentions(
    v_friendlies, v_intl, v_month_label
  );

  -- Existing: re-slim / enrich + refresh extras
  IF v_existing IS NOT NULL THEN
    SELECT e.front_page, e.back_page INTO v_front, v_back
    FROM public.gpsl_sport_editions e
    WHERE e.id = v_existing;

    v_back := coalesce(v_back, '{}'::jsonb);
    IF coalesce((v_back->>'enabled')::boolean, false) THEN
      v_back := v_back || jsonb_build_object(
        'stories', public.gpsl_sport_enrich_transfer_stories(coalesce(v_back->'stories', '[]'::jsonb))
      );
    END IF;

    v_front := public.gpsl_sport_slim_preseason_front(v_front, v_back);
    v_front := public.gpsl_sport_merge_preseason_front_mentions(v_front, v_mentions);

    UPDATE public.gpsl_sport_editions e
    SET
      front_page = v_front,
      back_page = v_back,
      detail = coalesce(e.detail, '{}'::jsonb) || jsonb_build_object(
        'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false)),
        'friendlies_page', coalesce(v_friendlies, jsonb_build_object('enabled', false)),
        'preseason_results_attached_at', now(),
        'preseason_voice_slim_at', now()
      ),
      published_at = coalesce(e.published_at, now())
    WHERE e.id = v_existing;
    DELETE FROM public.gpsl_sport_reads r WHERE r.edition_id = v_existing;
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

  IF to_regprocedure('public.gpsl_sport_preseason_data_bounds(bigint, text)') IS NOT NULL THEN
    SELECT * INTO v_bounds
    FROM public.gpsl_sport_preseason_data_bounds(p_season_id, v_month);
  ELSE
    RETURN NULL;
  END IF;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_seed := p_season_id::text || ':' || v_month || ':preseason';

  v_built := public.gpsl_sport_build_transfer_edition(
    v_seed,
    v_month_label,
    v_bounds.window_start,
    v_bounds.window_end,
    true
  );

  v_built := public.gpsl_sport_polish_preseason_built(v_built);

  v_front := public.gpsl_sport_merge_preseason_front_mentions(
    v_built->'front_page',
    v_mentions
  );

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    v_month,
    v_month_label,
    v_built->>'story_type',
    v_front,
    coalesce(v_built->'back_page', '{}'::jsonb),
    jsonb_build_object(
      'generated_at', now(),
      'preseason', true,
      'preseason_weeks', v_win.preseason_weeks,
      'data_window_start', v_bounds.window_start,
      'data_window_end', v_bounds.window_end,
      'august_start', v_win.august_start,
      'managers_page', coalesce(v_built->'managers_page', '{}'::jsonb),
      'owners_page', coalesce(v_built->'owners_page', '{}'::jsonb),
      'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false)),
      'friendlies_page', coalesce(v_friendlies, jsonb_build_object('enabled', false)),
      'preseason_voice_slim_at', now()
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_compose_transfer_blurb(text, text, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_enrich_transfer_stories(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_slim_preseason_front(jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_polish_preseason_built(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_preseason_front_mentions(jsonb, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_internationals_page(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO service_role;

NOTIFY pgrst, 'reload schema';

-- SELECT public.gpsl_sport_attach_preseason_results('july', NULL);
-- SELECT public.gpsl_sport_attach_preseason_results('june', NULL);
-- Or full rebuild:
-- SELECT public.competition_admin_regenerate_gpsl_sport('july', NULL);
