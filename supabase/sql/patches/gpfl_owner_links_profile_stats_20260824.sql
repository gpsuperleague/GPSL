-- =============================================================================
-- GPFL owner profile links + richer owner career stats
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Owner profile: draw/loss %, avg GF/GA, clean sheet %
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_profile_bundle(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := p_owner_id;
  v_profile jsonb;
  v_seasons jsonb;
  v_totals jsonb;
  v_transfers jsonb;
  v_high_paid jsonb;
  v_high_recv jsonb;
  v_trophies jsonb;
  v_awards jsonb;
  v_clubs text[];
  v_cs_pct numeric;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_owner');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.gpsl_owner_registry r WHERE r.owner_id = v_owner)
     AND EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner)
  THEN
    INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name)
    SELECT
      c.owner_id,
      'active',
      nullif(btrim(c.owner), ''),
      c."ShortName"
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner
    ON CONFLICT (owner_id) DO NOTHING;
  END IF;

  SELECT jsonb_build_object(
    'owner_id', p.owner_id,
    'owner_tag', p.owner_tag,
    'owner_name', p.owner_name,
    'status', p.status,
    'current_club_short_name', p.current_club_short_name,
    'current_club_name', p.current_club_name,
    'nation_code', p.last_nation_code,
    'nation_name', p.nation_name,
    'flag_emoji', p.flag_emoji,
    'badge_path', p.badge_path,
    'is_self', (auth.uid() IS NOT NULL AND auth.uid() = p.owner_id)
  )
  INTO v_profile
  FROM public.gpsl_owner_profile_public p
  WHERE p.owner_id = v_owner;

  IF v_profile IS NULL THEN
    SELECT jsonb_build_object(
      'owner_id', v_owner,
      'owner_tag', public.owner_registry_resolve_tag(v_owner),
      'owner_name', public.competition_owner_display_name(v_owner),
      'status', NULL,
      'current_club_short_name', c."ShortName",
      'current_club_name', c."Club",
      'nation_code', ion.nation_code,
      'nation_name', n.name,
      'flag_emoji', n.flag_emoji,
      'badge_path', NULL,
      'is_self', (auth.uid() IS NOT NULL AND auth.uid() = v_owner)
    )
    INTO v_profile
    FROM (SELECT v_owner AS owner_id) o
    LEFT JOIN public."Clubs" c ON c.owner_id = v_owner
    LEFT JOIN public.international_owner_nations ion
      ON ion.club_short_name = c."ShortName" AND ion.is_active = true
    LEFT JOIN public.international_nations n ON n.code = ion.nation_code;
  END IF;

  SELECT array_agg(DISTINCT r.club_short_name)
  INTO v_clubs
  FROM public.competition_owner_season_ranking r
  WHERE r.owner_id = v_owner;

  IF v_clubs IS NULL THEN
    SELECT array_agg(c."ShortName")
    INTO v_clubs
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.season_id DESC), '[]'::jsonb)
  INTO v_seasons
  FROM (
    SELECT
      h.season_id,
      h.season_label,
      h.club_short_name,
      h.club_name,
      h.division,
      h.final_position,
      h.mp,
      h.won,
      h.drawn,
      h.lost,
      h.gf,
      h.ga,
      h.gd,
      h.pts,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(100.0 * h.won::numeric / h.mp::numeric, 1)
        ELSE NULL
      END AS win_pct,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(100.0 * h.drawn::numeric / h.mp::numeric, 1)
        ELSE NULL
      END AS draw_pct,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(100.0 * h.lost::numeric / h.mp::numeric, 1)
        ELSE NULL
      END AS loss_pct,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(h.gf::numeric / h.mp::numeric, 2)
        ELSE NULL
      END AS avg_gf,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(h.ga::numeric / h.mp::numeric, 2)
        ELSE NULL
      END AS avg_ga
    FROM public.competition_club_season_history_public h
    JOIN public.competition_owner_season_ranking r
      ON r.season_id = h.season_id
     AND r.club_short_name = h.club_short_name
     AND r.owner_id = v_owner
  ) s;

  -- Clean sheets while this owner ran the club (played fixtures, 0 conceded)
  SELECT
    CASE
      WHEN count(*) = 0 THEN NULL
      ELSE round(
        100.0 * count(*) FILTER (WHERE g.conceded = 0)::numeric / count(*)::numeric,
        1
      )
    END
  INTO v_cs_pct
  FROM (
    SELECT
      CASE
        WHEN f.home_club_short_name = r.club_short_name THEN coalesce(f.away_goals, 0)
        ELSE coalesce(f.home_goals, 0)
      END AS conceded
    FROM public.competition_owner_season_ranking r
    JOIN public.competition_fixtures f
      ON f.season_id = r.season_id
     AND f.status = 'played'
     AND (
       f.home_club_short_name = r.club_short_name
       OR f.away_club_short_name = r.club_short_name
     )
    WHERE r.owner_id = v_owner
  ) g;

  SELECT jsonb_build_object(
    'seasons', coalesce(count(*), 0),
    'mp', coalesce(sum(mp), 0),
    'won', coalesce(sum(won), 0),
    'drawn', coalesce(sum(drawn), 0),
    'lost', coalesce(sum(lost), 0),
    'gf', coalesce(sum(gf), 0),
    'ga', coalesce(sum(ga), 0),
    'gd', coalesce(sum(gd), 0),
    'pts', coalesce(sum(pts), 0),
    'win_pct', CASE
      WHEN coalesce(sum(mp), 0) > 0
      THEN round(100.0 * sum(won)::numeric / sum(mp)::numeric, 1)
      ELSE NULL
    END,
    'draw_pct', CASE
      WHEN coalesce(sum(mp), 0) > 0
      THEN round(100.0 * sum(drawn)::numeric / sum(mp)::numeric, 1)
      ELSE NULL
    END,
    'loss_pct', CASE
      WHEN coalesce(sum(mp), 0) > 0
      THEN round(100.0 * sum(lost)::numeric / sum(mp)::numeric, 1)
      ELSE NULL
    END,
    'avg_gf', CASE
      WHEN coalesce(sum(mp), 0) > 0
      THEN round(sum(gf)::numeric / sum(mp)::numeric, 2)
      ELSE NULL
    END,
    'avg_ga', CASE
      WHEN coalesce(sum(mp), 0) > 0
      THEN round(sum(ga)::numeric / sum(mp)::numeric, 2)
      ELSE NULL
    END,
    'clean_sheet_pct', v_cs_pct
  )
  INTO v_totals
  FROM (
    SELECT h.mp, h.won, h.drawn, h.lost, h.gf, h.ga, h.gd, h.pts
    FROM public.competition_club_season_history_public h
    JOIN public.competition_owner_season_ranking r
      ON r.season_id = h.season_id
     AND r.club_short_name = h.club_short_name
     AND r.owner_id = v_owner
  ) x;

  SELECT jsonb_build_object(
    'spent', coalesce(sum(CASE WHEN th.buyer_club_id = ANY (v_clubs) THEN coalesce(th.fee, 0) + coalesce(th.agent_fee, 0) ELSE 0 END), 0),
    'received', coalesce(sum(CASE WHEN th.seller_club_id = ANY (v_clubs) THEN coalesce(th.fee, 0) ELSE 0 END), 0)
  )
  INTO v_transfers
  FROM public."Transfer_History" th
  WHERE v_clubs IS NOT NULL
    AND (th.buyer_club_id = ANY (v_clubs) OR th.seller_club_id = ANY (v_clubs));

  SELECT jsonb_build_object(
    'fee', th.fee,
    'agent_fee', th.agent_fee,
    'player_id', th.player_id,
    'player_name', p."Name",
    'club_short_name', th.buyer_club_id,
    'seller_club_id', th.seller_club_id,
    'transfer_time', th.transfer_time,
    'season_label', public.transfer_history_season_label(th.transfer_time)
  )
  INTO v_high_paid
  FROM public."Transfer_History" th
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id::text
  WHERE v_clubs IS NOT NULL
    AND th.buyer_club_id = ANY (v_clubs)
    AND coalesce(th.fee, 0) > 0
  ORDER BY th.fee DESC, th.transfer_time DESC NULLS LAST
  LIMIT 1;

  SELECT jsonb_build_object(
    'fee', th.fee,
    'player_id', th.player_id,
    'player_name', p."Name",
    'club_short_name', th.seller_club_id,
    'buyer_club_id', th.buyer_club_id,
    'foreign_buyer_name', th.foreign_buyer_name,
    'transfer_time', th.transfer_time,
    'season_label', public.transfer_history_season_label(th.transfer_time)
  )
  INTO v_high_recv
  FROM public."Transfer_History" th
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id::text
  WHERE v_clubs IS NOT NULL
    AND th.seller_club_id = ANY (v_clubs)
    AND coalesce(th.fee, 0) > 0
  ORDER BY th.fee DESC, th.transfer_time DESC NULLS LAST
  LIMIT 1;

  SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.season_id DESC, h.honour_label), '[]'::jsonb)
  INTO v_trophies
  FROM public.competition_club_honours_public h
  JOIN public.competition_owner_season_ranking r
    ON r.season_id = h.season_id
   AND r.club_short_name = h.club_short_name
   AND r.owner_id = v_owner;

  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.season_id DESC, a.award_type), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  JOIN public.competition_owner_season_ranking r
    ON r.season_id = a.season_id
   AND r.club_short_name = a.club_short_name
   AND r.owner_id = v_owner
  WHERE a.award_type IN (
    'ballon_dor',
    'golden_boot',
    'golden_playmaker',
    'golden_glove',
    'season_potm',
    'championship_player_of_season',
    'team_of_season'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'profile', v_profile,
    'career_totals', v_totals,
    'seasons', v_seasons,
    'transfers', v_transfers,
    'highest_fee_paid', v_high_paid,
    'highest_fee_received', v_high_recv,
    'trophies', v_trophies,
    'awards', v_awards
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO anon;

-- ---------------------------------------------------------------------------
-- GPFL leaderboard: include owner_id for profile links
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_leaderboard(p_limit int DEFAULT 60)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_rows jsonb;
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.rank), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      row_number() OVER (ORDER BY e.total_points DESC, e.joined_at)::int AS rank,
      e.team_name,
      e.club_short_name,
      e.owner_id,
      public.competition_owner_display_name(e.owner_id) AS owner_name,
      public.owner_registry_resolve_tag(e.owner_id) AS owner_tag,
      e.total_points,
      e.status,
      e.owner_id = auth.uid() AS is_me
    FROM public.gpfl_entries e
    WHERE e.gpfl_season_id = v_gs_id
      AND e.status IN ('active', 'building')
    ORDER BY e.total_points DESC, e.joined_at
    LIMIT greatest(1, least(coalesce(p_limit, 60), 200))
  ) r;

  RETURN jsonb_build_object('ok', true, 'gpfl_season_id', v_gs_id, 'rows', v_rows);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_leaderboard(int) TO authenticated;

