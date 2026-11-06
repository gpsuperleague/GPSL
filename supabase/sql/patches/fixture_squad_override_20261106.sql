-- =============================================================================
-- Per-match lineup beside the club default squad (2026-11-06)
-- =============================================================================
-- club_matchday_squad stays one row per club. Nothing already saved is moved.
-- A second pair of tables stores a lineup only when an owner presses
-- "Save for this match". Check-in, the squad-issues banner, result stats and
-- Match Centre use that lineup when one exists, and the club default otherwise.
--
-- Run once in the Supabase SQL editor. Safe to re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_fixture_matchday_squad (
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  fixture_id bigint NOT NULL
    REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  pitch_layout jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_short_name, fixture_id)
);

CREATE TABLE IF NOT EXISTS public.club_fixture_matchday_squad_player (
  club_short_name text NOT NULL,
  fixture_id bigint NOT NULL,
  player_id text NOT NULL,
  slot_kind text NOT NULL,
  pitch_slot text,
  sort_order smallint NOT NULL DEFAULT 0,
  CONSTRAINT club_fixture_matchday_squad_player_pk
    PRIMARY KEY (club_short_name, fixture_id, player_id),
  CONSTRAINT club_fixture_matchday_squad_player_parent_fk
    FOREIGN KEY (club_short_name, fixture_id)
    REFERENCES public.club_fixture_matchday_squad (club_short_name, fixture_id)
    ON DELETE CASCADE,
  CONSTRAINT club_fixture_matchday_squad_player_kind_chk
    CHECK (slot_kind IN ('pitch', 'bench', 'reserve')),
  CONSTRAINT club_fixture_matchday_squad_player_pitch_chk
    CHECK (
      (slot_kind = 'pitch' AND pitch_slot IS NOT NULL)
      OR (slot_kind <> 'pitch' AND pitch_slot IS NULL)
    ),
  CONSTRAINT club_fixture_matchday_squad_pitch_slot_unique
    UNIQUE (club_short_name, fixture_id, pitch_slot)
);

CREATE INDEX IF NOT EXISTS club_fixture_matchday_squad_player_fx_idx
  ON public.club_fixture_matchday_squad_player (fixture_id, club_short_name);

