-- =============================================================================
-- Owner-led divisions (Phase 1): seasons no longer require 60 clubs
--
-- Model:
--   • Create season registers every non-archived club as 'unassigned'
--     (any club count — e.g. 73).
--   • Club auction runs during pre-season.
--   • "Assign divisions from owners":
--       owner priority 1–20  → Super League (must be 20)
--       priority 21–40       → Championship A if at least 10 of them
--       priority 41–60       → Championship B if A is full and at least 10
--       other owned clubs    → 'standby' (cups / transfers / auctions, no league)
--       unowned clubs        → 'unassigned' (no fixtures, no costs, no income)
--   • Owner priority = Season 1 confirmed order (priority lane by S1#, then
--     mass lane by accept time), then waiting-list board order.
--   • Start season: SL 20; each Championship 0 or 10–20; B only when A is 20.
--
-- Season finance loops already only charge league divisions, so standby and
-- unassigned clubs pay no wages / upkeep / FFP / interest.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) 'standby' division value
-- ---------------------------------------------------------------------------
DO $chk$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    WHERE con.conrelid = 'public.competition_club_seasons'::regclass
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%division%'
      AND pg_get_constraintdef(con.oid) ILIKE '%superleague%'
  LOOP
    EXECUTE format('ALTER TABLE public.competition_club_seasons DROP CONSTRAINT %I', r.conname);
  END LOOP;

  ALTER TABLE public.competition_club_seasons
    ADD CONSTRAINT competition_club_seasons_division_check
    CHECK (
      division IN (
        'unassigned',
        'standby',
        'superleague',
        'championship_pool',
        'championship_a',
        'championship_b'
      )
    );
END;
$chk$;

