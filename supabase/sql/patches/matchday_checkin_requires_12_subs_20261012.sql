-- =============================================================================
-- Check-in squad gate: 12 valid subs required (2026-10-12)
-- =============================================================================
-- The saved matchday squad must now have 12 subs on the bench as well as
-- exactly 11 starters, a goalkeeper and no injured / suspended players.
-- If the club cannot name 12 fit subs (injuries, suspensions, small squad),
-- every available non-starter must be on the bench instead.
-- Updates both gates:
--   • club_matchday_checkin_ready(fixture)        — Check in button
--   • matchday_squad_issues_for_club(club, fixture) — dashboard / reminders
-- Also re-applies the Save squad function WITHOUT the old matchday minimums
-- (2 HG in the XI / 5 HG / 2 U21 in the 23). Those were dropped on 25 Sep but
-- an older version could still be live. HG / U21 minimums apply to the overall
-- club squad only.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_save_matchday_squad(
  p_slots jsonb,
  p_pitch_layout jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_row jsonb;
  v_player_id text;
  v_kind text;
  v_pitch_slot text;
  v_sort smallint;
  v_total int := 0;
  v_pitch_count int := 0;
  v_bench_count int := 0;
  v_reserve_count int := 0;
  v_layout jsonb;
  v_mirror_err text;
  v_gk int := 0;
  v_pos text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'p_slots must be a JSON array';
  END IF;

  IF jsonb_array_length(p_slots) > 23 THEN
    RAISE EXCEPTION 'Matchday squad cannot exceed 23 players';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_player_id := btrim(v_row->>'player_id');
    v_kind := btrim(v_row->>'slot_kind');
    v_pitch_slot := nullif(btrim(v_row->>'pitch_slot'), '');

    IF v_player_id IS NULL OR v_player_id = '' THEN
      RAISE EXCEPTION 'Each slot needs player_id';
    END IF;
    IF v_kind NOT IN ('pitch', 'bench', 'reserve') THEN
      RAISE EXCEPTION 'Invalid slot_kind for player %', v_player_id;
    END IF;
    IF v_kind = 'pitch' AND v_pitch_slot IS NULL THEN
      RAISE EXCEPTION 'Pitch players need pitch_slot';
    END IF;
    IF v_kind <> 'pitch' AND v_pitch_slot IS NOT NULL THEN
      RAISE EXCEPTION 'Only pitch players may have pitch_slot';
    END IF;

    SELECT upper(btrim(coalesce(p."Position", '')))
    INTO v_pos
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_player_id
      AND p."Contracted_Team" = v_club;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Player % is not in your contracted squad', v_player_id;
    END IF;

    IF v_pos IN ('GK', 'GOALKEEPER') THEN
      v_gk := v_gk + 1;
    END IF;

    v_total := v_total + 1;
    IF v_kind = 'pitch' THEN v_pitch_count := v_pitch_count + 1;
    ELSIF v_kind = 'bench' THEN v_bench_count := v_bench_count + 1;
    ELSE v_reserve_count := v_reserve_count + 1;
    END IF;
  END LOOP;

  IF v_pitch_count > 11 THEN
    RAISE EXCEPTION 'Maximum 11 players on the pitch (got %)', v_pitch_count;
  END IF;
  IF v_bench_count > 12 THEN
    RAISE EXCEPTION 'Maximum 12 bench players (got %)', v_bench_count;
  END IF;
  IF v_reserve_count > 0 THEN
    RAISE EXCEPTION 'Reserves are no longer used — use bench slots (max 12)';
  END IF;
  IF v_gk < 1 THEN
    RAISE EXCEPTION 'Matchday squad needs at least 1 goalkeeper (have %)', v_gk;
  END IF;

  v_layout := coalesce(p_pitch_layout, '{}'::jsonb);
  IF jsonb_typeof(v_layout) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_pitch_layout must be a JSON object';
  END IF;

  IF to_regprocedure('public.validate_pitch_layout_mirroring(jsonb)') IS NOT NULL THEN
    v_mirror_err := public.validate_pitch_layout_mirroring(v_layout);
    IF v_mirror_err IS NOT NULL THEN
      RAISE EXCEPTION '%', v_mirror_err;
    END IF;
  END IF;

  INSERT INTO public.club_matchday_squad (club_short_name, pitch_layout, updated_at)
  VALUES (v_club, v_layout, now())
  ON CONFLICT (club_short_name) DO UPDATE
  SET pitch_layout = EXCLUDED.pitch_layout,
      updated_at = now();

  DELETE FROM public.club_matchday_squad_player
  WHERE club_short_name = v_club;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    INSERT INTO public.club_matchday_squad_player (
      club_short_name, player_id, slot_kind, pitch_slot, sort_order
    )
    VALUES (
      v_club,
      btrim(v_row->>'player_id'),
      btrim(v_row->>'slot_kind'),
      nullif(btrim(v_row->>'pitch_slot'), ''),
      coalesce((v_row->>'sort_order')::smallint, 0)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'total', v_total,
    'pitch', v_pitch_count,
    'bench', v_bench_count,
    'reserve', v_reserve_count,
    'gk', v_gk,
    'u21_hg_mins_enforced', false
  );
END;
$function$;

COMMENT ON FUNCTION public.club_save_matchday_squad(jsonb, jsonb) IS
  'Save matchday 23. Enforces GK (≥1) and size limits. No HG / U21 matchday minimums (club squad rules only).';

GRANT EXECUTE ON FUNCTION public.club_save_matchday_squad(jsonb, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.matchday_required_bench_for_club(
  p_club text,
  p_fixture_id bigint
)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_has_unavail_fn boolean :=
    to_regprocedure('public.competition_player_unavailable_for_fixture(bigint, text)') IS NOT NULL;
  v_available int := 0;
BEGIN
  IF v_club IS NULL THEN
    RETURN 12;
  END IF;

  SELECT count(*)::int INTO v_available
  FROM public."Players" p
  WHERE upper(btrim(coalesce(p."Contracted_Team"::text, ''))) = v_club
    AND (
      NOT v_has_unavail_fn
      OR coalesce(btrim(public.competition_player_unavailable_for_fixture(p_fixture_id, p."Konami_ID"::text)), '') = ''
    );

  RETURN least(12, greatest(0, v_available - 11));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.matchday_required_bench_for_club(text, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.club_matchday_checkin_ready(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures%rowtype;
  v_total int := 0;
  v_pitch int := 0;
  v_bench int := 0;
  v_reserve int := 0;
  v_gk int := 0;
  v_u21 int := 0;
  v_hg_xi int := 0;
  v_hg_total int := 0;
  v_bench_required int;
  v_issues text[] := ARRAY[]::text[];
  v_unavailable text[] := ARRAY[]::text[];
  r record;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  FOR r IN
    SELECT
      sp.player_id,
      sp.slot_kind,
      p."Name" AS player_name,
      p."Age" AS age,
      upper(btrim(coalesce(p."Position", ''))) AS pos,
      coalesce(public.is_player_homegrown(sp.player_id, v_club), false) AS is_hg,
      CASE
        WHEN to_regprocedure('public.competition_player_unavailable_for_fixture(bigint, text)') IS NOT NULL
          THEN public.competition_player_unavailable_for_fixture(p_fixture_id, sp.player_id)
        ELSE NULL
      END AS unavailable_detail
    FROM public.club_matchday_squad_player sp
    JOIN public."Players" p
      ON p."Konami_ID"::text = sp.player_id
    WHERE sp.club_short_name = v_club
  LOOP
    v_total := v_total + 1;
    IF r.slot_kind = 'pitch' THEN
      v_pitch := v_pitch + 1;
    ELSIF r.slot_kind = 'bench' THEN
      v_bench := v_bench + 1;
    ELSE
      v_reserve := v_reserve + 1;
    END IF;

    IF r.pos IN ('GK', 'GOALKEEPER') THEN
      v_gk := v_gk + 1;
    END IF;
    IF r.age IS NOT NULL AND r.age <= 21 THEN
      v_u21 := v_u21 + 1;
    END IF;
    IF r.is_hg THEN
      v_hg_total := v_hg_total + 1;
      IF r.slot_kind = 'pitch' THEN
        v_hg_xi := v_hg_xi + 1;
      END IF;
    END IF;

    IF r.unavailable_detail IS NOT NULL AND btrim(r.unavailable_detail) <> '' THEN
      v_unavailable := array_append(
        v_unavailable,
        coalesce(nullif(btrim(r.player_name), ''), r.player_id) || ' (' || r.unavailable_detail || ')'
      );
    END IF;
  END LOOP;

  v_bench_required := public.matchday_required_bench_for_club(v_club, p_fixture_id);

  IF v_total = 0 THEN
    v_issues := array_append(v_issues, 'Save your matchday squad before check-in.');
  END IF;
  IF v_pitch <> 11 THEN
    v_issues := array_append(
      v_issues,
      format('Your saved matchday XI must have exactly 11 starters (currently %s).', v_pitch)
    );
  END IF;
  IF v_bench < v_bench_required THEN
    v_issues := array_append(
      v_issues,
      CASE WHEN v_bench_required = 12
        THEN format('Your saved matchday squad needs 12 subs on the bench (currently %s).', v_bench)
        ELSE format('Your saved matchday squad needs %s subs on the bench — every available player (currently %s).',
                    v_bench_required, v_bench)
      END
    );
  END IF;
  IF v_bench > 12 THEN
    v_issues := array_append(
      v_issues,
      format('Your saved matchday bench can have at most 12 players (currently %s).', v_bench)
    );
  END IF;
  IF v_reserve > 0 THEN
    v_issues := array_append(v_issues, 'Reserves are not allowed in the saved matchday squad.');
  END IF;
  IF v_gk < 1 THEN
    v_issues := array_append(v_issues, 'Your saved matchday squad needs at least 1 goalkeeper.');
  END IF;
  IF coalesce(array_length(v_unavailable, 1), 0) > 0 THEN
    v_issues := array_append(
      v_issues,
      'Remove injured or suspended players from your saved matchday squad: '
        || array_to_string(v_unavailable, ', ')
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', coalesce(array_length(v_issues, 1), 0) = 0,
    'club_short_name', v_club,
    'fixture_id', p_fixture_id,
    'issues', to_jsonb(v_issues),
    'counts', jsonb_build_object(
      'total', v_total,
      'pitch', v_pitch,
      'bench', v_bench,
      'bench_required', v_bench_required,
      'reserve', v_reserve,
      'gk', v_gk,
      'u21', v_u21,
      'hg_xi', v_hg_xi,
      'hg_total', v_hg_total
    ),
    'u21_hg_mins_enforced', false
  );
END;
$function$;

COMMENT ON FUNCTION public.club_matchday_checkin_ready(bigint) IS
  'Check-in readiness for saved matchday 23: 11 starters, 12 subs (or every available player), GK, no injured/suspended.';

GRANT EXECUTE ON FUNCTION public.club_matchday_checkin_ready(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.matchday_squad_issues_for_club(
  p_club text,
  p_fixture_id bigint
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_total int := 0;
  v_pitch int := 0;
  v_bench int := 0;
  v_reserve int := 0;
  v_gk int := 0;
  v_bench_required int;
  v_issues text[] := ARRAY[]::text[];
  v_unavailable text[] := ARRAY[]::text[];
  v_has_unavail_fn boolean :=
    to_regprocedure('public.competition_player_unavailable_for_fixture(bigint, text)') IS NOT NULL;
  v_detail text;
  r record;
BEGIN
  IF v_club IS NULL THEN
    RETURN ARRAY['No club'];
  END IF;

  FOR r IN
    SELECT sp.player_id, sp.slot_kind, p."Name" AS player_name,
           upper(btrim(coalesce(p."Position", ''))) AS pos
    FROM public.club_matchday_squad_player sp
    JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
    WHERE upper(btrim(sp.club_short_name)) = v_club
  LOOP
    v_total := v_total + 1;
    IF r.slot_kind = 'pitch' THEN v_pitch := v_pitch + 1;
    ELSIF r.slot_kind = 'bench' THEN v_bench := v_bench + 1;
    ELSE v_reserve := v_reserve + 1;
    END IF;
    IF r.pos IN ('GK', 'GOALKEEPER') THEN v_gk := v_gk + 1; END IF;

    IF v_has_unavail_fn THEN
      v_detail := public.competition_player_unavailable_for_fixture(p_fixture_id, r.player_id);
      IF v_detail IS NOT NULL AND btrim(v_detail) <> '' THEN
        v_unavailable := array_append(
          v_unavailable,
          coalesce(nullif(btrim(r.player_name), ''), r.player_id) || ' (' || v_detail || ')'
        );
      END IF;
    END IF;
  END LOOP;

  v_bench_required := public.matchday_required_bench_for_club(v_club, p_fixture_id);

  IF v_total = 0 THEN
    v_issues := array_append(v_issues, 'No matchday squad saved.');
  END IF;
  IF v_pitch <> 11 THEN
    v_issues := array_append(v_issues, format('%s/11 starters saved (exactly 11 needed).', v_pitch));
  END IF;
  IF v_bench < v_bench_required THEN
    v_issues := array_append(v_issues, format('%s/%s subs saved (%s needed on the bench).',
      v_bench, v_bench_required, v_bench_required));
  END IF;
  IF v_bench > 12 THEN
    v_issues := array_append(v_issues, format('%s on the bench (max 12).', v_bench));
  END IF;
  IF v_reserve > 0 THEN
    v_issues := array_append(v_issues, 'Reserves are not allowed in the saved squad.');
  END IF;
  IF v_gk < 1 THEN
    v_issues := array_append(v_issues, 'No goalkeeper in the saved squad.');
  END IF;
  IF coalesce(array_length(v_unavailable, 1), 0) > 0 THEN
    v_issues := array_append(
      v_issues,
      'Unavailable for this match: ' || array_to_string(v_unavailable, ', ')
    );
  END IF;

  RETURN v_issues;
END;
$function$;

NOTIFY pgrst, 'reload schema';

-- Report: every club's saved bench vs requirement for its next scheduled fixture
WITH nxt AS (
  SELECT DISTINCT ON (c.club)
    c.club, f.id AS fixture_id
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  CROSS JOIN LATERAL (VALUES (upper(btrim(f.home_club_short_name))), (upper(btrim(f.away_club_short_name)))) c(club)
  WHERE f.status = 'scheduled'
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
  ORDER BY c.club, public.competition_gpsl_month_sort(f.gpsl_month), f.matchday, f.cup_round, f.id
)
SELECT
  n.club,
  n.fixture_id AS next_fixture,
  (SELECT count(*) FROM public.club_matchday_squad_player sp
    WHERE upper(btrim(sp.club_short_name)) = n.club AND sp.slot_kind = 'bench') AS saved_subs,
  public.matchday_required_bench_for_club(n.club, n.fixture_id) AS subs_required,
  array_to_string(public.matchday_squad_issues_for_club(n.club, n.fixture_id), ' | ') AS issues,
  coalesce((
    SELECT string_agg(p.proname, ', ')
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace AND ns.nspname = 'public'
    WHERE p.prosrc ILIKE '%2 home-grown%'
       OR p.prosrc ILIKE '%5 home-grown%'
       OR p.prosrc ILIKE '%2 under-21%'
  ), 'none') AS old_matchday_hg_u21_rules_still_live
FROM nxt n
ORDER BY (coalesce(array_length(public.matchday_squad_issues_for_club(n.club, n.fixture_id), 1), 0) = 0), n.club;
