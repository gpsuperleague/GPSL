-- =============================================================================
-- Player career bundle — include transfer history with fees per season
-- Run once in Supabase SQL Editor after competition_history.sql
-- =============================================================================

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
  v_awards jsonb;
  v_totals jsonb;
  v_transfers jsonb;
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
      p."Contracted_Team" AS current_club
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
    LIMIT 1
  ) p;

  SELECT coalesce(jsonb_agg(row_to_json(c) ORDER BY c.season_label DESC), '[]'::jsonb)
  INTO v_stints
  FROM public.competition_player_career_public c
  WHERE c.player_id = v_pid;

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
  ) t;

  RETURN jsonb_build_object(
    'player', coalesce(v_player, '{}'::jsonb),
    'stints', coalesce(v_stints, '[]'::jsonb),
    'awards', coalesce(v_awards, '[]'::jsonb),
    'totals', coalesce(v_totals, '{}'::jsonb),
    'transfers', coalesce(v_transfers, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_player_career_bundle(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
