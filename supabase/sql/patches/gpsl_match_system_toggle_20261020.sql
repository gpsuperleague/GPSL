-- =============================================================================
-- GPSL match system ON/OFF (manual / Discord black-box arranging)
--
-- Default ON = regulated propose/reply/fines.
-- Both clubs OFF for a fixture half-season → black box until played;
-- still unplayed at that fixture's month lock → mutual forfeit (void, 0 pts),
-- ₿2.5m each; cups: both out, sibling winner gets a bye.
--
-- Windows: h1 Aug–Dec (set in July); h2 Jan–end (set in December; inherits h1
-- if unset). Missing preference = ON.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Preference table (per club, per season, per half)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.club_match_system_preference (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName"),
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  half text NOT NULL CHECK (half IN ('h1', 'h2')),
  gpsl_system_on boolean NOT NULL DEFAULT true,
  set_by_owner_id uuid,
  set_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT club_match_system_preference_uniq UNIQUE (club_short_name, season_id, half)
);

CREATE INDEX IF NOT EXISTS club_match_system_preference_season_idx
  ON public.club_match_system_preference (season_id, half);

ALTER TABLE public.club_match_system_preference ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_match_system_preference_select ON public.club_match_system_preference;
CREATE POLICY club_match_system_preference_select
  ON public.club_match_system_preference
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON public.club_match_system_preference TO authenticated;

-- Cup node flag: both sides eliminated (manual black-box month lock)
ALTER TABLE public.competition_cup_bracket_nodes
  ADD COLUMN IF NOT EXISTS both_eliminated boolean NOT NULL DEFAULT false;