-- Fixture lineup when one is saved, otherwise the club default.
CREATE OR REPLACE FUNCTION public.club_matchday_squad_for_fixture(
  p_club text,
  p_fixture_id bigint
)
RETURNS TABLE (
  player_id text,
  slot_kind text,
  pitch_slot text,
  sort_order smallint,
  squad_source text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH override AS (
    SELECT
      sp.player_id,
      sp.slot_kind,
      sp.pitch_slot,
      sp.sort_order,
      'fixture'::text AS squad_source
    FROM public.club_fixture_matchday_squad_player sp
    WHERE upper(btrim(sp.club_short_name)) = upper(btrim(coalesce(p_club, '')))
      AND sp.fixture_id = p_fixture_id
  )
  SELECT * FROM override
  UNION ALL
  SELECT
    sp.player_id,
    sp.slot_kind,
    sp.pitch_slot,
    sp.sort_order,
    'default'::text
  FROM public.club_matchday_squad_player sp
  WHERE upper(btrim(sp.club_short_name)) = upper(btrim(coalesce(p_club, '')))
    AND NOT EXISTS (SELECT 1 FROM override);
$function$;

CREATE OR REPLACE FUNCTION public.club_matchday_pitch_layout_for_fixture(
  p_club text,
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_layout jsonb;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.club_fixture_matchday_squad_player sp
    WHERE upper(btrim(sp.club_short_name)) = upper(btrim(coalesce(p_club, '')))
      AND sp.fixture_id = p_fixture_id
  ) THEN
    SELECT h.pitch_layout
    INTO v_layout
    FROM public.club_fixture_matchday_squad h
    WHERE upper(btrim(h.club_short_name)) = upper(btrim(coalesce(p_club, '')))
      AND h.fixture_id = p_fixture_id;
    RETURN coalesce(v_layout, '{}'::jsonb);
  END IF;

  SELECT s.pitch_layout
  INTO v_layout
  FROM public.club_matchday_squad s
  WHERE upper(btrim(s.club_short_name)) = upper(btrim(coalesce(p_club, '')));
  RETURN coalesce(v_layout, '{}'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_save_fixture_matchday_squad(
  p_fixture_id bigint,
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
  v_fixture public.competition_fixtures%ROWTYPE;
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
  IF p_fixture_id IS NULL THEN
    RAISE EXCEPTION 'fixture_id required';
  END IF;
  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'p_slots must be a JSON array';
  END IF;
  IF jsonb_array_length(p_slots) = 0 THEN
    RAISE EXCEPTION 'Save at least one player, or use the default squad for this match';
  END IF;
  IF jsonb_array_length(p_slots) > 23 THEN
    RAISE EXCEPTION 'Matchday squad cannot exceed 23 players';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;
  IF upper(btrim(v_club)) NOT IN (
    upper(btrim(v_fixture.home_club_short_name)),
    upper(btrim(v_fixture.away_club_short_name))
  ) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;
  IF v_fixture.status IS DISTINCT FROM 'scheduled' THEN
    RAISE EXCEPTION 'A match lineup can only be saved while the fixture is still scheduled';
  END IF;
  IF coalesce(v_fixture.competition_type, 'league') NOT IN ('league', 'cup') THEN
    RAISE EXCEPTION 'Match lineups are for league and cup fixtures';
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
      AND upper(btrim(p."Contracted_Team")) = upper(btrim(v_club));
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

  INSERT INTO public.club_fixture_matchday_squad (
    club_short_name, fixture_id, pitch_layout, updated_at
  )
  VALUES (v_club, p_fixture_id, v_layout, now())
  ON CONFLICT (club_short_name, fixture_id) DO UPDATE
  SET pitch_layout = EXCLUDED.pitch_layout,
      updated_at = now();

  DELETE FROM public.club_fixture_matchday_squad_player
  WHERE club_short_name = v_club
    AND fixture_id = p_fixture_id;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    INSERT INTO public.club_fixture_matchday_squad_player (
      club_short_name, fixture_id, player_id, slot_kind, pitch_slot, sort_order
    )
    VALUES (
      v_club,
      p_fixture_id,
      btrim(v_row->>'player_id'),
      btrim(v_row->>'slot_kind'),
      nullif(btrim(v_row->>'pitch_slot'), ''),
      coalesce((v_row->>'sort_order')::smallint, 0)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'fixture_id', p_fixture_id,
    'squad_source', 'fixture',
    'total', v_total,
    'pitch', v_pitch_count,
    'bench', v_bench_count,
    'gk', v_gk
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_clear_fixture_matchday_squad(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures%ROWTYPE;
  v_removed int := 0;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;
  IF upper(btrim(v_club)) NOT IN (
    upper(btrim(v_fixture.home_club_short_name)),
    upper(btrim(v_fixture.away_club_short_name))
  ) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;
  IF v_fixture.status IS DISTINCT FROM 'scheduled' THEN
    RAISE EXCEPTION 'This match has already been played — its saved lineup stays as it was';
  END IF;

  DELETE FROM public.club_fixture_matchday_squad
  WHERE club_short_name = v_club
    AND fixture_id = p_fixture_id;
  GET DIAGNOSTICS v_removed = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'fixture_id', p_fixture_id,
    'removed', v_removed > 0
  );
END;
$function$;

-- Check-in reads the fixture lineup when one is saved. Body matches
-- fixture_check_in_age_cast_fix_20261022.sql aside from that read.
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
  v_bench_required int := 12;
  v_issues text[] := ARRAY[]::text[];
  v_unavailable text[] := ARRAY[]::text[];
  v_source text := 'default';
  v_age numeric;
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
      sp.squad_source,
      p."Name" AS player_name,
      p."Age"::text AS age_text,
      upper(btrim(coalesce(p."Position", ''))) AS pos,
      CASE
        WHEN to_regprocedure('public.is_player_homegrown(text, text)') IS NOT NULL
          THEN coalesce(public.is_player_homegrown(sp.player_id, v_club), false)
        ELSE false
      END AS is_hg,
      CASE
        WHEN to_regprocedure('public.competition_player_unavailable_for_fixture(bigint, text)') IS NOT NULL
          THEN public.competition_player_unavailable_for_fixture(p_fixture_id, sp.player_id)
        ELSE NULL
      END AS unavailable_detail
    FROM public.club_matchday_squad_for_fixture(v_club, p_fixture_id) sp
    JOIN public."Players" p
      ON p."Konami_ID"::text = sp.player_id
  LOOP
    v_total := v_total + 1;
    v_source := coalesce(r.squad_source, v_source);
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

    BEGIN
      v_age := public.player_age_numeric(r.age_text);
    EXCEPTION WHEN others THEN
      v_age := NULL;
    END;
    IF v_age IS NOT NULL AND v_age <= 21 THEN
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

  IF to_regprocedure('public.matchday_required_bench_for_club(text, bigint)') IS NOT NULL THEN
    v_bench_required := public.matchday_required_bench_for_club(v_club, p_fixture_id);
  END IF;

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
        ELSE format(
          'Your saved matchday squad needs %s subs on the bench — every available player (currently %s).',
          v_bench_required, v_bench
        )
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

  IF to_regprocedure('public.gpsl_owner_ready_issue_prepend(text, text[])') IS NOT NULL THEN
    v_issues := public.gpsl_owner_ready_issue_prepend(v_club, v_issues);
  END IF;

  RETURN jsonb_build_object(
    'ok', coalesce(array_length(v_issues, 1), 0) = 0,
    'club_short_name', v_club,
    'fixture_id', p_fixture_id,
    'squad_source', v_source,
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
  'Check-in readiness. Uses a lineup saved for this fixture when one exists, otherwise the club default. 11 starters, 12 subs (or every available player), GK, no injured/suspended.';

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
    FROM public.club_matchday_squad_for_fixture(v_club, p_fixture_id) sp
    JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
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

-- Match Centre preview. Fixture argument prefers a saved match lineup.
CREATE OR REPLACE FUNCTION public.competition_match_club_preview(
  p_club text,
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club, '')), '');
  v_layout jsonb;
  v_updated timestamptz;
  v_source text := 'default';
  v_formation_id text;
  v_formation_name text;
  v_mgr public."Managers"%rowtype;
  v_xi jsonb := '[]'::jsonb;
  v_bench jsonb := '[]'::jsonb;
  v_has_squad boolean := false;
BEGIN
  IF v_club IS NULL THEN
    RETURN NULL;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_fixture_matchday_squad_player sp
    WHERE upper(btrim(sp.club_short_name)) = upper(btrim(v_club))
      AND sp.fixture_id = p_fixture_id
  ) THEN
    v_source := 'fixture';
    SELECT h.pitch_layout, h.updated_at
    INTO v_layout, v_updated
    FROM public.club_fixture_matchday_squad h
    WHERE upper(btrim(h.club_short_name)) = upper(btrim(v_club))
      AND h.fixture_id = p_fixture_id;
  ELSE
    SELECT s.pitch_layout, s.updated_at
    INTO v_layout, v_updated
    FROM public.club_matchday_squad s
    WHERE upper(btrim(s.club_short_name)) = upper(btrim(v_club));
  END IF;

  v_formation_id := nullif(btrim(coalesce(v_layout->>'formation_id', '')), '');

  IF v_layout IS NOT NULL THEN
    SELECT f.name
    INTO v_formation_name
    FROM public.club_matchday_saved_formation f
    WHERE upper(btrim(f.club_short_name)) = upper(btrim(v_club))
      AND f.pitch_layout = v_layout
      AND nullif(btrim(coalesce(f.name, '')), '') IS NOT NULL
    ORDER BY f.slot_no
    LIMIT 1;
  END IF;

  IF v_formation_name IS NULL THEN
    v_formation_name := v_formation_id;
  END IF;

  SELECT m.*
  INTO v_mgr
  FROM public."Managers" m
  WHERE upper(btrim(m.contracted_club)) = upper(btrim(v_club))
  LIMIT 1;

  IF NOT FOUND OR v_mgr.id IS NULL THEN
    SELECT m.*
    INTO v_mgr
    FROM public."Clubs" c
    JOIN public."Managers" m ON m.id = c.manager_id
    WHERE upper(btrim(c."ShortName")) = upper(btrim(v_club))
    LIMIT 1;
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', x.player_id,
        'player_name', x.player_name,
        'player_position', x.player_position,
        'pitch_slot', x.pitch_slot,
        'role_label', x.role_label
      )
      ORDER BY x.sort_key, x.sort_order, x.player_name
    ),
    '[]'::jsonb
  )
  INTO v_xi
  FROM (
    SELECT
      sp.player_id,
      coalesce(p."Name", sp.player_id) AS player_name,
      coalesce(p."Position", '') AS player_position,
      sp.pitch_slot,
      coalesce(
        nullif(btrim(v_layout -> sp.pitch_slot ->> 'label'), ''),
        sp.pitch_slot,
        p."Position",
        ''
      ) AS role_label,
      CASE sp.pitch_slot
        WHEN 'GK' THEN 0
        WHEN 'LB' THEN 1
        WHEN 'CB1' THEN 2
        WHEN 'CB2' THEN 3
        WHEN 'RB' THEN 4
        WHEN 'LMF' THEN 5
        WHEN 'CMF' THEN 6
        WHEN 'RMF' THEN 7
        WHEN 'LWF' THEN 8
        WHEN 'CF' THEN 9
        WHEN 'RWF' THEN 10
        ELSE 50
      END AS sort_key,
      sp.sort_order
    FROM public.club_matchday_squad_for_fixture(v_club, p_fixture_id) sp
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id::text
    WHERE sp.slot_kind = 'pitch'
  ) x;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', x.player_id,
        'player_name', x.player_name,
        'player_position', x.player_position,
        'sort_order', x.sort_order,
        'role_label', x.role_label
      )
      ORDER BY x.sort_order, x.player_name
    ),
    '[]'::jsonb
  )
  INTO v_bench
  FROM (
    SELECT
      sp.player_id,
      coalesce(p."Name", sp.player_id) AS player_name,
      coalesce(p."Position", '') AS player_position,
      sp.sort_order,
      CASE
        WHEN sp.sort_order < 5 THEN 'Sub'
        ELSE 'Squad'
      END AS role_label
    FROM public.club_matchday_squad_for_fixture(v_club, p_fixture_id) sp
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id::text
    WHERE sp.slot_kind IN ('bench', 'reserve')
  ) x;

  v_has_squad :=
    jsonb_array_length(coalesce(v_xi, '[]'::jsonb)) > 0
    OR jsonb_array_length(coalesce(v_bench, '[]'::jsonb)) > 0;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'has_squad', v_has_squad,
    'squad_source', v_source,
    'squad_updated_at', v_updated,
    'formation_id', v_formation_id,
    'formation_name', v_formation_name,
    'manager_id', v_mgr.id,
    'manager_name', v_mgr.name,
    'manager_rating', v_mgr.rating,
    'strongest_playstyle', public.manager_strongest_playstyle(v_mgr),
    'xi', coalesce(v_xi, '[]'::jsonb),
    'bench', coalesce(v_bench, '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_match_club_preview(p_club text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT public.competition_match_club_preview(p_club, NULL::bigint);
$function$;

COMMENT ON FUNCTION public.competition_match_club_preview(text, bigint) IS
  'Match Centre pre-match squad. Uses a lineup saved for this fixture when one exists, otherwise the club default.';

-- Point the live report at the fixture-aware preview. Same payload as
-- competition_match_report_prematch_20260918.sql, with the fixture id passed through.
CREATE OR REPLACE FUNCTION public.competition_match_report(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fx record;
  v_home_players jsonb;
  v_away_players jsonb;
  v_injuries jsonb;
  v_attendance int;
  v_capacity int;
  v_home_player_goals int := 0;
  v_away_player_goals int := 0;
BEGIN
  IF p_fixture_id IS NULL THEN
    RAISE EXCEPTION 'fixture_id required';
  END IF;

  SELECT
    f.id,
    f.season_id,
    f.division,
    f.competition_type,
    f.cup_code,
    f.cup_round,
    f.cup_match,
    f.matchday,
    f.gpsl_month,
    f.home_club_short_name,
    hc."Club" AS home_club_name,
    hc."Stadium" AS home_stadium,
    f.away_club_short_name,
    ac."Club" AS away_club_name,
    f.home_goals,
    f.away_goals,
    f.status,
    f.is_forfeit,
    f.weather,
    f.pitch_condition,
    sch.agreed_kickoff_at,
    sch.status AS schedule_status
  INTO v_fx
  FROM public.competition_fixtures f
  JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
  JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
  LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
  WHERE f.id = p_fixture_id;

  IF v_fx IS NULL THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT coalesce(
    jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_key, x.player_name),
    '[]'::jsonb
  )
  INTO v_home_players
  FROM (
    SELECT
      m.player_id,
      coalesce(p."Name", m.player_id) AS player_name,
      coalesce(m.appeared, false) AS appeared,
      coalesce(m.started, false) AS started,
      coalesce(m.subbed_on, false) AS subbed_on,
      coalesce(m.goals, 0) AS goals,
      coalesce(m.own_goals, 0) AS own_goals,
      coalesce(m.assists, 0) AS assists,
      m.rating,
      coalesce(m.is_player_of_match, false) AS is_player_of_match,
      coalesce(m.yellow_card, false) AS yellow_card,
      coalesce(m.red_card, false) AS red_card,
      CASE
        WHEN coalesce(m.started, false) THEN 0
        WHEN coalesce(m.subbed_on, false) THEN 1
        ELSE 2
      END AS sort_key
    FROM public.competition_match_player_stats m
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = v_fx.home_club_short_name
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
        OR coalesce(m.goals, 0) > 0
        OR coalesce(m.own_goals, 0) > 0
        OR coalesce(m.assists, 0) > 0
        OR coalesce(m.yellow_card, false)
        OR coalesce(m.red_card, false)
        OR coalesce(m.is_player_of_match, false)
      )
  ) x;

  SELECT coalesce(
    jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_key, x.player_name),
    '[]'::jsonb
  )
  INTO v_away_players
  FROM (
    SELECT
      m.player_id,
      coalesce(p."Name", m.player_id) AS player_name,
      coalesce(m.appeared, false) AS appeared,
      coalesce(m.started, false) AS started,
      coalesce(m.subbed_on, false) AS subbed_on,
      coalesce(m.goals, 0) AS goals,
      coalesce(m.own_goals, 0) AS own_goals,
      coalesce(m.assists, 0) AS assists,
      m.rating,
      coalesce(m.is_player_of_match, false) AS is_player_of_match,
      coalesce(m.yellow_card, false) AS yellow_card,
      coalesce(m.red_card, false) AS red_card,
      CASE
        WHEN coalesce(m.started, false) THEN 0
        WHEN coalesce(m.subbed_on, false) THEN 1
        ELSE 2
      END AS sort_key
    FROM public.competition_match_player_stats m
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = v_fx.away_club_short_name
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
        OR coalesce(m.goals, 0) > 0
        OR coalesce(m.own_goals, 0) > 0
        OR coalesce(m.assists, 0) > 0
        OR coalesce(m.yellow_card, false)
        OR coalesce(m.red_card, false)
        OR coalesce(m.is_player_of_match, false)
      )
  ) x;

  SELECT coalesce(sum((p ->> 'goals')::int), 0)
  INTO v_home_player_goals
  FROM jsonb_array_elements(coalesce(v_home_players, '[]'::jsonb)) p;

  SELECT coalesce(sum((p ->> 'goals')::int), 0)
  INTO v_away_player_goals
  FROM jsonb_array_elements(coalesce(v_away_players, '[]'::jsonb)) p;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', i.player_id,
        'player_name', coalesce(p."Name", i.player_id::text),
        'club_short_name', i.club_short_name,
        'label', coalesce(nullif(btrim(i.label), ''), cat.name, 'Injury'),
        'severity', coalesce(i.severity, cat.severity)
      )
      ORDER BY i.club_short_name, p."Name"
    ),
    '[]'::jsonb
  )
  INTO v_injuries
  FROM public.competition_player_injuries i
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id::text
  LEFT JOIN public.competition_injury_catalogue cat ON cat.id = i.catalogue_id
  WHERE i.source_fixture_id = p_fixture_id;

  SELECT
    round(
      (l.metadata ->> 'capacity')::numeric
      * (l.metadata ->> 'attendance_rate')::numeric
    )::int,
    nullif(l.metadata ->> 'capacity', '')::int
  INTO v_attendance, v_capacity
  FROM public.competition_finance_ledger l
  WHERE l.fixture_id = p_fixture_id
    AND l.entry_type = 'gate_league_home'
  LIMIT 1;

  RETURN jsonb_build_object(
    'fixture', jsonb_build_object(
      'id', v_fx.id,
      'season_id', v_fx.season_id,
      'division', v_fx.division,
      'competition_type', v_fx.competition_type,
      'cup_code', v_fx.cup_code,
      'cup_round', v_fx.cup_round,
      'cup_match', v_fx.cup_match,
      'matchday', v_fx.matchday,
      'gpsl_month', v_fx.gpsl_month,
      'home_club_short_name', v_fx.home_club_short_name,
      'home_club_name', v_fx.home_club_name,
      'home_stadium', v_fx.home_stadium,
      'away_club_short_name', v_fx.away_club_short_name,
      'away_club_name', v_fx.away_club_name,
      'home_goals', v_fx.home_goals,
      'away_goals', v_fx.away_goals,
      'status', v_fx.status,
      'is_forfeit', v_fx.is_forfeit,
      'weather', v_fx.weather,
      'pitch_condition', v_fx.pitch_condition,
      'agreed_kickoff_at', v_fx.agreed_kickoff_at,
      'schedule_status', v_fx.schedule_status
    ),
    'home_players', coalesce(v_home_players, '[]'::jsonb),
    'away_players', coalesce(v_away_players, '[]'::jsonb),
    'injuries', coalesce(v_injuries, '[]'::jsonb),
    'attendance', v_attendance,
    'capacity', v_capacity,
    'home_og_for', greatest(coalesce(v_fx.home_goals, 0) - v_home_player_goals, 0),
    'away_og_for', greatest(coalesce(v_fx.away_goals, 0) - v_away_player_goals, 0),
    'has_stats', (
      jsonb_array_length(coalesce(v_home_players, '[]'::jsonb))
      + jsonb_array_length(coalesce(v_away_players, '[]'::jsonb))
    ) > 0,
    'home_preview', public.competition_match_club_preview(v_fx.home_club_short_name, p_fixture_id),
    'away_preview', public.competition_match_club_preview(v_fx.away_club_short_name, p_fixture_id)
  );
