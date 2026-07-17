-- =============================================================================
-- Active suspensions: expose pending red-card appeal for UI status
-- Shows "Suspended — Pending review" in squad / GPDB when appeal lodged.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_active_suspensions(
  p_club text DEFAULT NULL,
  p_player_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club), '');
BEGIN
  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x) ORDER BY x.player_id, x.suspension_id)
    FROM (
      SELECT
        s.id AS suspension_id,
        s.player_id,
        s.club_short_name,
        s.season_id,
        s.reason,
        s.yellow_count_at_issue,
        s.ban_matches,
        s.status,
        s.source_fixture_id,
        s.created_at,
        coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'fixture_id', sm.fixture_id,
              'sequence_no', sm.sequence_no,
              'served', sm.served,
              'label', public.competition_fixture_discipline_label(f, s.club_short_name),
              'matchday', f.matchday,
              'competition_type', f.competition_type
            )
            ORDER BY sm.sequence_no
          )
          FROM public.competition_player_suspension_matches sm
          JOIN public.competition_fixtures f ON f.id = sm.fixture_id
          WHERE sm.suspension_id = s.id
            AND sm.served = false
        ), '[]'::jsonb) AS pending_matches,
        (
          SELECT count(*)::int
          FROM public.competition_match_player_stats m
          WHERE m.season_id = s.season_id
            AND m.player_id = s.player_id
            AND m.yellow_card = true
        ) AS season_yellows,
        (
          SELECT count(*)::int
          FROM public.competition_match_player_stats m
          WHERE m.season_id = s.season_id
            AND m.player_id = s.player_id
            AND m.red_card = true
        ) AS season_reds,
        CASE
          WHEN to_regclass('public.competition_suspension_appeals') IS NULL THEN false
          ELSE EXISTS (
            SELECT 1
            FROM public.competition_suspension_appeals a
            WHERE a.suspension_id = s.id
              AND a.status = 'pending'
          )
        END AS appeal_pending
      FROM public.competition_player_suspensions s
      WHERE s.status = 'active'
        AND (v_club IS NULL OR s.club_short_name = v_club)
        AND (
          p_player_ids IS NULL
          OR cardinality(p_player_ids) = 0
          OR s.player_id = ANY (p_player_ids)
        )
        AND EXISTS (
          SELECT 1 FROM public.competition_player_suspension_matches sm
          WHERE sm.suspension_id = s.id AND sm.served = false
        )
    ) x
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_active_suspensions(text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_active_suspensions(text, text[]) TO anon;

NOTIFY pgrst, 'reload schema';