-- ---------------------------------------------------------------------------
-- GPFL prizes board: include owner_id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_prizes_board(
  p_gpfl_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_cfg public.gpfl_settings%rowtype;
  v_payouts jsonb := '[]'::jsonb;
BEGIN
  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  IF v_gs_id IS NOT NULL THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'scope', r.scope,
          'gpsl_month', r.gpsl_month,
          'place', r.place,
          'amount', r.amount,
          'paid_at', r.paid_at,
          'team_name', r.team_name,
          'owner_id', r.owner_id,
          'owner_name', r.owner_name,
          'owner_tag', r.owner_tag,
          'is_me', r.is_me
        )
        ORDER BY r.sort_scope, r.sort_month, r.place
      ),
      '[]'::jsonb
    )
    INTO v_payouts
    FROM (
      SELECT
        p.scope,
        p.gpsl_month,
        p.place,
        p.amount,
        p.created_at AS paid_at,
        e.team_name,
        p.owner_id,
        public.competition_owner_display_name(p.owner_id) AS owner_name,
        public.owner_registry_resolve_tag(p.owner_id) AS owner_tag,
        p.owner_id = auth.uid() AS is_me,
        CASE WHEN p.scope = 'season' THEN 0 ELSE 1 END AS sort_scope,
        CASE lower(coalesce(p.gpsl_month, ''))
          WHEN 'august' THEN 1
          WHEN 'september' THEN 2
          WHEN 'october' THEN 3
          WHEN 'november' THEN 4
          WHEN 'december' THEN 5
          WHEN 'january' THEN 6
          WHEN 'february' THEN 7
          WHEN 'march' THEN 8
          WHEN 'april' THEN 9
          WHEN 'may' THEN 10
          ELSE 99
        END AS sort_month
      FROM public.gpfl_prize_payouts p
      LEFT JOIN public.gpfl_entries e ON e.id = p.entry_id
      WHERE p.gpfl_season_id = v_gs_id
    ) r;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'enabled', coalesce(v_cfg.cash_prizes_enabled, false),
    'season', jsonb_build_array(
      jsonb_build_object('place', 1, 'amount', coalesce(v_cfg.prize_season_1, 0)),
      jsonb_build_object('place', 2, 'amount', coalesce(v_cfg.prize_season_2, 0)),
      jsonb_build_object('place', 3, 'amount', coalesce(v_cfg.prize_season_3, 0))
    ),
    'month', jsonb_build_array(
      jsonb_build_object('place', 1, 'amount', coalesce(v_cfg.prize_month_1, 0)),
      jsonb_build_object('place', 2, 'amount', coalesce(v_cfg.prize_month_2, 0)),
      jsonb_build_object('place', 3, 'amount', coalesce(v_cfg.prize_month_3, 0))
    ),
    'payouts', coalesce(v_payouts, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_prizes_board(bigint) TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- GPFL list players: include club owner_id (keeps exclude-own-clubs behaviour)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_list_players(
  p_position_group text DEFAULT NULL,
  p_division text DEFAULT NULL,
  p_club text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_max_price numeric DEFAULT NULL,
  p_limit int DEFAULT 80,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_comp_id bigint;
  v_cfg public.gpfl_settings%rowtype;
  v_rows jsonb;
  v_total int;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_uid uuid := auth.uid();
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season', 'players', '[]'::jsonb);
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  SELECT gs.competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT count(*)::int INTO v_total
  FROM public.gpfl_player_prices pp
  JOIN public."Players" p ON p."Konami_ID"::text = pp.player_id
  JOIN public.competition_club_seasons ccs
    ON ccs.club_short_name = p."Contracted_Team"
   AND ccs.season_id = v_comp_id
  JOIN public."Clubs" c
    ON c."ShortName" = p."Contracted_Team"
   AND c.owner_id IS NOT NULL
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND p."Contracted_Team" IS NOT NULL
    AND btrim(p."Contracted_Team") <> ''
    AND ccs.division = ANY (v_cfg.divisions)
    AND (v_uid IS NULL OR c.owner_id IS DISTINCT FROM v_uid)
    AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
    AND (p_division IS NULL OR ccs.division = p_division OR pp.division = p_division)
    AND (
      p_club IS NULL
      OR p."Contracted_Team" = p_club
      OR pp.club_short_name = p_club
      OR coalesce(c."Club", '') ILIKE p_club
    )
    AND (p_max_price IS NULL OR pp.price <= p_max_price)
    AND (
      v_q IS NULL
      OR pp.player_name ILIKE '%' || v_q || '%'
      OR p."Name" ILIKE '%' || v_q || '%'
      OR p."Contracted_Team" ILIKE '%' || v_q || '%'
      OR pp.club_short_name ILIKE '%' || v_q || '%'
      OR coalesce(c."Club", '') ILIKE '%' || v_q || '%'
      OR coalesce(public.competition_owner_display_name(c.owner_id), '') ILIKE '%' || v_q || '%'
      OR coalesce(c.owner, '') ILIKE '%' || v_q || '%'
    );

  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      pp.player_id,
      coalesce(nullif(btrim(p."Name"), ''), pp.player_name) AS player_name,
      p."Contracted_Team" AS club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), p."Contracted_Team") AS club_name,
      c.owner_id,
      coalesce(
        nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
        nullif(btrim(c.owner), ''),
        'Owner'
      ) AS owner_name,
      ccs.division,
      coalesce(nullif(btrim(p."Position"::text), ''), pp.position) AS position,
      pp.position_group,
      pp.price,
      pp.market_value_raw,
      public.gpfl_ownership_pct(v_gs_id, pp.player_id) AS ownership_pct,
      coalesce((
        SELECT sum(pfp.points)
        FROM public.gpfl_player_fixture_points pfp
        WHERE pfp.gpfl_season_id = v_gs_id
          AND pfp.player_id = pp.player_id
      ), 0) AS total_points
    FROM public.gpfl_player_prices pp
    JOIN public."Players" p ON p."Konami_ID"::text = pp.player_id
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = p."Contracted_Team"
     AND ccs.season_id = v_comp_id
    JOIN public."Clubs" c
      ON c."ShortName" = p."Contracted_Team"
     AND c.owner_id IS NOT NULL
    WHERE pp.gpfl_season_id = v_gs_id
      AND pp.eligible = true
      AND p."Contracted_Team" IS NOT NULL
      AND btrim(p."Contracted_Team") <> ''
      AND ccs.division = ANY (v_cfg.divisions)
      AND (v_uid IS NULL OR c.owner_id IS DISTINCT FROM v_uid)
      AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
      AND (p_division IS NULL OR ccs.division = p_division OR pp.division = p_division)
      AND (
        p_club IS NULL
        OR p."Contracted_Team" = p_club
        OR pp.club_short_name = p_club
        OR coalesce(c."Club", '') ILIKE p_club
      )
      AND (p_max_price IS NULL OR pp.price <= p_max_price)
      AND (
        v_q IS NULL
        OR pp.player_name ILIKE '%' || v_q || '%'
        OR p."Name" ILIKE '%' || v_q || '%'
        OR p."Contracted_Team" ILIKE '%' || v_q || '%'
        OR pp.club_short_name ILIKE '%' || v_q || '%'
        OR coalesce(c."Club", '') ILIKE '%' || v_q || '%'
        OR coalesce(public.competition_owner_display_name(c.owner_id), '') ILIKE '%' || v_q || '%'
        OR coalesce(c.owner, '') ILIKE '%' || v_q || '%'
      )
    ORDER BY pp.price DESC, coalesce(p."Name", pp.player_name)
    LIMIT greatest(1, least(coalesce(p_limit, 80), 200))
    OFFSET greatest(0, coalesce(p_offset, 0))
  ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'total', v_total,
    'players', v_rows,
    'contracted_only', true,
    'owned_clubs_only', true,
    'exclude_own_clubs', true,
    'editing_open', public.gpfl_editing_open(v_comp_id)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_list_players(text, text, text, text, numeric, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
