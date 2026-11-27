-- Player career: appearances split by competition (league + cups, not World Cup).
-- Adds competitions[] on competition_player_career_bundle. Safe re-run.

CREATE OR REPLACE FUNCTION public.competition_player_career_bundle(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_player jsonb;
  v_stints jsonb;
  v_honours jsonb;
  v_awards jsonb;
  v_totals jsonb;
  v_transfers jsonb;
  v_discipline jsonb;
  v_competitions jsonb;
BEGIN
  SELECT to_jsonb(p)
  INTO v_player
  FROM (
    SELECT
      p."Konami_ID" AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Rating" AS rating,
      p."Nation" AS nation,
      p."Contracted_Team" AS current_club,
      p."Height" AS height_cm,
      p."Stronger_Foot" AS stronger_foot,
      p."Weak_Foot_Usage" AS weak_foot_usage,
      p."Weak_Foot_Accuracy" AS weak_foot_accuracy
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
    LIMIT 1
  ) p;

  SELECT coalesce(jsonb_agg(row_to_json(c) ORDER BY c.season_label DESC), '[]'::jsonb)
  INTO v_stints
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(h) ORDER BY h.honoured_at DESC), '[]'::jsonb)
  INTO v_honours
  FROM public.competition_player_honours_public h
  WHERE h.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(a) ORDER BY a.season_label DESC), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  WHERE a.player_id = v_pid;

  SELECT jsonb_build_object(
    'appearances', coalesce(sum(appearances), 0),
    'goals', coalesce(sum(goals), 0),
    'assists', coalesce(sum(assists), 0),
    'potm_awards', coalesce(sum(potm_awards), 0),
    'clean_sheets', coalesce(sum(clean_sheets), 0),
    'avg_rating', round(avg(avg_rating) FILTER (WHERE avg_rating IS NOT NULL), 2)
  )
  INTO v_totals
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

  SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.transfer_time DESC), '[]'::jsonb)
  INTO v_transfers
  FROM (
    SELECT
      h.player_id::text AS player_id,
      public.transfer_history_season_label(h.transfer_time) AS season_label,
      h.transfer_time,
      h.seller_club_id AS seller_club_short_name,
      h.buyer_club_id AS buyer_club_short_name,
      h.foreign_buyer_name,
      h.transfer_sale_note,
      coalesce(h.fee, 0)::numeric AS fee,
      coalesce(h.agent_fee, 0)::numeric AS agent_fee,
      (coalesce(h.fee, 0) + coalesce(h.agent_fee, 0))::numeric AS total_cost,
      CASE
        WHEN coalesce(h.fee, 0) <= 0 THEN 'free'
        WHEN h.transfer_sale_note = 'squad_overflow' THEN 'overflow_release'
        WHEN h.foreign_buyer_name IS NOT NULL AND btrim(h.foreign_buyer_name) <> '' THEN 'foreign_sale'
        ELSE 'transfer'
      END AS move_kind
    FROM public."Transfer_History" h
    WHERE h.player_id::text = v_pid
      AND coalesce(h.transfer_sale_note, '') IS DISTINCT FROM 'admin_reversed'
      AND coalesce(h.transfer_sale_note, '') NOT LIKE 'admin_reversed%'
  ) t;

  SELECT coalesce(jsonb_agg(row_to_json(d) ORDER BY d.created_at DESC), '[]'::jsonb)
  INTO v_discipline
  FROM (
    SELECT
      s.id AS suspension_id,
      s.season_id,
      se.label AS season_label,
      s.club_short_name,
      s.reason,
      s.yellow_count_at_issue,
      s.ban_matches,
      s.status,
      s.source_fixture_id,
      s.created_at,
      CASE
        WHEN s.reason = 'red_card' THEN 'Red card — 2 match ban'
        WHEN s.reason = 'yellow_accumulation' THEN
          format('Yellow card accumulation (%s) — 2 match ban', coalesce(s.yellow_count_at_issue, 8))
        ELSE s.reason
      END AS summary,
      coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'fixture_id', sm.fixture_id,
            'sequence_no', sm.sequence_no,
            'served', sm.served,
            'label', public.competition_fixture_discipline_label(f, s.club_short_name)
          )
          ORDER BY sm.sequence_no
        )
        FROM public.competition_player_suspension_matches sm
        JOIN public.competition_fixtures f ON f.id = sm.fixture_id
        WHERE sm.suspension_id = s.id
      ), '[]'::jsonb) AS matches
    FROM public.competition_player_suspensions s
    LEFT JOIN public.competition_seasons se ON se.id = s.season_id
    WHERE s.player_id = v_pid
  ) d;

  SELECT coalesce(
    jsonb_agg(
      row_to_json(x)
      ORDER BY x.season_id DESC, x.is_league DESC, x.competition_code, x.club_short_name
    ),
    '[]'::jsonb
  )
  INTO v_competitions
  FROM (
    SELECT
      m.season_id,
      s.label AS season_label,
      m.club_short_name,
      c."Club" AS club_name,
      CASE
        WHEN lower(coalesce(f.competition_type, 'league')) = 'league' THEN 'league'
        ELSE coalesce(nullif(btrim(f.cup_code), ''), 'cup')
      END AS competition_code,
      CASE
        WHEN lower(coalesce(f.competition_type, 'league')) = 'league'
          THEN coalesce(ccs.division, ca.division)
        ELSE NULL
      END AS division,
      (lower(coalesce(f.competition_type, 'league')) = 'league') AS is_league,
      count(*) FILTER (WHERE m.appeared)::int AS appearances,
      coalesce(sum(m.goals), 0)::int AS goals,
      coalesce(sum(m.assists), 0)::int AS assists,
      round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    JOIN public.competition_seasons s ON s.id = m.season_id
    JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
    LEFT JOIN public.competition_club_seasons ccs
      ON ccs.season_id = m.season_id AND ccs.club_short_name = m.club_short_name
    LEFT JOIN public.competition_club_season_archive ca
      ON ca.season_id = m.season_id AND ca.club_short_name = m.club_short_name
    WHERE m.player_id = v_pid
      AND f.status = 'played'
      AND lower(coalesce(f.competition_type, 'league')) IN ('league', 'cup')
      AND public.competition_fixture_counts_in_tables(f.id)
    GROUP BY
      m.season_id,
      s.label,
      m.club_short_name,
      c."Club",
      CASE
        WHEN lower(coalesce(f.competition_type, 'league')) = 'league' THEN 'league'
        ELSE coalesce(nullif(btrim(f.cup_code), ''), 'cup')
      END,
      CASE
        WHEN lower(coalesce(f.competition_type, 'league')) = 'league'
          THEN coalesce(ccs.division, ca.division)
        ELSE NULL
      END,
      (lower(coalesce(f.competition_type, 'league')) = 'league')
    HAVING count(*) FILTER (WHERE m.appeared) > 0
  ) x;

  RETURN jsonb_build_object(
    'player', coalesce(v_player, '{}'::jsonb),
    'stints', coalesce(v_stints, '[]'::jsonb),
    'competitions', coalesce(v_competitions, '[]'::jsonb),
    'honours', coalesce(v_honours, '[]'::jsonb),
    'awards', coalesce(v_awards, '[]'::jsonb),
    'totals', coalesce(v_totals, '{}'::jsonb),
    'transfers', coalesce(v_transfers, '[]'::jsonb),
    'discipline', coalesce(v_discipline, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_player_career_bundle(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
