-- =============================================================================
-- August forced star releases: credit market value (was 125% MV)
-- Fine unchanged (₿2.5m per over-cap star). Special-auction 125% prize release unchanged.
-- Run once in Supabase SQL Editor.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.club_enforce_squad_minimum(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_season_id bigint := p_season_id;
  v_count int;
  v_hg int;
  v_u21 int;
  v_stars int;
  v_star_cap int;
  v_short int;
  v_i int;
  v_exclude text[] := ARRAY[]::text[];
  v_errors text[] := ARRAY[]::text[];
  v_actions jsonb := '[]'::jsonb;
  v_action jsonb;
  v_fine_total numeric := 0;
  v_loan_total numeric := 0;
  v_loans int := 0;
  v_releases int := 0;
  v_size_short int := 0;
  v_hg_short int := 0;
  v_u21_short int := 0;
  v_star_over int := 0;
  v_fee numeric := public.squad_minimum_fine_amount();
  v_loan_fee numeric := public.squad_minimum_loan_fee_amount();
  v_pid text;
  v_rel jsonb;
  v_min_hg constant int := 8;
  v_min_u21 constant int := 5;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  IF NOT p_force AND NOT public.squad_minimum_punishments_active(v_season_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'before_august', 'club', v_club);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_squad_minimum_enforcement e
    WHERE e.season_id = v_season_id AND e.club_short_name = v_club
  ) THEN
    RETURN jsonb_build_object('ok', true, 'already_enforced', true, 'club', v_club);
  END IF;

  -- ===== 1) Size 竕･ 24 =====
  v_count := public.club_registered_squad_count(v_club);
  v_short := greatest(public.squad_minimum_size() - v_count, 0);
  v_size_short := v_short;

  FOR v_i IN 1..v_short LOOP
    PERFORM public.competition_apply_club_fine_tariff(
      v_club, 'breach_squad_24_min', v_fee,
      format('Below minimum squad at August (%s of %s missing)', v_i, v_short),
      NULL, v_season_id
    );
    v_fine_total := v_fine_total + v_fee;

    v_action := public.club_august_issue_loan(
      v_club, v_season_id, v_exclude, false, false, 'any'
    );
    IF jsonb_typeof(v_action -> 'exclude') = 'array'
       AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
      SELECT array_agg(x ORDER BY ord)
      INTO v_exclude
      FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
    END IF;
    IF v_action ->> 'error' IS NOT NULL THEN
      v_errors := array_append(v_errors, v_action ->> 'error');
    END IF;
    IF coalesce((v_action ->> 'ok')::boolean, false) THEN
      v_loans := v_loans + 1;
      v_loan_total := v_loan_total + v_loan_fee;
      IF v_action -> 'released' IS NOT NULL AND jsonb_typeof(v_action -> 'released') = 'object' THEN
        v_releases := v_releases + 1;
      END IF;
    END IF;
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'size', 'result', v_action));
  END LOOP;

  -- ===== 2) HG 竕･ 8 =====
  v_hg := public.club_hg_count(v_club);
  v_short := greatest(v_min_hg - v_hg, 0);
  v_hg_short := v_short;

  FOR v_i IN 1..v_short LOOP
    PERFORM public.competition_apply_club_fine_tariff(
      v_club, 'breach_squad_hg_min', v_fee,
      format('Below home-grown minimum at August (%s of %s missing)', v_i, v_short),
      NULL, v_season_id
    );
    v_fine_total := v_fine_total + v_fee;

    v_action := public.club_august_issue_loan(
      v_club, v_season_id, v_exclude, false, true, 'non_hg'
    );
    IF jsonb_typeof(v_action -> 'exclude') = 'array'
       AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
      SELECT array_agg(x ORDER BY ord)
      INTO v_exclude
      FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
    END IF;
    IF v_action ->> 'error' IS NOT NULL THEN
      v_errors := array_append(v_errors, v_action ->> 'error');
    END IF;
    IF coalesce((v_action ->> 'ok')::boolean, false) THEN
      v_loans := v_loans + 1;
      v_loan_total := v_loan_total + v_loan_fee;
      IF v_action -> 'released' IS NOT NULL AND jsonb_typeof(v_action -> 'released') = 'object' THEN
        v_releases := v_releases + 1;
      END IF;
    END IF;
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'hg', 'result', v_action));
  END LOOP;

  -- ===== 3) U21 竕･ 5 =====
  v_u21 := public.club_u21_count(v_club);
  v_short := greatest(v_min_u21 - v_u21, 0);
  v_u21_short := v_short;

  FOR v_i IN 1..v_short LOOP
    PERFORM public.competition_apply_club_fine_tariff(
      v_club, 'breach_squad_u21_min', v_fee,
      format('Below under-21 minimum at August (%s of %s missing)', v_i, v_short),
      NULL, v_season_id
    );
    v_fine_total := v_fine_total + v_fee;

    v_action := public.club_august_issue_loan(
      v_club, v_season_id, v_exclude, true, false, 'non_u21'
    );
    IF jsonb_typeof(v_action -> 'exclude') = 'array'
       AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
      SELECT array_agg(x ORDER BY ord)
      INTO v_exclude
      FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
    END IF;
    IF v_action ->> 'error' IS NOT NULL THEN
      v_errors := array_append(v_errors, v_action ->> 'error');
    END IF;
    IF coalesce((v_action ->> 'ok')::boolean, false) THEN
      v_loans := v_loans + 1;
      v_loan_total := v_loan_total + v_loan_fee;
      IF v_action -> 'released' IS NOT NULL AND jsonb_typeof(v_action -> 'released') = 'object' THEN
        v_releases := v_releases + 1;
      END IF;
    END IF;
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'u21', 'result', v_action));
  END LOOP;

  -- ===== 4) Stars 竕､ cap =====
  IF to_regprocedure('public.club_squad_star_cap(text)') IS NOT NULL THEN
    v_star_cap := public.club_squad_star_cap(v_club)::int;
  ELSE
    v_star_cap := CASE
      WHEN public.competition_club_division_tier(v_club) = 'superleague' THEN 3
      ELSE 2
    END;
  END IF;

  v_stars := public.club_star_count_for_cap(v_club);
  v_star_over := greatest(v_stars - v_star_cap, 0);

  FOR v_i IN 1..v_star_over LOOP
    v_count := public.club_registered_squad_count(v_club);

    IF v_count <= public.squad_minimum_size() THEN
      v_action := public.club_august_issue_loan(
        v_club, v_season_id, v_exclude, false, false, 'any'
      );
      IF jsonb_typeof(v_action -> 'exclude') = 'array'
         AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
        SELECT array_agg(x ORDER BY ord)
        INTO v_exclude
        FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
      END IF;
      IF v_action ->> 'error' IS NOT NULL THEN
        v_errors := array_append(v_errors, v_action ->> 'error');
      END IF;
      IF coalesce((v_action ->> 'ok')::boolean, false) THEN
        v_loans := v_loans + 1;
        v_loan_total := v_loan_total + v_loan_fee;
        v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'star_preloan', 'result', v_action));
      ELSE
        v_errors := array_append(v_errors, 'Cannot release star 窶・squad at minimum and loan unavailable');
        v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'star_preloan', 'result', v_action));
        EXIT;
      END IF;
    END IF;

    v_pid := public.club_pick_august_release_player(v_club, 'star');
    IF v_pid IS NULL THEN
      v_errors := array_append(v_errors, 'No releasable star remaining');
      EXIT;
    END IF;

    BEGIN
      v_rel := public.club_august_release_player(
        v_club, v_pid, 1.0, 'august_star_compliance',
        'Market value (August star cap)'
      );
      v_releases := v_releases + 1;

      PERFORM public.competition_apply_club_fine_tariff(
        v_club, 'breach_squad_star_cap', v_fee,
        format('Star cap breach 窶・released %s (%s of %s)', coalesce(v_rel ->> 'player_name', v_pid), v_i, v_star_over),
        NULL, v_season_id
      );
      v_fine_total := v_fine_total + v_fee;

      v_actions := v_actions || jsonb_build_array(jsonb_build_object(
        'step', 'star_release',
        'result', v_rel
      ));
    EXCEPTION WHEN OTHERS THEN
      v_errors := array_append(v_errors, format('Star release failed %s: %s', v_pid, SQLERRM));
      EXIT;
    END;
  END LOOP;

  v_count := public.club_registered_squad_count(v_club);
  v_short := greatest(v_size_short + v_hg_short + v_u21_short + v_star_over, 0);

  IF v_short > 0 OR v_loans > 0 OR v_releases > 0 OR v_fine_total > 0 THEN
    INSERT INTO public.club_squad_minimum_enforcement (
      season_id, club_short_name, squad_count, shortfall,
      fine_per_player, loan_fee_per_player, total_fine, total_loan_fee,
      loans_granted, metadata
    )
    VALUES (
      v_season_id, v_club, v_count,
      greatest(v_short, 1),
      v_fee, v_loan_fee, v_fine_total, v_loan_total, v_loans,
      jsonb_build_object(
        'version', 2,
        'size_shortfall', v_size_short,
        'hg_shortfall', v_hg_short,
        'u21_shortfall', v_u21_short,
        'stars_over', v_star_over,
        'star_cap', v_star_cap,
        'releases', v_releases,
        'errors', to_jsonb(v_errors),
        'actions', v_actions
      )
    )
    ON CONFLICT (season_id, club_short_name) DO UPDATE
    SET
      squad_count = excluded.squad_count,
      shortfall = excluded.shortfall,
      fine_per_player = excluded.fine_per_player,
      loan_fee_per_player = excluded.loan_fee_per_player,
      total_fine = excluded.total_fine,
      total_loan_fee = excluded.total_loan_fee,
      loans_granted = excluded.loans_granted,
      metadata = excluded.metadata,
      enforced_at = now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'squad_count', v_count,
    'size_shortfall', v_size_short,
    'hg_shortfall', v_hg_short,
    'u21_shortfall', v_u21_short,
    'stars_over', v_star_over,
    'star_cap', v_star_cap,
    'fines_total', v_fine_total,
    'loans_granted', v_loans,
    'loan_fees_total', v_loan_total,
    'releases', v_releases,
    'errors', to_jsonb(v_errors),
    'enforced', v_short > 0
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_enforce_squad_minimum(text, bigint, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

