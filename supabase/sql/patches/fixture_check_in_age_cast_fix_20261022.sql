-- =============================================================================
-- Fix check-in: operator does not exist: text <= integer (2026-10-22)
-- =============================================================================
-- Players."Age" is text. club_matchday_checkin_ready compared r.age <= 21 and
-- blew up on check-in (alert from gpsuperleague.github.io).
-- Cast via player_age_numeric. Keeps 12-subs readiness + Ready-for-August prepend.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.player_age_numeric(p_age text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_age IS NULL OR btrim(p_age) = '' THEN NULL::numeric
    ELSE btrim(p_age)::numeric
  END;
$$;

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

  -- Ready-for-August (no-op until August unlock)
  IF to_regprocedure('public.gpsl_owner_ready_issue_prepend(text, text[])') IS NOT NULL THEN
    v_issues := public.gpsl_owner_ready_issue_prepend(v_club, v_issues);
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
  'Check-in readiness for saved matchday 23: 11 starters, 12 subs (or every available player), GK, no injured/suspended. Age cast-safe.';

GRANT EXECUTE ON FUNCTION public.club_matchday_checkin_ready(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE 'club_matchday_checkin_ready: Age text<=int fixed — retry check-in.';
END $$;
