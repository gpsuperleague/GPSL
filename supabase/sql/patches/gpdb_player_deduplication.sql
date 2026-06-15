-- =============================================================================
-- GPDB player deduplication — audit + pre-season apply
-- Match: normalized Name + Nation. Keep highest Rating (then Potential, contracted, lowest Konami_ID).
-- Run after squad_composition_rules.sql (normalize_nation_key).
-- Admin UI: admin_gpdb_dedup.html
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_player_rating_numeric(p_rating text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(
    regexp_replace(coalesce(btrim(p_rating::text), ''), '[^0-9.]', '', 'g'),
    ''
  )::numeric;
$$;

CREATE OR REPLACE FUNCTION public.gpdb_player_potential_numeric(
  p_potential text,
  p_calc_potential text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    public.gpdb_player_rating_numeric(p_calc_potential),
    public.gpdb_player_rating_numeric(p_potential)
  );
$$;

CREATE OR REPLACE FUNCTION public.gpdb_player_duplicate_key(p_name text, p_nation text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN public.normalize_nation_key(p_name) = '' THEN NULL
    WHEN public.normalize_nation_key(p_nation) = '' THEN NULL
    ELSE public.normalize_nation_key(p_name) || '|' || public.normalize_nation_key(p_nation)
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpdb_player_id_reference_summary(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_out jsonb := '{}'::jsonb;
  v_n integer;
BEGIN
  IF v_pid = '' THEN
    RETURN v_out;
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id::text = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('transfer_listings', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public."Player_Transfer_Bids" b
  WHERE btrim(coalesce(b.player_id, '')) = v_pid
     OR btrim(coalesce(b.direct_bid_id::text, '')) = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('transfer_bids', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public."Transfer_History" h
  WHERE h.player_id::text = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('transfer_history', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public.competition_match_player_stats m
  WHERE m.player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('match_stats', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public.international_squad_callups sc
  WHERE sc.player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('intl_callups', v_n); END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_player_career ipc WHERE ipc.player_id = v_pid
  ) THEN
    v_out := v_out || jsonb_build_object('intl_career', 1);
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.competition_player_season_archive a
  WHERE a.player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('season_archive', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public.competition_season_award aw
  WHERE aw.player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('season_awards', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public.club_matchday_squad_player ms
  WHERE ms.player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('matchday_squad', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public.draft_auction_favourites f
  WHERE f.player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('draft_favourites', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public.contract_expiry_wage_bids w
  WHERE w.player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('expiry_wage_bids', v_n); END IF;

  SELECT count(*)::int INTO v_n
  FROM public.special_auctions sa
  WHERE sa.prize_player_id = v_pid OR sa.known_player_id = v_pid;
  IF v_n > 0 THEN v_out := v_out || jsonb_build_object('special_auctions', v_n); END IF;

  IF nullif(btrim(
    (SELECT p."Contracted_Team" FROM public."Players" p WHERE p."Konami_ID"::text = v_pid LIMIT 1)
  ), '') IS NOT NULL THEN
    v_out := v_out || jsonb_build_object('contracted', 1);
  END IF;

  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_player_id_in_use(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpdb_player_id_reference_summary(p_player_id) <> '{}'::jsonb;
$$;

CREATE OR REPLACE FUNCTION public.gpdb_player_remap_id(p_from_id text, p_to_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from text := btrim(p_from_id);
  v_to text := btrim(p_to_id);
  v_loser public."Players"%rowtype;
  v_winner public."Players"%rowtype;
BEGIN
  IF v_from = '' OR v_to = '' OR v_from = v_to THEN
    RETURN;
  END IF;

  SELECT * INTO v_loser FROM public."Players" p WHERE p."Konami_ID"::text = v_from;
  SELECT * INTO v_winner FROM public."Players" p WHERE p."Konami_ID"::text = v_to;

  IF v_loser."Konami_ID" IS NULL OR v_winner."Konami_ID" IS NULL THEN
    RETURN;
  END IF;

  -- Merge international career stats
  IF EXISTS (SELECT 1 FROM public.international_player_career WHERE player_id = v_from) THEN
    IF EXISTS (SELECT 1 FROM public.international_player_career WHERE player_id = v_to) THEN
      UPDATE public.international_player_career w
      SET
        caps = w.caps + l.caps,
        goals = w.goals + l.goals,
        assists = w.assists + l.assists,
        potm = w.potm + l.potm,
        rating_sum = w.rating_sum + l.rating_sum,
        rating_count = w.rating_count + l.rating_count,
        updated_at = now()
      FROM public.international_player_career l
      WHERE w.player_id = v_to AND l.player_id = v_from;
      DELETE FROM public.international_player_career WHERE player_id = v_from;
    ELSE
      UPDATE public.international_player_career SET player_id = v_to WHERE player_id = v_from;
    END IF;
  END IF;

  -- Copy contract from loser if winner is a free agent
  IF nullif(btrim(v_winner."Contracted_Team"), '') IS NULL
     AND nullif(btrim(v_loser."Contracted_Team"), '') IS NOT NULL THEN
    UPDATE public."Players" w
    SET
      "Contracted_Team" = l."Contracted_Team",
      "Season_Signed" = l."Season_Signed",
      contract_seasons_remaining = l.contract_seasons_remaining,
      contract_wage = l.contract_wage,
      foreign_contract_club = l.foreign_contract_club,
      foreign_contract_sold_season_id = l.foreign_contract_sold_season_id,
      foreign_contract_unlock_season_label = l.foreign_contract_unlock_season_label,
      foreign_contract_lock_kind = l.foreign_contract_lock_kind
    FROM public."Players" l
    WHERE w."Konami_ID"::text = v_to AND l."Konami_ID"::text = v_from;
  END IF;

  -- Drop loser rows that would violate uniques after remap
  DELETE FROM public.draft_auction_favourites f
  WHERE f.player_id = v_from
    AND EXISTS (
      SELECT 1 FROM public.draft_auction_favourites w
      WHERE w.club_id = f.club_id AND w.player_id = v_to
    );

  DELETE FROM public.club_matchday_squad_player ms
  WHERE ms.player_id = v_from
    AND EXISTS (
      SELECT 1 FROM public.club_matchday_squad_player w
      WHERE w.club_short_name = ms.club_short_name AND w.player_id = v_to
    );

  DELETE FROM public.international_squad_callups sc
  WHERE sc.player_id = v_from
    AND EXISTS (
      SELECT 1 FROM public.international_squad_callups w
      WHERE w.nation_code = sc.nation_code AND w.player_id = v_to
    );

  DELETE FROM public.competition_match_player_stats m
  WHERE m.player_id = v_from
    AND EXISTS (
      SELECT 1 FROM public.competition_match_player_stats w
      WHERE w.fixture_id = m.fixture_id AND w.player_id = v_to
    );

  DELETE FROM public.contract_expiry_wage_bids b
  WHERE b.player_id = v_from
    AND EXISTS (
      SELECT 1 FROM public.contract_expiry_wage_bids w
      WHERE w.player_id = v_to
        AND w.bidder_club_short_name = b.bidder_club_short_name
        AND w.season_label = b.season_label
    );

  UPDATE public."Player_Transfer_Listings" SET player_id = v_to WHERE player_id::text = v_from;
  UPDATE public."Player_Transfer_Bids"
  SET player_id = v_to
  WHERE btrim(coalesce(player_id, '')) = v_from;
  UPDATE public."Player_Transfer_Bids"
  SET direct_bid_id = v_to
  WHERE btrim(coalesce(direct_bid_id::text, '')) = v_from;
  UPDATE public."Transfer_History" SET player_id = v_to WHERE player_id::text = v_from;
  UPDATE public.competition_match_player_stats SET player_id = v_to WHERE player_id = v_from;
  UPDATE public.international_squad_callups SET player_id = v_to WHERE player_id = v_from;
  UPDATE public.competition_player_season_archive SET player_id = v_to WHERE player_id = v_from;
  UPDATE public.competition_season_award SET player_id = v_to WHERE player_id = v_from;
  UPDATE public.club_matchday_squad_player SET player_id = v_to WHERE player_id = v_from;
  UPDATE public.draft_auction_favourites SET player_id = v_to WHERE player_id = v_from;
  UPDATE public.contract_expiry_wage_bids SET player_id = v_to WHERE player_id = v_from;
  UPDATE public.special_auctions SET prize_player_id = v_to WHERE prize_player_id = v_from;
  UPDATE public.special_auctions SET known_player_id = v_to WHERE known_player_id = v_from;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_player_duplicate_audit()
RETURNS TABLE (
  dup_key text,
  group_size integer,
  blocked_reason text,
  keep_konami_id text,
  keep_name text,
  keep_nation text,
  keep_rating numeric,
  keep_club text,
  drop_konami_id text,
  drop_name text,
  drop_nation text,
  drop_rating numeric,
  drop_club text,
  drop_in_use boolean,
  drop_refs jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  WITH tagged AS (
    SELECT
      p."Konami_ID"::text AS konami_id,
      p."Name" AS player_name,
      p."Nation" AS player_nation,
      public.gpdb_player_duplicate_key(p."Name", p."Nation") AS dup_key,
      public.gpdb_player_rating_numeric(p."Rating"::text) AS rating_num,
      public.gpdb_player_potential_numeric(p."Potential"::text, p."Calc_Potential"::text) AS potential_num,
      nullif(btrim(p."Contracted_Team"), '') AS club_short
    FROM public."Players" p
  ),
  group_stats AS (
    SELECT
      t.dup_key,
      count(*)::integer AS group_size,
      count(DISTINCT t.club_short) FILTER (WHERE t.club_short IS NOT NULL)::integer AS distinct_clubs
    FROM tagged t
    WHERE t.dup_key IS NOT NULL
    GROUP BY t.dup_key
    HAVING count(*) > 1
  ),
  ranked AS (
    SELECT
      t.*,
      gs.group_size,
      gs.distinct_clubs,
      row_number() OVER (
        PARTITION BY t.dup_key
        ORDER BY
          t.rating_num DESC NULLS LAST,
          t.potential_num DESC NULLS LAST,
          CASE WHEN t.club_short IS NOT NULL THEN 0 ELSE 1 END,
          t.konami_id ASC
      ) AS rn
    FROM tagged t
    JOIN group_stats gs ON gs.dup_key = t.dup_key
  ),
  winners AS (
    SELECT * FROM ranked WHERE rn = 1
  ),
  losers AS (
    SELECT * FROM ranked WHERE rn > 1
  )
  SELECT
    l.dup_key,
    l.group_size,
    CASE
      WHEN l.distinct_clubs > 1 THEN 'multiple_clubs_contracted'
      ELSE NULL
    END AS blocked_reason,
    w.konami_id AS keep_konami_id,
    w.player_name AS keep_name,
    w.player_nation AS keep_nation,
    w.rating_num AS keep_rating,
    w.club_short AS keep_club,
    l.konami_id AS drop_konami_id,
    l.player_name AS drop_name,
    l.player_nation AS drop_nation,
    l.rating_num AS drop_rating,
    l.club_short AS drop_club,
    public.gpdb_player_id_in_use(l.konami_id) AS drop_in_use,
    public.gpdb_player_id_reference_summary(l.konami_id) AS drop_refs
  FROM losers l
  JOIN winners w ON w.dup_key = l.dup_key
  ORDER BY l.dup_key, l.rating_num DESC NULLS LAST, l.konami_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_player_deduplicate(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_groups integer := 0;
  v_to_drop integer := 0;
  v_blocked_groups integer := 0;
  v_remap_count integer := 0;
  v_deleted integer := 0;
  v_blocked jsonb := '[]'::jsonb;
  v_actions jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(DISTINCT dup_key)::integer INTO v_groups
  FROM public.gpdb_player_duplicate_audit();

  SELECT count(*)::integer INTO v_to_drop
  FROM public.gpdb_player_duplicate_audit()
  WHERE blocked_reason IS NULL;

  SELECT count(DISTINCT dup_key)::integer INTO v_blocked_groups
  FROM public.gpdb_player_duplicate_audit()
  WHERE blocked_reason IS NOT NULL;

  FOR v_row IN
    SELECT *
    FROM public.gpdb_player_duplicate_audit()
    ORDER BY dup_key, drop_konami_id
  LOOP
    IF v_row.blocked_reason IS NOT NULL THEN
      v_blocked := v_blocked || jsonb_build_array(
        jsonb_build_object(
          'dup_key', v_row.dup_key,
          'reason', v_row.blocked_reason,
          'keep_konami_id', v_row.keep_konami_id,
          'drop_konami_id', v_row.drop_konami_id
        )
      );
      CONTINUE;
    END IF;

    IF v_row.drop_in_use THEN
      v_remap_count := v_remap_count + 1;
    END IF;

    v_actions := v_actions || jsonb_build_array(
      jsonb_build_object(
        'dup_key', v_row.dup_key,
        'keep_konami_id', v_row.keep_konami_id,
        'drop_konami_id', v_row.drop_konami_id,
        'drop_in_use', v_row.drop_in_use,
        'drop_refs', v_row.drop_refs
      )
    );

    IF NOT p_dry_run THEN
      PERFORM public.gpdb_player_remap_id(v_row.drop_konami_id, v_row.keep_konami_id);
      DELETE FROM public."Players" p
      WHERE p."Konami_ID"::text = v_row.drop_konami_id;
      v_deleted := v_deleted + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run', p_dry_run,
    'duplicate_groups', v_groups,
    'players_to_remove', v_to_drop,
    'blocked_groups', v_blocked_groups,
    'refs_to_remap', v_remap_count,
    'deleted', v_deleted,
    'blocked', v_blocked,
    'actions', v_actions
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_player_duplicate_audit() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_player_deduplicate(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