-- ---------------------------------------------------------------------------
-- 2) Owner league priority (1 = first pick for the Super League)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_owner_league_priority()
RETURNS TABLE (owner_id uuid, owner_tag text, priority int, source text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    r.owner_id,
    coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
    (row_number() OVER (
      ORDER BY
        CASE WHEN r.season1_invite_response = 'accepted' THEN 0 ELSE 1 END,
        CASE
          WHEN r.season1_invite_response = 'accepted'
           AND coalesce(nullif(btrim(r.season1_invite_lane), ''), 'priority') = 'mass' THEN 1
          ELSE 0
        END,
        CASE
          WHEN r.season1_invite_response = 'accepted'
           AND coalesce(nullif(btrim(r.season1_invite_lane), ''), 'priority') = 'mass'
            THEN r.season1_invite_responded_at
        END NULLS LAST,
        r.season1_invite_queue_num NULLS LAST,
        r.season1_invite_responded_at NULLS LAST,
        r.waiting_list_admin_sort NULLS LAST,
        r.created_at,
        r.owner_id
    ))::int AS priority,
    CASE
      WHEN r.season1_invite_response = 'accepted' THEN 'season1_confirmed'
      ELSE 'waiting_list'
    END AS source
  FROM public.gpsl_owner_registry r
  WHERE r.status IS DISTINCT FROM 'archived';
$$;

-- ---------------------------------------------------------------------------
-- 3) Create season: any club count, archived clubs excluded
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_create_season(p_label text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text := trim(p_label);
  v_season_id bigint;
  v_club_count bigint;
  v_prev bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_label IS NULL OR v_label = '' THEN
    RAISE EXCEPTION 'Season label is required';
  END IF;

  INSERT INTO public.competition_seasons (label, status, is_current)
  VALUES (v_label, 'preseason', false)
  RETURNING id INTO v_season_id;

  INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
  SELECT v_season_id, c."ShortName", 'unassigned'
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
    AND NOT coalesce(c.is_archived, false)
  ORDER BY c."ShortName";

  GET DIAGNOSTICS v_club_count = ROW_COUNT;

  IF v_club_count < 20 THEN
    RAISE EXCEPTION 'Need at least 20 active clubs to create a season, found %', v_club_count;
  END IF;

  SELECT s.id INTO v_prev
  FROM public.competition_seasons s
  WHERE s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev IS NOT NULL THEN
    IF to_regprocedure('public.admin_gpdb_copy_season_exclusions(bigint, bigint)') IS NOT NULL
       AND (
         EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_players ep WHERE ep.season_id = v_prev
         )
         OR EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_nations en WHERE en.season_id = v_prev
         )
       )
    THEN
      PERFORM public.admin_gpdb_copy_season_exclusions(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_cup_prizes(bigint, bigint)') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_cup_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_cup_prizes(v_prev, v_season_id);
    ELSIF EXISTS (SELECT 1 FROM public.competition_cup_prize_template) THEN
      PERFORM public.competition_admin_apply_cup_prize_template(v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_league_prizes(bigint, bigint)') IS NOT NULL
       AND to_regclass('public.competition_league_prize_config') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_league_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_league_prizes(v_prev, v_season_id);
    ELSIF EXISTS (SELECT 1 FROM public.competition_league_prize_template) THEN
      PERFORM public.competition_admin_apply_league_prize_template(v_season_id);
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM public.competition_cup_prize_template) THEN
      PERFORM public.competition_admin_apply_cup_prize_template(v_season_id);
    END IF;
    IF EXISTS (SELECT 1 FROM public.competition_league_prize_template) THEN
      PERFORM public.competition_admin_apply_league_prize_template(v_season_id);
    END IF;
  END IF;

  -- Contract tick is intentionally NOT here — call contract_tick_season_rollover()
  -- as a separate admin step (avoids API gateway timeouts).

  RETURN v_season_id;
END;
$function$;

-- Clubs added / un-archived after the season was created
CREATE OR REPLACE FUNCTION public.competition_register_missing_clubs(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
  SELECT p_season_id, c."ShortName", 'unassigned'
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
    AND NOT coalesce(c.is_archived, false)
    AND NOT EXISTS (
      SELECT 1 FROM public.competition_club_seasons cs
      WHERE cs.season_id = p_season_id
        AND cs.club_short_name = c."ShortName"
    );

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4) Assign divisions from owners (dry run by default)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_assign_divisions_from_owners(
  p_season_id bigint,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owned int;
  v_tier2 int;
  v_tier3 int;
  v_use_a boolean;
  v_use_b boolean;
  v_rows jsonb;
  v_counts jsonb;
  v_warnings text[] := ARRAY[]::text[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.competition_assert_setup_season(p_season_id);

  IF NOT p_dry_run THEN
    PERFORM public.competition_register_missing_clubs(p_season_id);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _owner_div_plan (
    club_short_name text PRIMARY KEY,
    club_name text,
    owner_id uuid,
    owner_tag text,
    owner_priority int,
    owner_source text,
    seq int,
    division text
  ) ON COMMIT DROP;
  TRUNCATE _owner_div_plan;

  INSERT INTO _owner_div_plan (club_short_name, club_name, owner_id, owner_tag, owner_priority, owner_source, seq, division)
  SELECT
    cs.club_short_name,
    coalesce(c."Club", cs.club_short_name),
    c.owner_id,
    coalesce(p.owner_tag, nullif(btrim(c.owner), ''), '—'),
    p.priority,
    p.source,
    CASE
      WHEN c.owner_id IS NULL THEN NULL
      ELSE row_number() OVER (
        PARTITION BY (c.owner_id IS NULL)
        ORDER BY p.priority NULLS LAST, cs.club_short_name
      )
    END::int,
    'unassigned'
  FROM public.competition_club_seasons cs
  JOIN public."Clubs" c ON c."ShortName" = cs.club_short_name
  LEFT JOIN public.competition_owner_league_priority() p ON p.owner_id = c.owner_id
  WHERE cs.season_id = p_season_id;

  SELECT count(*) INTO v_owned FROM _owner_div_plan WHERE owner_id IS NOT NULL;
  SELECT count(*) INTO v_tier2 FROM _owner_div_plan WHERE seq BETWEEN 21 AND 40;
  SELECT count(*) INTO v_tier3 FROM _owner_div_plan WHERE seq BETWEEN 41 AND 60;

  v_use_a := v_tier2 >= 10;
  v_use_b := v_use_a AND v_tier2 = 20 AND v_tier3 >= 10;

  UPDATE _owner_div_plan
  SET division = CASE
    WHEN seq IS NULL THEN 'unassigned'
    WHEN seq <= 20 THEN 'superleague'
    WHEN seq <= 40 AND v_use_a THEN 'championship_a'
    WHEN seq BETWEEN 41 AND 60 AND v_use_b THEN 'championship_b'
    ELSE 'standby'
  END
  WHERE true;

  IF v_owned < 20 THEN
    v_warnings := array_append(v_warnings,
      format('Only %s owned clubs — the Super League needs 20. Run the club auction first.', v_owned));
  END IF;
  IF v_tier2 BETWEEN 1 AND 9 THEN
    v_warnings := array_append(v_warnings,
      format('%s owner(s) in positions 21–40 — below 10, so they are standby (no Championship yet).', v_tier2));
  END IF;
  IF v_use_a AND v_tier2 < 20 THEN
    v_warnings := array_append(v_warnings,
      format('Championship A has %s clubs — fixtures for a division under 20 need the Phase 3 fixture update.', v_tier2));
  END IF;
  IF v_use_b AND v_tier3 < 20 THEN
    v_warnings := array_append(v_warnings,
      format('Championship B has %s clubs — fixtures for a division under 20 need the Phase 3 fixture update.', v_tier3));
  END IF;

  SELECT jsonb_build_object(
    'superleague', count(*) FILTER (WHERE division = 'superleague'),
    'championship_a', count(*) FILTER (WHERE division = 'championship_a'),
    'championship_b', count(*) FILTER (WHERE division = 'championship_b'),
    'standby', count(*) FILTER (WHERE division = 'standby'),
    'unassigned', count(*) FILTER (WHERE division = 'unassigned'),
    'owned', v_owned
  )
  INTO v_counts
  FROM _owner_div_plan;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'club', club_short_name,
    'club_name', club_name,
    'owner_tag', owner_tag,
    'owner_priority', owner_priority,
    'owner_source', owner_source,
    'seq', seq,
    'division', division
  ) ORDER BY seq NULLS LAST, club_short_name), '[]'::jsonb)
  INTO v_rows
  FROM _owner_div_plan
  WHERE owner_id IS NOT NULL;

  IF NOT p_dry_run THEN
    IF v_owned < 20 THEN
      RAISE EXCEPTION 'Only % owned clubs — the Super League needs 20', v_owned;
    END IF;

    UPDATE public.competition_club_seasons cs
    SET division = p.division,
        league_position = NULL
    FROM _owner_div_plan p
    WHERE cs.season_id = p_season_id
      AND cs.club_short_name = p.club_short_name;
  END IF;

  RETURN jsonb_build_object(
    'ok', v_owned >= 20,
    'dry_run', p_dry_run,
    'season_id', p_season_id,
    'counts', v_counts,
    'warnings', to_jsonb(v_warnings),
    'owned_clubs', v_rows
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5) Manual division edits: allow standby / A / B directly
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_set_club_division(
  p_season_id bigint,
  p_club_short_name text,
  p_division text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  IF p_division NOT IN (
    'unassigned', 'standby', 'superleague', 'championship_pool', 'championship_a', 'championship_b'
  ) THEN
    RAISE EXCEPTION 'Invalid setup division: %', p_division;
  END IF;

  UPDATE public.competition_club_seasons
  SET division = p_division
  WHERE season_id = p_season_id
    AND club_short_name = p_club_short_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club not registered for this season';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_bulk_set_divisions(
  p_season_id bigint,
  p_assignments jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item jsonb;
  v_club text;
  v_division text;
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  IF p_assignments IS NULL OR jsonb_typeof(p_assignments) <> 'array' THEN
    RAISE EXCEPTION 'Assignments must be a JSON array';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_assignments)
  LOOP
    v_club := trim(both '"' FROM (v_item ->> 'club'));
    v_division := v_item ->> 'division';

    IF v_club IS NULL OR v_club = '' THEN
      RAISE EXCEPTION 'Each assignment needs club';
    END IF;

    IF v_division NOT IN (
      'unassigned', 'standby', 'superleague', 'championship_pool', 'championship_a', 'championship_b'
    ) THEN
      RAISE EXCEPTION 'Invalid division for %: %', v_club, v_division;
    END IF;

    UPDATE public.competition_club_seasons
    SET division = v_division
    WHERE season_id = p_season_id
      AND club_short_name = v_club;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Club not registered for this season: %', v_club;
    END IF;
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6) Start season: SL 20; Championships 0 or 10–20
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_activate_season(p_season_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sl bigint;
  v_a bigint;
  v_b bigint;
  v_pool bigint;
  v_has_calendar boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.competition_assert_setup_season(p_season_id);

  SELECT
    count(*) FILTER (WHERE division = 'superleague'),
    count(*) FILTER (WHERE division = 'championship_a'),
    count(*) FILTER (WHERE division = 'championship_b'),
    count(*) FILTER (WHERE division = 'championship_pool')
  INTO v_sl, v_a, v_b, v_pool
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id;

  IF v_sl <> 20 THEN
    RAISE EXCEPTION 'Super League needs exactly 20 clubs (has %)', v_sl;
  END IF;

  IF v_a <> 0 AND (v_a < 10 OR v_a > 20) THEN
    RAISE EXCEPTION 'Championship A needs 0 or 10–20 clubs (has %)', v_a;
  END IF;

  IF v_b <> 0 AND (v_a <> 20 OR v_b < 10 OR v_b > 20) THEN
    RAISE EXCEPTION 'Championship B needs Championship A full (20) and 10–20 clubs (A %, B %)', v_a, v_b;
  END IF;

  IF v_pool > 0 THEN
    RAISE EXCEPTION '% clubs still in the Championship pool — draw A/B or move them to standby', v_pool;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config WHERE season_id = p_season_id
  ) INTO v_has_calendar;

  IF NOT v_has_calendar THEN
    RAISE EXCEPTION 'Set the real-world season calendar (first Friday 19:00 UK) before starting the season';
  END IF;

  UPDATE public.competition_seasons
  SET is_current = false
  WHERE is_current = true;

  UPDATE public.competition_seasons
  SET status = 'active',
      is_current = true,
      started_at = coalesce(started_at, now())
  WHERE id = p_season_id;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'competition_seasons'
      AND column_name = 'activated_at'
  ) THEN
    EXECUTE
      'UPDATE public.competition_seasons
       SET activated_at = coalesce(activated_at, now())
       WHERE id = $1'
    USING p_season_id;
  END IF;

  UPDATE public.global_settings
  SET league_phase = NULL, updated_at = now()
  WHERE id = 1;

  IF to_regprocedure('public.competition_stadium_snapshot_season_start(bigint)') IS NOT NULL THEN
    PERFORM public.competition_stadium_snapshot_season_start(p_season_id);
  END IF;

  IF to_regprocedure('public.competition_club_prestige_lock_season(bigint)') IS NOT NULL THEN
    PERFORM public.competition_club_prestige_lock_season(p_season_id);
  END IF;

  IF to_regprocedure('public.competition_reset_club_season_quotas()') IS NOT NULL THEN
    PERFORM public.competition_reset_club_season_quotas();
  ELSE
    IF to_regprocedure('public.club_reset_voluntary_contract_releases()') IS NOT NULL THEN
      PERFORM public.club_reset_voluntary_contract_releases();
    END IF;
    IF to_regprocedure('public.manager_reset_season_quotas()') IS NOT NULL THEN
      PERFORM public.manager_reset_season_quotas();
    END IF;
  END IF;

  IF to_regprocedure('public.club_owner_availability_carry_forward(bigint)') IS NOT NULL THEN
    PERFORM public.club_owner_availability_carry_forward(p_season_id);
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7) Club auction listings skip archived clubs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_club_auction_seed_listings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_opening numeric;
  v_inserted int := 0;
  v_skipped int := 0;
  v_total smallint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::smallint INTO v_total
  FROM public."Clubs" c2
  WHERE c2."ShortName" <> 'FOREIGN'
    AND NOT coalesce(c2.is_archived, false);

  FOR v_club IN
    SELECT
      c."ShortName" AS club_short_name,
      coalesce(c."Capacity", 0)::int AS capacity,
      p.prestige_rank
    FROM public."Clubs" c
    LEFT JOIN public.competition_club_prestige_public p
      ON p.club_short_name = c."ShortName"
    WHERE c."ShortName" <> 'FOREIGN'
      AND c.owner_id IS NULL
      AND NOT coalesce(c.is_archived, false)
    ORDER BY p.prestige_rank NULLS LAST, c."ShortName"
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public."Club_Auction_Listings" l
      WHERE l.club_short_name = v_club.club_short_name
        AND l.status = 'Active'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_opening := public.club_auction_opening_bid_for_capacity(v_club.capacity);

    INSERT INTO public."Club_Auction_Listings" (
      club_short_name,
      status,
      opening_bid,
      reserve_price,
      prestige_rank,
      expected_position,
      created_at,
      updated_at
    )
    VALUES (
      v_club.club_short_name,
      'Active',
      v_opening,
      v_opening,
      v_club.prestige_rank,
      public.competition_club_baseline_expected_position(v_club.prestige_rank, v_total),
      now(),
      now()
    );

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'inserted', v_inserted,
    'skipped_existing_active', v_skipped
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_owner_league_priority() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_create_season(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_register_missing_clubs(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_assign_divisions_from_owners(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_set_club_division(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_bulk_set_divisions(bigint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_activate_season(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_auction_seed_listings() TO authenticated;

NOTIFY pgrst, 'reload schema';