END;
$function$;

COMMENT ON FUNCTION public.competition_match_report(bigint) IS
  'Full match centre payload. Prematch squad uses a lineup saved for this fixture when one exists.';

DROP VIEW IF EXISTS public.club_fixture_matchday_squad_public;
CREATE VIEW public.club_fixture_matchday_squad_public
WITH (security_invoker = false)
AS
SELECT
  sp.club_short_name,
  sp.fixture_id,
  sp.player_id,
  sp.slot_kind,
  sp.pitch_slot,
  sp.sort_order,
  h.pitch_layout,
  h.updated_at AS squad_updated_at
FROM public.club_fixture_matchday_squad_player sp
JOIN public.club_fixture_matchday_squad h
  ON h.club_short_name = sp.club_short_name
 AND h.fixture_id = sp.fixture_id
WHERE sp.club_short_name = public.my_club_shortname();

ALTER TABLE public.club_fixture_matchday_squad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.club_fixture_matchday_squad_player ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_fixture_matchday_squad_owner ON public.club_fixture_matchday_squad;
CREATE POLICY club_fixture_matchday_squad_owner ON public.club_fixture_matchday_squad
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

DROP POLICY IF EXISTS club_fixture_matchday_squad_player_owner ON public.club_fixture_matchday_squad_player;
CREATE POLICY club_fixture_matchday_squad_player_owner ON public.club_fixture_matchday_squad_player
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

GRANT SELECT ON public.club_fixture_matchday_squad TO authenticated;
GRANT SELECT ON public.club_fixture_matchday_squad_player TO authenticated;
GRANT SELECT ON public.club_fixture_matchday_squad_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_matchday_squad_for_fixture(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_matchday_pitch_layout_for_fixture(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_save_fixture_matchday_squad(bigint, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_clear_fixture_matchday_squad(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_matchday_checkin_ready(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_club_preview(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_club_preview(text, bigint) TO anon;
GRANT EXECUTE ON FUNCTION public.competition_match_club_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_club_preview(text) TO anon;
GRANT EXECUTE ON FUNCTION public.competition_match_report(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_report(bigint) TO anon;

NOTIFY pgrst, 'reload schema';
