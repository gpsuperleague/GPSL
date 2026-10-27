-- =============================================================================
-- Owner profile: attribute Transfer_History to ownership tenure only
--
-- Bug: spent / received / highest fee used every club the owner is linked to
-- for all time — so a new AC Milan owner inherited the previous owner's spend.
--
-- Fix: count transfers only while the owner held that club
--   • current club: transfer_time >= Clubs.owner_assigned_at
--   • past ranking seasons (other clubs): that season's window
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_profile_transfer_stats(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := p_owner_id;
  v_spent numeric := 0;
  v_received numeric := 0;
  v_high_paid jsonb;
  v_high_recv jsonb;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object(
      'spent', 0,
      'received', 0,
      'highest_fee_paid', NULL,
      'highest_fee_received', NULL
    );
  END IF;

  WITH tenure AS (
    -- Current ownership spell(s)
    SELECT
      c."ShortName" AS club_short_name,
      coalesce(
        c.owner_assigned_at,
        (SELECT s.started_at
         FROM public.competition_seasons s
         WHERE s.id = c.owner_assigned_season_id),
        (SELECT s.started_at
         FROM public.competition_seasons s
         WHERE s.is_current = true
         ORDER BY s.id DESC
         LIMIT 1),
        now()
      ) AS starts_at,
      NULL::timestamptz AS ends_at
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner

    UNION ALL

    -- Prior seasons from ranking (skip current club — covered above)
    SELECT
      r.club_short_name,
      coalesce(s.started_at, s.created_at) AS starts_at,
      CASE
        WHEN coalesce(s.is_current, false) THEN now()
        ELSE coalesce(
          (
            SELECT s2.started_at
            FROM public.competition_seasons s2
            WHERE s2.id > s.id
            ORDER BY s2.id
            LIMIT 1
          ),
          coalesce(s.started_at, s.created_at) + interval '400 days'
        )
      END AS ends_at
    FROM public.competition_owner_season_ranking r
    JOIN public.competition_seasons s ON s.id = r.season_id
    WHERE r.owner_id = v_owner
      AND NOT EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c.owner_id = v_owner
          AND c."ShortName" = r.club_short_name
      )
  ),
  hits AS (
    SELECT
      th.id,
      th.fee,
      th.agent_fee,
      th.player_id,
      th.buyer_club_id,
      th.seller_club_id,
      th.foreign_buyer_name,
      th.transfer_time,
      bool_or(th.buyer_club_id = t.club_short_name) AS is_buy,
      bool_or(th.seller_club_id = t.club_short_name) AS is_sell
    FROM public."Transfer_History" th
    JOIN tenure t
      ON (th.buyer_club_id = t.club_short_name
          OR th.seller_club_id = t.club_short_name)
     AND th.transfer_time >= t.starts_at
     AND (t.ends_at IS NULL OR th.transfer_time < t.ends_at)
    GROUP BY
      th.id, th.fee, th.agent_fee, th.player_id, th.buyer_club_id,
      th.seller_club_id, th.foreign_buyer_name, th.transfer_time
  )
  SELECT
    coalesce(sum(
      CASE WHEN h.is_buy THEN coalesce(h.fee, 0) + coalesce(h.agent_fee, 0) ELSE 0 END
    ), 0),
    coalesce(sum(
      CASE WHEN h.is_sell THEN coalesce(h.fee, 0) ELSE 0 END
    ), 0)
  INTO v_spent, v_received
  FROM hits h;

  WITH tenure AS (
    SELECT
      c."ShortName" AS club_short_name,
      coalesce(
        c.owner_assigned_at,
        (SELECT s.started_at FROM public.competition_seasons s WHERE s.id = c.owner_assigned_season_id),
        (SELECT s.started_at FROM public.competition_seasons s WHERE s.is_current = true ORDER BY s.id DESC LIMIT 1),
        now()
      ) AS starts_at,
      NULL::timestamptz AS ends_at
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner
    UNION ALL
    SELECT
      r.club_short_name,
      coalesce(s.started_at, s.created_at),
      CASE
        WHEN coalesce(s.is_current, false) THEN now()
        ELSE coalesce(
          (SELECT s2.started_at FROM public.competition_seasons s2 WHERE s2.id > s.id ORDER BY s2.id LIMIT 1),
          coalesce(s.started_at, s.created_at) + interval '400 days'
        )
      END
    FROM public.competition_owner_season_ranking r
    JOIN public.competition_seasons s ON s.id = r.season_id
    WHERE r.owner_id = v_owner
      AND NOT EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c.owner_id = v_owner AND c."ShortName" = r.club_short_name
      )
  )
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
  JOIN tenure t
    ON th.buyer_club_id = t.club_short_name
   AND th.transfer_time >= t.starts_at
   AND (t.ends_at IS NULL OR th.transfer_time < t.ends_at)
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id::text
  WHERE coalesce(th.fee, 0) > 0
  ORDER BY th.fee DESC, th.transfer_time DESC NULLS LAST
  LIMIT 1;

  WITH tenure AS (
    SELECT
      c."ShortName" AS club_short_name,
      coalesce(
        c.owner_assigned_at,
        (SELECT s.started_at FROM public.competition_seasons s WHERE s.id = c.owner_assigned_season_id),
        (SELECT s.started_at FROM public.competition_seasons s WHERE s.is_current = true ORDER BY s.id DESC LIMIT 1),
        now()
      ) AS starts_at,
      NULL::timestamptz AS ends_at
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner
    UNION ALL
    SELECT
      r.club_short_name,
      coalesce(s.started_at, s.created_at),
      CASE
        WHEN coalesce(s.is_current, false) THEN now()
        ELSE coalesce(
          (SELECT s2.started_at FROM public.competition_seasons s2 WHERE s2.id > s.id ORDER BY s2.id LIMIT 1),
          coalesce(s.started_at, s.created_at) + interval '400 days'
        )
      END
    FROM public.competition_owner_season_ranking r
    JOIN public.competition_seasons s ON s.id = r.season_id
    WHERE r.owner_id = v_owner
      AND NOT EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c.owner_id = v_owner AND c."ShortName" = r.club_short_name
      )
  )
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
  JOIN tenure t
    ON th.seller_club_id = t.club_short_name
   AND th.transfer_time >= t.starts_at
   AND (t.ends_at IS NULL OR th.transfer_time < t.ends_at)
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id::text
  WHERE coalesce(th.fee, 0) > 0
  ORDER BY th.fee DESC, th.transfer_time DESC NULLS LAST
  LIMIT 1;

  RETURN jsonb_build_object(
    'spent', coalesce(v_spent, 0),
    'received', coalesce(v_received, 0),
    'highest_fee_paid', v_high_paid,
    'highest_fee_received', v_high_recv
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_profile_transfer_stats(uuid)
  TO authenticated, anon;

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
  v_achievements jsonb;
  v_xfer jsonb;
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

  v_xfer := public.owner_profile_transfer_stats(v_owner);
  v_transfers := jsonb_build_object(
    'spent', coalesce((v_xfer->>'spent')::numeric, 0),
    'received', coalesce((v_xfer->>'received')::numeric, 0)
  );
  v_high_paid := v_xfer->'highest_fee_paid';
  IF v_high_paid = 'null'::jsonb THEN v_high_paid := NULL; END IF;
  v_high_recv := v_xfer->'highest_fee_received';
  IF v_high_recv = 'null'::jsonb THEN v_high_recv := NULL; END IF;

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

  v_achievements := public.owner_profile_personal_achievements(v_owner);

  RETURN jsonb_build_object(
    'ok', true,
    'profile', v_profile,
    'career_totals', v_totals,
    'seasons', v_seasons,
    'transfers', v_transfers,
    'highest_fee_paid', v_high_paid,
    'highest_fee_received', v_high_recv,
    'trophies', v_trophies,
    'awards', v_awards,
    'achievements', v_achievements
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO anon;

NOTIFY pgrst, 'reload schema';
