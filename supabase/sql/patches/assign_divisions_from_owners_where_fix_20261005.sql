-- =============================================================================
-- Fix: "Assign divisions from owners" failed with
--   "UPDATE requires a WHERE clause" (Supabase safe-update guard)
-- The plan-table UPDATE now has WHERE true. Behaviour is otherwise unchanged.
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

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

GRANT EXECUTE ON FUNCTION public.competition_admin_assign_divisions_from_owners(bigint, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
