-- =============================================================================
-- Transfer: move active injuries + match fitness with the player
--
-- Also: clear unserved injury_fixture links (old club's fixtures) so the new
-- club ticks remaining matches on their own schedule.
--
-- Hook: AFTER UPDATE OF Contracted_Team on Players (covers all assign paths).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_move_player_medical_to_club(
  p_player_id text,
  p_to_club text,
  p_from_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := nullif(btrim(p_player_id), '');
  v_to text := upper(nullif(btrim(p_to_club), ''));
  v_from text := upper(nullif(btrim(coalesce(p_from_club, '')), ''));
  v_season bigint;
  v_inj_n int := 0;
  v_fit_n int := 0;
  v_cleared int := 0;
  v_n int := 0;
  r record;
BEGIN
  IF v_pid IS NULL OR v_to IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'player_or_club_required');
  END IF;

  -- Active injuries → buying club
  FOR r IN
    SELECT i.id
    FROM public.competition_player_injuries i
    WHERE i.player_id = v_pid
      AND i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
      AND upper(btrim(i.club_short_name)) IS DISTINCT FROM v_to
  LOOP
    -- Drop pending fixture ticks tied to the old club's schedule
    IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
      DELETE FROM public.competition_player_injury_fixtures iff
      WHERE iff.injury_id = r.id
        AND iff.served = false;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_cleared := v_cleared + v_n;
    END IF;

    UPDATE public.competition_player_injuries i
    SET club_short_name = v_to
    WHERE i.id = r.id;

    v_inj_n := v_inj_n + 1;

    IF to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NOT NULL THEN
      PERFORM public.competition_match_fitness_sync_from_injury(r.id);
    END IF;
  END LOOP;

  -- Match fitness row(s) for current season → buying club
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NOT NULL
     AND to_regclass('public.competition_player_match_fitness') IS NOT NULL THEN
    UPDATE public.competition_player_match_fitness f
    SET club_short_name = v_to,
        updated_at = now()
    WHERE f.season_id = v_season
      AND f.player_id = v_pid
      AND upper(btrim(f.club_short_name)) IS DISTINCT FROM v_to;
    GET DIAGNOSTICS v_fit_n = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'to_club', v_to,
    'injuries_moved', v_inj_n,
    'injury_fixtures_cleared', v_cleared,
    'fitness_rows_moved', v_fit_n
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_move_player_medical_to_club(text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_move_player_medical_to_club(text, text, text)
  TO authenticated, service_role;

-- Trigger: any Contracted_Team change to a real club moves medical state
CREATE OR REPLACE FUNCTION public.trg_players_move_medical_on_club_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_old text := upper(nullif(btrim(coalesce(OLD."Contracted_Team", '')), ''));
  v_new text := upper(nullif(btrim(coalesce(NEW."Contracted_Team", '')), ''));
BEGIN
  IF v_new IS NULL OR v_new IS NOT DISTINCT FROM v_old THEN
    RETURN NEW;
  END IF;

  IF to_regprocedure(
    'public.competition_move_player_medical_to_club(text,text,text)'
  ) IS NOT NULL THEN
    PERFORM public.competition_move_player_medical_to_club(
      NEW."Konami_ID"::text,
      v_new,
      v_old
    );
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS players_move_medical_on_club_change ON public."Players";
CREATE TRIGGER players_move_medical_on_club_change
  AFTER UPDATE OF "Contracted_Team" ON public."Players"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_players_move_medical_on_club_change();

-- One-shot: fix already-transferred players whose injury is still on the seller
DO $fixup$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT
      i.id AS injury_id,
      i.player_id,
      upper(btrim(i.club_short_name)) AS injury_club,
      upper(btrim(p."Contracted_Team")) AS player_club
    FROM public.competition_player_injuries i
    JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
    WHERE i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
      AND nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
      AND upper(btrim(i.club_short_name))
        IS DISTINCT FROM upper(btrim(p."Contracted_Team"))
  LOOP
    PERFORM public.competition_move_player_medical_to_club(
      r.player_id, r.player_club, r.injury_club
    );
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Moved medical state for % already-transferred injured player(s)', n;
END;
$fixup$;

-- Compact injury map for transfer market UI
CREATE OR REPLACE FUNCTION public.competition_active_injuries_for_players(
  p_player_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF p_player_ids IS NULL OR coalesce(array_length(p_player_ids, 1), 0) = 0 THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT coalesce(jsonb_object_agg(y.player_id, y.payload), '{}'::jsonb)
  INTO v_out
  FROM (
    SELECT DISTINCT ON (i.player_id)
      i.player_id,
      jsonb_build_object(
        'label', i.label,
        'severity', i.severity,
        'matches_out_remaining', coalesce(i.matches_out_remaining, 0),
        'recovery_remaining', coalesce(i.recovery_remaining, 0),
        'phase', CASE
          WHEN coalesce(i.matches_out_remaining, 0) > 0 THEN 'out'
          ELSE 'recovery'
        END
      ) AS payload
    FROM public.competition_player_injuries i
    WHERE i.status = 'active'
      AND i.player_id = ANY (p_player_ids)
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
    ORDER BY i.player_id, i.id DESC
  ) y;

  RETURN coalesce(v_out, '{}'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_active_injuries_for_players(text[])
  TO authenticated;

NOTIFY pgrst, 'reload schema';