-- Fine tariff
INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order
)
VALUES (
  'match_manual_mutual_forfeit',
  'Manual arrange — mutual forfeit',
  'scheduling',
  'fine',
  2500000,
  'fixed',
  265
)
ON CONFLICT (code) DO UPDATE SET
  label = EXCLUDED.label,
  amount = EXCLUDED.amount,
  is_active = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Month → half
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_month_match_system_half(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'august' THEN 'h1'
    WHEN 'september' THEN 'h1'
    WHEN 'october' THEN 'h1'
    WHEN 'november' THEN 'h1'
    WHEN 'december' THEN 'h1'
    WHEN 'january' THEN 'h2'
    WHEN 'february' THEN 'h2'
    WHEN 'march' THEN 'h2'
    WHEN 'april' THEN 'h2'
    WHEN 'may' THEN 'h2'
    WHEN 'playoffs' THEN 'h2'
    ELSE NULL
  END;
$fn$;

GRANT EXECUTE ON FUNCTION public.gpsl_month_match_system_half(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Effective GPSL-system-on for a club at a given GPSL month
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_gpsl_match_system_on(
  p_club text,
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_half text := public.gpsl_month_match_system_half(p_gpsl_month);
  v_on boolean;
BEGIN
  IF nullif(btrim(coalesce(p_club, '')), '') IS NULL OR p_season_id IS NULL THEN
    RETURN true;
  END IF;
  IF v_half IS NULL THEN
    RETURN true; -- preseason / unknown → safety net
  END IF;

  IF v_half = 'h2' THEN
    SELECT gpsl_system_on INTO v_on
    FROM public.club_match_system_preference
    WHERE club_short_name = p_club
      AND season_id = p_season_id
      AND half = 'h2';
    IF FOUND THEN
      RETURN coalesce(v_on, true);
    END IF;
  END IF;

  SELECT gpsl_system_on INTO v_on
  FROM public.club_match_system_preference
  WHERE club_short_name = p_club
    AND season_id = p_season_id
    AND half = 'h1';

  RETURN coalesce(v_on, true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_gpsl_match_system_on(text, bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.fixture_is_manual_black_box(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN false;
  END IF;
  IF public.competition_club_is_vacant(v_f.home_club_short_name)
     OR public.competition_club_is_vacant(v_f.away_club_short_name) THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.competition_club_is_fixture_inactive(text)') IS NOT NULL THEN
    IF public.competition_club_is_fixture_inactive(v_f.home_club_short_name)
       OR public.competition_club_is_fixture_inactive(v_f.away_club_short_name) THEN
      RETURN false;
    END IF;
  END IF;

  RETURN
    NOT public.club_gpsl_match_system_on(
      v_f.home_club_short_name, v_f.season_id, v_f.gpsl_month
    )
    AND NOT public.club_gpsl_match_system_on(
      v_f.away_club_short_name, v_f.season_id, v_f.gpsl_month
    );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_is_manual_black_box(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.fixtures_manual_black_box_map(p_fixture_ids bigint[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb := '{}'::jsonb;
  v_id bigint;
BEGIN
  IF p_fixture_ids IS NULL THEN
    RETURN v_out;
  END IF;
  FOREACH v_id IN ARRAY p_fixture_ids LOOP
    IF v_id IS NULL THEN
      CONTINUE;
    END IF;
    v_out := v_out || jsonb_build_object(v_id::text, public.fixture_is_manual_black_box(v_id));
  END LOOP;
  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixtures_manual_black_box_map(bigint[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- Owner status / set
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_match_system_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_season_id bigint;
  v_month text;
  v_half text;
  v_h1 boolean := true;
  v_h2 boolean;
  v_h2_set boolean := false;
  v_can_edit_h1 boolean := false;
  v_can_edit_h2 boolean := false;
  v_effective boolean := true;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season', 'club_short_name', v_club);
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_half := public.gpsl_month_match_system_half(v_month);

  SELECT gpsl_system_on INTO v_h1
  FROM public.club_match_system_preference
  WHERE club_short_name = v_club AND season_id = v_season_id AND half = 'h1';
  v_h1 := coalesce(v_h1, true);

  SELECT gpsl_system_on INTO v_h2
  FROM public.club_match_system_preference
  WHERE club_short_name = v_club AND season_id = v_season_id AND half = 'h2';
  IF FOUND THEN
    v_h2_set := true;
  ELSE
    v_h2 := v_h1;
  END IF;

  -- July (or preseason / null month before August): edit h1
  IF v_month IS NULL
     OR lower(v_month) IN ('june', 'july')
     OR public.competition_gpsl_month_is_preseason(v_month) THEN
    v_can_edit_h1 := true;
  END IF;
  -- December: edit h2 for Jan onward
  IF lower(coalesce(v_month, '')) = 'december' THEN
    v_can_edit_h2 := true;
  END IF;

  IF v_half = 'h2' THEN
    v_effective := CASE WHEN v_h2_set THEN v_h2 ELSE v_h1 END;
  ELSE
    v_effective := v_h1;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'season_id', v_season_id,
    'active_gpsl_month', v_month,
    'active_half', v_half,
    'h1_gpsl_system_on', v_h1,
    'h2_gpsl_system_on', v_h2,
    'h2_explicitly_set', v_h2_set,
    'effective_gpsl_system_on', v_effective,
    'can_edit_h1', v_can_edit_h1,
    'can_edit_h2', v_can_edit_h2,
    'editable_half', CASE
      WHEN v_can_edit_h1 THEN 'h1'
      WHEN v_can_edit_h2 THEN 'h2'
      ELSE NULL
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_match_system_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.owner_match_system_set(
  p_gpsl_system_on boolean,
  p_half text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_season_id bigint;
  v_status jsonb;
  v_half text;
  v_on boolean := coalesce(p_gpsl_system_on, true);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  v_status := public.owner_match_system_status();
  IF coalesce((v_status->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION '%', coalesce(v_status->>'reason', 'Cannot set match system preference');
  END IF;

  v_club := v_status->>'club_short_name';
  v_season_id := (v_status->>'season_id')::bigint;
  v_half := lower(btrim(coalesce(p_half, v_status->>'editable_half', '')));

  IF v_half NOT IN ('h1', 'h2') THEN
    RAISE EXCEPTION 'Match system preference can only be changed in July (Aug–Dec) or December (Jan onward)';
  END IF;

  IF v_half = 'h1' AND coalesce((v_status->>'can_edit_h1')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Aug–Dec preference is locked until next July window';
  END IF;
  IF v_half = 'h2' AND coalesce((v_status->>'can_edit_h2')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Jan–end preference can only be changed in December';
  END IF;

  INSERT INTO public.club_match_system_preference AS p (
    club_short_name, season_id, half, gpsl_system_on, set_by_owner_id, set_at, updated_at
  )
  VALUES (v_club, v_season_id, v_half, v_on, v_uid, now(), now())
  ON CONFLICT (club_short_name, season_id, half) DO UPDATE SET
    gpsl_system_on = EXCLUDED.gpsl_system_on,
    set_by_owner_id = EXCLUDED.set_by_owner_id,
    set_at = now(),
    updated_at = now();

  RETURN public.owner_match_system_status() || jsonb_build_object('saved_half', v_half, 'saved_on', v_on);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_match_system_set(boolean, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Cup: after a feeder is both_eliminated, sibling winner gets a bye
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_cup_try_bye_after_mutual_elim(p_node_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node public.competition_cup_bracket_nodes%ROWTYPE;
  v_sib public.competition_cup_bracket_nodes%ROWTYPE;
  v_child public.competition_cup_bracket_nodes%ROWTYPE;
  v_winner text;
  v_fx_id bigint;
BEGIN
  SELECT * INTO v_node FROM public.competition_cup_bracket_nodes WHERE id = p_node_id;
  IF NOT FOUND OR v_node.child_node_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_child FROM public.competition_cup_bracket_nodes WHERE id = v_node.child_node_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Sibling feeding same child
  SELECT * INTO v_sib
  FROM public.competition_cup_bracket_nodes
  WHERE child_node_id = v_node.child_node_id
    AND id <> v_node.id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Need one eliminated feeder and one winner
  IF coalesce(v_node.both_eliminated, false) AND v_sib.winner_club_short_name IS NOT NULL THEN
    v_winner := v_sib.winner_club_short_name;
  ELSIF coalesce(v_sib.both_eliminated, false) AND v_node.winner_club_short_name IS NOT NULL THEN
    v_winner := v_node.winner_club_short_name;
  ELSE
    RETURN;
  END IF;

  -- Cancel any half-built child fixture
  v_fx_id := v_child.fixture_id;
  IF v_fx_id IS NOT NULL THEN
    UPDATE public.competition_fixtures
    SET status = 'cancelled'
    WHERE id = v_fx_id AND status = 'scheduled';
  END IF;

  UPDATE public.competition_cup_bracket_nodes
  SET home_club_short_name = v_winner,
      away_club_short_name = NULL,
      fixture_id = NULL,
      winner_club_short_name = v_winner,
      both_eliminated = false
  WHERE id = v_child.id;

  PERFORM public.competition_cup_advance_node_winner(v_child.id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Mutual forfeit writer
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fixture_apply_manual_mutual_forfeit(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
  v_node public.competition_cup_bracket_nodes%ROWTYPE;
  v_title text;
  v_body text;
  v_club text;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id FOR UPDATE;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_scheduled');
  END IF;

  IF NOT public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_black_box');
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by manual-arrange mutual forfeit',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixtures
  SET status = 'played',
      is_void = true,
      home_goals = NULL,
      away_goals = NULL,
      is_forfeit = false,
      forfeit_loser_club = NULL
  WHERE id = p_fixture_id;

  -- Fines both clubs
  FOREACH v_club IN ARRAY ARRAY[v_f.home_club_short_name, v_f.away_club_short_name] LOOP
    BEGIN
      PERFORM public.competition_apply_club_fine_tariff(
        v_club,
        'match_manual_mutual_forfeit',
        NULL,
        format('Manual arrange mutual forfeit — %s', coalesce(v_f.gpsl_month, 'fixture')),
        p_fixture_id,
        v_f.season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    BEGIN
      v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Mutual forfeit');
      v_body := public.competition_fixture_inbox_body(
        p_fixture_id,
        E'Both clubs had GPSL match arranging switched OFF. The fixture was still unplayed at month lock.\n\n'
        || E'Result: mutual forfeit (0 points each — not a draw). Fine: ₿2.5m each.'
      );
      PERFORM public.owner_inbox_send(
        'match_forfeit_applied', v_title, v_body,
        v_club, NULL, p_fixture_id,
        NULL, NULL, NULL,
        'fixtures.html',
        'manual_mutual_forfeit:' || p_fixture_id::text,
        v_f.gpsl_month, v_f.season_id, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  IF v_f.competition_type = 'cup' THEN
    SELECT * INTO v_node
    FROM public.competition_cup_bracket_nodes
    WHERE fixture_id = p_fixture_id
    LIMIT 1;

    IF FOUND THEN
      UPDATE public.competition_cup_bracket_nodes
      SET winner_club_short_name = NULL,
          both_eliminated = true
      WHERE id = v_node.id;

      PERFORM public.competition_cup_try_bye_after_mutual_elim(v_node.id);
    END IF;
  ELSIF v_f.competition_type = 'league' THEN
    BEGIN
      PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'fixture_id', p_fixture_id, 'result', 'mutual_forfeit');
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_apply_manual_mutual_forfeit(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_apply_manual_mutual_forfeit(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Month-lock processor (one job per locked month)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_enforce_manual_black_box_forfeits(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f record;
  v_res jsonb;
  v_n int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  FOR v_f IN
    SELECT f.id
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
      AND lower(btrim(coalesce(f.gpsl_month, ''))) = lower(btrim(coalesce(p_closed_gpsl_month, '')))
      AND public.fixture_is_manual_black_box(f.id)
  LOOP
    v_res := public.fixture_apply_manual_mutual_forfeit(v_f.id);
    IF coalesce((v_res->>'ok')::boolean, false) THEN
      v_n := v_n + 1;
      v_details := v_details || jsonb_build_array(v_res);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'applied', v_n,
    'details', v_details
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_process_manual_black_box_forfeits(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_job_key text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF p_season_id IS NULL THEN
    SELECT id INTO p_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'manual_black_box_forfeits:' || v_cal.gpsl_month;
    IF EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_res := public.competition_enforce_manual_black_box_forfeits(p_season_id, v_cal.gpsl_month);

    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (p_season_id, v_job_key, v_cal.gpsl_month, coalesce(v_res, '{}'::jsonb))
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object('gpsl_month', v_cal.gpsl_month, 'result', v_res)
    );
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'processed', v_results);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_manual_black_box_forfeits(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_manual_black_box_forfeits(bigint) TO service_role;

-- Run black-box forfeits BEFORE arrangement fines (so those fixtures are already played)
CREATE OR REPLACE FUNCTION public.competition_process_scheduling_arrangement_fines(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_job_key text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
  v_bb jsonb;
BEGIN
  -- Manual black-box mutual forfeits first
  BEGIN
    v_bb := public.competition_process_manual_black_box_forfeits(p_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_bb := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = p_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar', 'manual_black_box', v_bb);
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month, c.lock_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'scheduling_arrangement_fines:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_res := public.competition_enforce_scheduling_arrangement_fines(
      p_season_id,
      v_cal.gpsl_month
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      v_job_key,
      v_cal.gpsl_month,
      coalesce(v_res, '{}'::jsonb)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_cal.gpsl_month,
        'result', v_res
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'processed', v_results,
    'manual_black_box', v_bb
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Patch cup advance: after placing a winner, try bye if sibling eliminated
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_cup_advance_node_winner(p_node_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node public.competition_cup_bracket_nodes;
  v_child public.competition_cup_bracket_nodes;
  v_winner text;
BEGIN
  SELECT * INTO v_node FROM public.competition_cup_bracket_nodes WHERE id = p_node_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_winner := v_node.winner_club_short_name;
  IF v_winner IS NULL OR v_node.child_node_id IS NULL OR v_node.child_slot IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_child FROM public.competition_cup_bracket_nodes WHERE id = v_node.child_node_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_node.child_slot = 'home' THEN
    UPDATE public.competition_cup_bracket_nodes
    SET home_club_short_name = v_winner
    WHERE id = v_child.id
      AND home_club_short_name IS DISTINCT FROM v_winner;
  ELSE
    UPDATE public.competition_cup_bracket_nodes
    SET away_club_short_name = v_winner
    WHERE id = v_child.id
      AND away_club_short_name IS DISTINCT FROM v_winner;
  END IF;

  -- If the other feeder was mutual-elim, this winner gets a bye onward
  PERFORM public.competition_cup_try_bye_after_mutual_elim(p_node_id);

  SELECT * INTO v_child FROM public.competition_cup_bracket_nodes WHERE id = v_node.child_node_id;

  IF v_child.home_club_short_name IS NOT NULL AND v_child.away_club_short_name IS NOT NULL THEN
    PERFORM public.competition_create_cup_fixture_for_node(v_child.id);
  END IF;
END;
$function$;

NOTIFY pgrst, 'reload schema';
