-- =============================================================================
-- One-off: remove Test Player (Konami_ID 999999) from GPDB
-- Safe re-run (no-op if already gone).
-- =============================================================================

DO $$
DECLARE
  v_pid text := '999999';
  v_name text;
  v_club text;
  v_deleted int := 0;
BEGIN
  SELECT nullif(btrim(p."Name"), ''), nullif(btrim(p."Contracted_Team"), '')
  INTO v_name, v_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE NOTICE 'Player % already absent from Players — nothing to do.', v_pid;
    RETURN;
  END IF;

  -- Guard: only remove if it looks like the test card (or name empty)
  IF v_name IS NOT NULL
     AND lower(v_name) NOT IN ('test', 'test player', 'testplayer')
     AND lower(v_name) NOT LIKE 'test %'
  THEN
    RAISE EXCEPTION
      'Refusing to delete Konami_ID % — Name is "%" (expected Test Player).',
      v_pid, v_name;
  END IF;

  RAISE NOTICE 'Removing % (%) club=%', v_pid, coalesce(v_name, '?'), coalesce(v_club, 'FA');

  -- Common child / reference tables (ignore if relation missing)
  BEGIN DELETE FROM public.draft_auction_favourites WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.club_matchday_squad_player WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.international_squad_callups WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.international_player_career WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.competition_match_player_stats WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.competition_player_season_archive WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.competition_season_award WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.contract_expiry_wage_bids WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.auction_exclusion_players WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.gpdb_season_excluded_players WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.nextgen_youth_players WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.club_squad_player_designations WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.club_scouting_planner_player WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.owner_scouting_planner_player WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;

  BEGIN
    DELETE FROM public."Player_Transfer_Bids" WHERE btrim(coalesce(player_id, '')) = v_pid;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;
  BEGIN
    DELETE FROM public."Player_Transfer_Listings" WHERE player_id::text = v_pid;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;
  BEGIN
    DELETE FROM public."Transfer_History" WHERE player_id::text = v_pid;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  BEGIN
    UPDATE public.special_auctions SET prize_player_id = NULL WHERE prize_player_id = v_pid;
    UPDATE public.special_auctions SET known_player_id = NULL WHERE known_player_id = v_pid;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  -- GPFL
  BEGIN DELETE FROM public.gpfl_squad_players WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN DELETE FROM public.gpfl_pool_players WHERE player_id = v_pid; EXCEPTION WHEN undefined_table THEN NULL; END;
  BEGIN
    DELETE FROM public.gpfl_transfers
    WHERE player_in = v_pid OR player_out = v_pid;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;

  DELETE FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RAISE NOTICE 'Deleted % Players row(s) for Konami_ID %.', v_deleted, v_pid;
END $$;
