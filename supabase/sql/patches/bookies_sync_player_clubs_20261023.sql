-- =============================================================================
-- Bookies: refresh player selection clubs/labels from live squads (2026-10-23)
-- =============================================================================
-- Player markets freeze "Name (CLUB)" at insert. Transfers left stale boards
-- (e.g. Yamal still showing at an old club). This syncs open/closed player
-- selections from Players."Contracted_Team", withdraws free agents / FOREIGN /
-- non-league clubs, and is hooked into admin_bookies_recompute_player_odds
-- (Refresh board odds). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_bookies_sync_player_selection_clubs(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_updated int := 0;
  v_withdrawn int := 0;
  v_restored int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  -- Update label + club metadata from live contract
  WITH live AS (
    SELECT
      s.id AS selection_id,
      s.market_id,
      s.selection_key AS player_id,
      coalesce(nullif(btrim(p."Name"), ''), s.selection_key) AS player_name,
      nullif(btrim(public.player_contracted_club_key(p."Contracted_Team")), '') AS club,
      EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = public.player_contracted_club_key(p."Contracted_Team")
          AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      ) AS in_gpsl
    FROM public.bookies_selections s
    JOIN public.bookies_markets m ON m.id = s.market_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.selection_key
    WHERE m.season_id = v_season
      AND m.market_kind = 'player'
      AND m.status IN ('open', 'closed')
  ),
  upd AS (
    UPDATE public.bookies_selections s
    SET
      label = CASE
        WHEN l.club IS NOT NULL AND l.in_gpsl
          THEN l.player_name || ' (' || l.club || ')'
        ELSE l.player_name || ' (left squad)'
      END,
      metadata = coalesce(s.metadata, '{}'::jsonb) || jsonb_build_object(
        'club', l.club,
        'club_synced_at', now(),
        'withdrawn', NOT (l.club IS NOT NULL AND l.in_gpsl)
      )
    FROM live l
    WHERE s.id = l.selection_id
      AND (
        s.label IS DISTINCT FROM (
          CASE
            WHEN l.club IS NOT NULL AND l.in_gpsl
              THEN l.player_name || ' (' || l.club || ')'
            ELSE l.player_name || ' (left squad)'
          END
        )
        OR coalesce(s.metadata->>'club', '') IS DISTINCT FROM coalesce(l.club, '')
        OR coalesce((s.metadata->>'withdrawn')::boolean, false)
             IS DISTINCT FROM NOT (l.club IS NOT NULL AND l.in_gpsl)
      )
    RETURNING
      s.id,
      coalesce((s.metadata->>'withdrawn')::boolean, false) AS is_withdrawn
  )
  SELECT
    count(*)::int,
    count(*) FILTER (WHERE is_withdrawn)::int,
    count(*) FILTER (WHERE NOT is_withdrawn)::int
  INTO v_updated, v_withdrawn, v_restored
  FROM upd;

  -- Zero weight on withdrawn so they fall off the odds board
  UPDATE public.bookies_selections s
  SET weight = 0.01
  FROM public.bookies_markets m
  WHERE m.id = s.market_id
    AND m.season_id = v_season
    AND m.market_kind = 'player'
    AND m.status IN ('open', 'closed')
    AND coalesce((s.metadata->>'withdrawn')::boolean, false) = true
    AND coalesce(s.weight, 0) > 0.01;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'selections_touched', v_updated,
    'withdrawn_flagged', v_withdrawn,
    'active_updated', v_restored
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_bookies_sync_player_selection_clubs(bigint)
  TO authenticated, service_role;

-- Hook into player odds recompute (Refresh board odds)
CREATE OR REPLACE FUNCTION public.admin_bookies_recompute_player_odds(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_n int := 0;
  v_sync jsonb;
  r record;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;

  v_sync := public.admin_bookies_sync_player_selection_clubs(v_season);

  WITH w AS (
    SELECT s.id, s.market_id,
           public.bookies_player_live_weight(s.market_id, s.selection_key) AS strength
    FROM public.bookies_selections s
    JOIN public.bookies_markets m ON m.id = s.market_id
    WHERE m.market_kind = 'player'
      AND m.season_id = v_season
      AND m.status IN ('open', 'closed')
      AND coalesce((s.metadata->>'withdrawn')::boolean, false) IS NOT TRUE
  ),
  o AS (
    SELECT w.*,
           row_number() OVER (PARTITION BY w.market_id ORDER BY w.strength DESC, w.id)::int AS so
    FROM w
  )
  UPDATE public.bookies_selections s
  SET weight = o.strength,
      sort_order = o.so,
      metadata = coalesce(s.metadata, '{}'::jsonb) || jsonb_build_object(
        'live_form', true,
        'weight_source', 'player_live_weight'
      )
  FROM o
  WHERE s.id = o.id;

  BEGIN
    PERFORM set_config('gpsl.bookies_preopen_ok', 'on', true);
    IF to_regprocedure('public.bookies_open_stat_markets(bigint,boolean)') IS NOT NULL THEN
      PERFORM public.bookies_open_stat_markets(v_season, true);
    END IF;
    PERFORM set_config('gpsl.bookies_preopen_ok', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'bookies_open_stat_markets during player recompute: %', SQLERRM;
  END;

  -- Sync again after new selections are inserted from stat markets
  PERFORM public.admin_bookies_sync_player_selection_clubs(v_season);

  FOR r IN
    SELECT id FROM public.bookies_markets
    WHERE season_id = v_season
      AND market_kind = 'player'
      AND status IN ('open', 'closed')
  LOOP
    PERFORM public.bookies_apply_odds_from_weights(r.id);
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season,
    'markets_repriced', v_n,
    'club_sync', v_sync
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_bookies_recompute_player_odds(bigint) TO authenticated;

-- One-shot sync now
SELECT public.admin_bookies_sync_player_selection_clubs(NULL) AS sync_result;

-- Report: still-mismatched labels (should be empty / few after sync)
SELECT
  m.title,
  s.selection_key AS player_id,
  s.label AS board_label,
  p."Name" AS live_name,
  public.player_contracted_club_key(p."Contracted_Team") AS live_club,
  s.metadata->>'club' AS board_club,
  coalesce((s.metadata->>'withdrawn')::boolean, false) AS withdrawn
FROM public.bookies_selections s
JOIN public.bookies_markets m ON m.id = s.market_id
JOIN public.competition_seasons se ON se.id = m.season_id AND se.is_current
LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.selection_key
WHERE m.market_kind = 'player'
  AND m.status IN ('open', 'closed')
  AND (
    coalesce(s.metadata->>'club', '')
      IS DISTINCT FROM coalesce(public.player_contracted_club_key(p."Contracted_Team"), '')
    OR s.label ILIKE '%(left squad)%'
  )
ORDER BY m.title, s.label
LIMIT 80;

NOTIFY pgrst, 'reload schema';
