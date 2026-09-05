-- =============================================================================
-- Suspension resync repair v3
--
-- Some suspensions already have served rows with non-contiguous sequence numbers
-- (for example only sequence 2 exists). Refill from max(served sequence_no)
-- instead of count(served rows).
--
-- Run after competition_suspension_resync_20260905.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_resync_pending_suspensions(
  p_season_id bigint DEFAULT NULL,
  p_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_fx record;
  v_done int := 0;
  v_season_id bigint := p_season_id;
  v_club text := nullif(btrim(coalesce(p_club, '')), '');
  v_served_count int;
  v_served_max_seq int;
  v_remaining int;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT s.id
    INTO v_season_id
    FROM public.competition_seasons s
    WHERE coalesce(s.is_current, false) = true
       OR s.status = 'active'
    ORDER BY coalesce(s.is_current, false) DESC, s.id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'updated', 0, 'reason', 'no_active_season');
  END IF;

  FOR v_row IN
    SELECT s.id, s.season_id, s.club_short_name, s.source_fixture_id, s.ban_matches
    FROM public.competition_player_suspensions s
    WHERE s.status = 'active'
      AND s.season_id = v_season_id
      AND (v_club IS NULL OR s.club_short_name = v_club)
  LOOP
    SELECT
      count(*)::int,
      coalesce(max(sm.sequence_no), 0)::int
    INTO v_served_count, v_served_max_seq
    FROM public.competition_player_suspension_matches sm
    WHERE sm.suspension_id = v_row.id
      AND sm.served = true;

    v_remaining := greatest(coalesce(v_row.ban_matches, 0) - coalesce(v_served_count, 0), 0);

    DELETE FROM public.competition_player_suspension_matches sm
    WHERE sm.suspension_id = v_row.id
      AND sm.served = false;

    IF v_remaining > 0 THEN
      FOR v_fx IN
        SELECT *
        FROM public.competition_next_club_fixtures(
          v_row.season_id,
          v_row.club_short_name,
          v_row.source_fixture_id,
          v_remaining
        )
      LOOP
        INSERT INTO public.competition_player_suspension_matches (
          suspension_id, fixture_id, sequence_no, served
        )
        VALUES (v_row.id, v_fx.fixture_id, v_served_max_seq + v_fx.seq, false)
        ON CONFLICT (suspension_id, fixture_id) DO NOTHING;
      END LOOP;
    END IF;

    UPDATE public.competition_player_suspensions s
    SET status = CASE
      WHEN EXISTS (
        SELECT 1
        FROM public.competition_player_suspension_matches sm
        WHERE sm.suspension_id = v_row.id
          AND sm.served = false
      ) THEN 'active'
      ELSE 'completed'
    END
    WHERE s.id = v_row.id;

    v_done := v_done + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'updated', v_done);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_resync_pending_suspensions(bigint, text)
  TO authenticated, service_role;

SELECT public.competition_resync_pending_suspensions(NULL, NULL);

NOTIFY pgrst, 'reload schema';
