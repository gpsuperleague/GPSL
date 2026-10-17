-- =============================================================================
-- Club season absence (finance freeze) — 2026-10-17
--
-- Owned club stays attached. League + cup fixtures awarded like vacant walkovers.
-- Finances frozen; loans paused; manager released for MV into club balance at start.
-- Market locked except FFP force-sell (only relevant if already ≤ −100m at freeze).
-- Expectations soft punishment suppressed; rock-bottom forced TR still issues.
-- Eligibility: 1 season in 4 (game season number from club_loan_game_season_number).
-- Early return unfreezes remaining fixtures.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.club_season_absences (
  id bigserial PRIMARY KEY,
  owner_id uuid NOT NULL,
  club_short_name text NOT NULL,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  game_season_number int NOT NULL,
  status text NOT NULL
    CHECK (status IN ('requested', 'active', 'completed', 'rejected', 'cancelled')),
  note text,
  requested_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz,
  returned_at timestamptz,
  decided_at timestamptz,
  decided_by uuid,
  manager_release jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (club_short_name, season_id),
  UNIQUE (owner_id, season_id)
);

CREATE INDEX IF NOT EXISTS club_season_absences_status_idx
  ON public.club_season_absences (status, season_id);

CREATE INDEX IF NOT EXISTS club_season_absences_club_idx
  ON public.club_season_absences (club_short_name, status);

COMMENT ON TABLE public.club_season_absences IS
  'Season absence / finance freeze. Club stays owned; fixtures walkover; money/loans frozen.';

ALTER TABLE public.club_season_absences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_season_absences_select_auth ON public.club_season_absences;
CREATE POLICY club_season_absences_select_auth
  ON public.club_season_absences
  FOR SELECT TO authenticated
  USING (true);

-- ---------------------------------------------------------------------------
-- 2) Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_is_season_absent(
  p_club text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_season_id bigint := p_season_id;
  v_club text := upper(btrim(coalesce(p_club, '')));
BEGIN
  IF v_club = '' THEN
    RETURN false;
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.club_season_absences a
    WHERE a.club_short_name = v_club
      AND a.season_id = v_season_id
      AND a.status = 'active'
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.club_is_season_absent(text, bigint) TO authenticated, anon, service_role;

CREATE OR REPLACE FUNCTION public.competition_club_is_fixture_inactive(
  p_club text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.competition_club_is_vacant(p_club)
      OR public.club_is_season_absent(p_club, p_season_id);
$$;

GRANT EXECUTE ON FUNCTION public.competition_club_is_fixture_inactive(text, bigint)
  TO authenticated, anon, service_role;

CREATE OR REPLACE FUNCTION public.owner_season_absence_eligible(
  p_owner_id uuid DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_owner uuid := coalesce(p_owner_id, auth.uid());
  v_season_id bigint := p_season_id;
  v_num int;
  v_from int;
  v_used int := 0;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'eligible', false, 'reason', 'no_owner');
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'eligible', false, 'reason', 'no_season');
  END IF;

  v_num := public.club_loan_game_season_number(v_season_id);
  IF v_num IS NULL OR v_num < 1 THEN
    RETURN jsonb_build_object('ok', false, 'eligible', false, 'reason', 'bad_season_number');
  END IF;

  v_from := greatest(v_num - 3, 1);

  SELECT count(*)::int INTO v_used
  FROM public.club_season_absences a
  WHERE a.owner_id = v_owner
    AND a.game_season_number BETWEEN v_from AND v_num
    AND a.status IN ('requested', 'active', 'completed');

  RETURN jsonb_build_object(
    'ok', true,
    'eligible', v_used < 1,
    'used_in_window', v_used,
    'window_from', v_from,
    'window_to', v_num,
    'season_id', v_season_id,
    'game_season_number', v_num,
    'rule', '1 season in 4'
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.owner_season_absence_eligible(uuid, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.club_season_absence_assert_market_open(
  p_club text,
  p_season_id bigint DEFAULT NULL,
  p_allow_ffp boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF public.club_is_season_absent(p_club, p_season_id) AND NOT coalesce(p_allow_ffp, false) THEN
    RAISE EXCEPTION
      'Club is on season absence — no signings, sales, or releases (FFP force-sell excepted).';
  END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.club_season_absence_assert_market_open(text, bigint, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_season_absence_assert_market_open(text, bigint, boolean)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3) Activate / return / request / admin list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_season_absence_activate_internal(
  p_club text,
  p_owner_id uuid,
  p_season_id bigint,
  p_note text DEFAULT NULL,
  p_decided_by uuid DEFAULT NULL,
  p_existing_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_club text := upper(btrim(p_club));
  v_num int;
  v_elig jsonb;
  v_mgr_id bigint;
  v_mgr_rel jsonb := NULL;
  v_id bigint;
  v_bal numeric;
BEGIN
  IF v_club = '' OR p_owner_id IS NULL OR p_season_id IS NULL THEN
    RAISE EXCEPTION 'club, owner and season required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_club AND c.owner_id = p_owner_id
  ) THEN
    RAISE EXCEPTION 'Owner is not linked to that club';
  END IF;

  IF public.club_is_season_absent(v_club, p_season_id) THEN
    RAISE EXCEPTION 'Club is already on season absence';
  END IF;

  v_elig := public.owner_season_absence_eligible(p_owner_id, p_season_id);
  IF NOT coalesce((v_elig->>'eligible')::boolean, false) THEN
    -- Allow activating an existing requested row for this season even if window counts it
    IF p_existing_id IS NULL THEN
      RAISE EXCEPTION 'Not eligible for season absence (1 season in 4). %', v_elig::text;
    END IF;
  END IF;

  v_num := public.club_loan_game_season_number(p_season_id);

  -- Release manager for full MV into club balance (before freeze ticks)
  SELECT m.id INTO v_mgr_id
  FROM public."Managers" m
  WHERE m.contracted_club = v_club
  LIMIT 1;

  IF v_mgr_id IS NULL THEN
    SELECT c.manager_id INTO v_mgr_id
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;
  END IF;

  IF v_mgr_id IS NOT NULL THEN
    BEGIN
      v_mgr_rel := public.manager_release_from_club(
        v_mgr_id,
        v_club,
        NULL,
        'transfer_sale',
        format('Season absence — manager released (%s)', v_club),
        jsonb_build_object(
          'season_absence', true,
          'season_id', p_season_id,
          'source', 'club_season_absence_activate'
        )
      );
    EXCEPTION WHEN OTHERS THEN
      v_mgr_rel := jsonb_build_object('ok', false, 'error', SQLERRM, 'manager_id', v_mgr_id);
    END;
  END IF;

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  IF p_existing_id IS NOT NULL THEN
    UPDATE public.club_season_absences
    SET status = 'active',
        note = coalesce(nullif(btrim(p_note), ''), note),
        activated_at = now(),
        decided_at = now(),
        decided_by = p_decided_by,
        manager_release = v_mgr_rel,
        updated_at = now()
    WHERE id = p_existing_id
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.club_season_absences (
      owner_id, club_short_name, season_id, game_season_number,
      status, note, activated_at, decided_at, decided_by, manager_release
    ) VALUES (
      p_owner_id, v_club, p_season_id, v_num,
      'active', nullif(btrim(p_note), ''), now(), now(), p_decided_by, v_mgr_rel
    )
    ON CONFLICT (club_short_name, season_id) DO UPDATE
      SET status = 'active',
          owner_id = excluded.owner_id,
          game_season_number = excluded.game_season_number,
          note = coalesce(excluded.note, club_season_absences.note),
          activated_at = now(),
          decided_at = now(),
          decided_by = excluded.decided_by,
          manager_release = excluded.manager_release,
          returned_at = NULL,
          updated_at = now()
    RETURNING id INTO v_id;
  END IF;

  BEGIN
    PERFORM public.owner_inbox_send(
      p_message_type => 'season_overview',
      p_title => 'Season absence active',
      p_body => format(
        'Your club %s is on season absence. Fixtures are awarded to opponents; finances and loans are frozen; the manager was released for market value into the club balance. You can return early to unfreeze remaining fixtures.',
        v_club
      ),
      p_recipient_club => v_club,
      p_action_href => 'owner_details.html',
      p_dedupe_key => format('season_absence_active:%s:%s', v_club, p_season_id),
      p_season_id => p_season_id
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_id,
    'club', v_club,
    'season_id', p_season_id,
    'game_season_number', v_num,
    'balance_at_activate', v_bal,
    'ffp_at_risk', coalesce(v_bal, 0) <= -100000000,
    'manager_release', v_mgr_rel
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.club_season_absence_activate_internal(text, uuid, bigint, text, uuid, bigint)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_club_season_absence_activate(
  p_club_short_name text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_owner uuid;
  v_season_id bigint;
  v_req_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Club has no owner — use vacant flow, not season absence';
  END IF;

  SELECT a.id INTO v_req_id
  FROM public.club_season_absences a
  WHERE a.club_short_name = v_club
    AND a.season_id = v_season_id
    AND a.status = 'requested'
  LIMIT 1;

  RETURN public.club_season_absence_activate_internal(
    v_club, v_owner, v_season_id, p_note, auth.uid(), v_req_id
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_club_season_absence_activate(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.owner_club_season_absence_request(p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_owner uuid := auth.uid();
  v_club text;
  v_season_id bigint;
  v_num int;
  v_elig jsonb;
  v_id bigint;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE c.owner_id = v_owner
  LIMIT 1;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  IF public.club_is_season_absent(v_club, v_season_id) THEN
    RAISE EXCEPTION 'Already on season absence';
  END IF;

  v_elig := public.owner_season_absence_eligible(v_owner, v_season_id);
  IF NOT coalesce((v_elig->>'eligible')::boolean, false) THEN
    RAISE EXCEPTION 'Not eligible (1 season in 4)';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_season_absences a
    WHERE a.club_short_name = v_club AND a.season_id = v_season_id
      AND a.status = 'requested'
  ) THEN
    RAISE EXCEPTION 'Request already pending admin approval';
  END IF;

  v_num := public.club_loan_game_season_number(v_season_id);

  INSERT INTO public.club_season_absences (
    owner_id, club_short_name, season_id, game_season_number, status, note
  ) VALUES (
    v_owner, v_club, v_season_id, v_num, 'requested', nullif(btrim(p_note), '')
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'status', 'requested', 'club', v_club);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.owner_club_season_absence_request(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_club_season_absence_reject(
  p_id bigint,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.club_season_absences
  SET status = 'rejected',
      note = coalesce(nullif(btrim(p_note), ''), note),
      decided_at = now(),
      decided_by = auth.uid(),
      updated_at = now()
  WHERE id = p_id AND status = 'requested';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No pending request for that id';
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id, 'status', 'rejected');
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_club_season_absence_reject(bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.club_season_absence_return(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_season_id bigint;
  v_row public.club_season_absences%ROWTYPE;
  v_is_admin boolean := public.is_gpsl_admin();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF p_club_short_name IS NOT NULL AND btrim(p_club_short_name) <> '' THEN
    v_club := upper(btrim(p_club_short_name));
  ELSE
    SELECT c."ShortName" INTO v_club
    FROM public."Clubs" c
    WHERE c.owner_id = v_uid
    LIMIT 1;
  END IF;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  SELECT * INTO v_row
  FROM public.club_season_absences a
  WHERE a.club_short_name = v_club
    AND a.season_id = v_season_id
    AND a.status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active season absence for %', v_club;
  END IF;

  IF NOT v_is_admin AND v_row.owner_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'Not your club';
  END IF;

  UPDATE public.club_season_absences
  SET status = 'completed',
      returned_at = now(),
      updated_at = now()
  WHERE id = v_row.id;

  BEGIN
    PERFORM public.owner_inbox_send(
      p_message_type => 'season_overview',
      p_title => 'Season absence ended',
      p_body => format(
        'Season absence for %s has ended. Remaining fixtures are live again; awarded results stand. Finances and loans are unfrozen from this point (no catch-up for skipped months).',
        v_club
      ),
      p_recipient_club => v_club,
      p_action_href => 'club_fixtures.html',
      p_dedupe_key => format('season_absence_return:%s:%s:%s', v_club, v_season_id, v_row.id),
      p_season_id => v_season_id
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_row.id,
    'club', v_club,
    'status', 'completed',
    'returned_at', now()
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.club_season_absence_return(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_club_season_absence_list(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_season_id bigint := p_season_id;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.status, x.club_short_name)
    FROM (
      SELECT
        a.*,
        c."Club" AS club_name,
        c.owner AS owner_tag,
        f.balance AS club_balance
      FROM public.club_season_absences a
      LEFT JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
      LEFT JOIN public."Club_Finances" f ON f.club_name = a.club_short_name
      WHERE a.season_id = v_season_id
    ) x
  ), '[]'::jsonb);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_club_season_absence_list(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.owner_club_season_absence_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_owner uuid := auth.uid();
  v_club text;
  v_season_id bigint;
  v_row jsonb;
  v_elig jsonb;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_signed_in');
  END IF;

  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE c.owner_id = v_owner
  LIMIT 1;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_elig := public.owner_season_absence_eligible(v_owner, v_season_id);

  SELECT to_jsonb(a) INTO v_row
  FROM public.club_season_absences a
  WHERE a.owner_id = v_owner
    AND a.season_id = v_season_id
    AND a.status IN ('requested', 'active')
  ORDER BY CASE a.status WHEN 'active' THEN 0 ELSE 1 END
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'season_id', v_season_id,
    'eligibility', v_elig,
    'current', v_row
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.owner_club_season_absence_status() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) Fixtures: treat season-absent like vacant for walkovers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_fixture_involves_vacant_club(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((
    SELECT f.competition_type IN ('league', 'cup')
       AND (
         public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
         OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
       )
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
  ), false);
$$;

GRANT EXECUTE ON FUNCTION public.competition_fixture_involves_vacant_club(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_apply_vacant_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_home_inactive boolean;
  v_away_inactive boolean;
  v_loser text;
  v_winner text;
  v_low text;
  v_high text;
  v_title text;
  v_body text;
  v_loser_label text;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled'
     OR v_f.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'not_applicable');
  END IF;

  v_home_inactive := public.competition_club_is_fixture_inactive(v_f.home_club_short_name, v_f.season_id);
  v_away_inactive := public.competition_club_is_fixture_inactive(v_f.away_club_short_name, v_f.season_id);

  IF NOT v_home_inactive AND NOT v_away_inactive THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'both_active');
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by vacant/absence walkover',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  IF v_home_inactive AND v_away_inactive AND v_f.competition_type = 'league' THEN
    UPDATE public.competition_fixtures
    SET status = 'played',
        is_void = true,
        home_goals = NULL,
        away_goals = NULL
    WHERE id = p_fixture_id;

    PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);

    RETURN jsonb_build_object('ok', true, 'fixture_id', p_fixture_id, 'result', 'void');
  END IF;

  IF v_home_inactive AND v_away_inactive THEN
    v_low := least(v_f.home_club_short_name, v_f.away_club_short_name);
    v_high := greatest(v_f.home_club_short_name, v_f.away_club_short_name);
    v_loser := CASE
      WHEN substr(md5(concat_ws(':', v_f.season_id, v_f.cup_code, v_low, v_high)), 1, 1) < '8'
      THEN v_low ELSE v_high
    END;
  ELSIF v_home_inactive THEN
    v_loser := v_f.home_club_short_name;
  ELSE
    v_loser := v_f.away_club_short_name;
  END IF;

  v_winner := CASE
    WHEN v_loser = v_f.home_club_short_name THEN v_f.away_club_short_name
    ELSE v_f.home_club_short_name
  END;

  UPDATE public.competition_fixtures
  SET home_goals = CASE WHEN v_winner = v_f.home_club_short_name THEN 3 ELSE 0 END,
      away_goals = CASE WHEN v_winner = v_f.away_club_short_name THEN 3 ELSE 0 END,
      status = 'played',
      is_forfeit = true,
      forfeit_loser_club = v_loser
  WHERE id = p_fixture_id;

  -- Skip gate/TV money when either side is on season absence (finances frozen)
  IF NOT public.club_is_season_absent(v_f.home_club_short_name, v_f.season_id)
     AND NOT public.club_is_season_absent(v_f.away_club_short_name, v_f.season_id) THEN
    BEGIN
      PERFORM public.competition_settle_fixture_gates(p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    IF to_regprocedure('public.competition_tv_settle_fixture(bigint)') IS NOT NULL THEN
      BEGIN
        PERFORM public.competition_tv_settle_fixture(p_fixture_id);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  END IF;

  IF v_f.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  ELSE
    PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);
  END IF;

  -- Notify active (playing) winner only — not vacant, not season-absent
  IF NOT public.competition_club_is_fixture_inactive(v_winner, v_f.season_id) THEN
    BEGIN
      v_loser_label := CASE
        WHEN public.club_is_season_absent(v_loser, v_f.season_id)
          THEN format('%s is on season absence', public.club_display_name(v_loser))
        ELSE format('%s has no owner', public.club_display_name(v_loser))
      END;
      v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Walkover win');
      v_body := public.competition_fixture_inbox_body(
        p_fixture_id,
        format('%s, so you win 3–0 by walkover.', v_loser_label)
      );
      PERFORM public.owner_inbox_send(
        'match_forfeit_applied', v_title, v_body,
        v_winner, NULL, p_fixture_id,
        NULL, NULL, NULL,
        'fixture_schedule.html?fixture=' || p_fixture_id::text,
        'vacant_walkover:' || p_fixture_id::text,
        v_f.gpsl_month, v_f.season_id, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'fixture_id', p_fixture_id, 'result', 'walkover',
    'winner', v_winner, 'loser', v_loser
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_apply_vacant_fixture_result(bigint)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.competition_process_vacant_walkovers(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_cal record;
  v_fx record;
  v_job_key text;
  v_month_sort smallint;
  v_res jsonb;
  v_month_results jsonb;
  v_walkovers int;
  v_voids int;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'vacant_walkovers:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season_id AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_month_sort := public.competition_gpsl_month_sort(v_cal.gpsl_month);
    v_month_results := '[]'::jsonb;
    v_walkovers := 0;
    v_voids := 0;

    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND f.gpsl_month IS NOT NULL
        AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_month_sort
        AND (
          public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
          OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
        )
      ORDER BY public.competition_gpsl_month_sort(f.gpsl_month), f.matchday NULLS LAST, f.id
    LOOP
      v_res := public.competition_apply_vacant_fixture_result(v_fx.id);
      IF coalesce((v_res->>'ok')::boolean, false) THEN
        IF v_res->>'result' = 'void' THEN
          v_voids := v_voids + 1;
        ELSE
          v_walkovers := v_walkovers + 1;
        END IF;
        v_month_results := v_month_results || jsonb_build_array(v_res);
      END IF;
    END LOOP;

    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (
      v_season_id, v_job_key, v_cal.gpsl_month,
      jsonb_build_object('ok', true, 'walkovers', v_walkovers, 'voids', v_voids, 'fixtures', v_month_results)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'gpsl_month', v_cal.gpsl_month, 'walkovers', v_walkovers, 'voids', v_voids
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season_id, 'processed', v_out);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_vacant_walkovers(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_vacant_walkovers(bigint) TO service_role;

-- Refresh assert message (vacant OR absence)
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'competition_assert_fixture_month_unlocked'
      AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('season absence' IN lower(v_def)) > 0 THEN
      CONTINUE;
    END IF;
    IF position('competition_fixture_involves_vacant_club' IN v_def) > 0 THEN
      v_new := replace(
        v_def,
        'This fixture involves a club with no owner. It is settled automatically when the GPSL month ends (3–0 walkover, or void if both clubs have no owner).',
        'This fixture involves a vacant club or a club on season absence. It is settled automatically when the GPSL month ends (3–0 walkover, or void if both sides are inactive).'
      );
      IF v_new IS DISTINCT FROM v_def THEN
        EXECUTE v_new;
      END IF;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 5) Finance / loan / owner-wallet skips (soft inject)
-- ---------------------------------------------------------------------------

-- Wage / upkeep lines (replace with absence skip)
CREATE OR REPLACE FUNCTION public.competition_post_club_season_upkeep(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int := 0;
BEGIN
  IF public.club_is_season_absent(p_club_short_name, p_season_id) THEN
    RETURN 0;
  END IF;

  IF public.competition_post_club_wage_bill(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  IF to_regprocedure('public.competition_post_club_manager_salary(bigint,text)') IS NOT NULL THEN
    IF public.competition_post_club_manager_salary(p_season_id, p_club_short_name) THEN
      v_n := v_n + 1;
    END IF;
  END IF;
  IF public.competition_post_club_34plus_tax(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  IF public.competition_post_club_star_tax(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  RETURN v_n;
END;
$function$;

-- Loans: pause repayments
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'club_loan_process_due_for_club' AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('club_is_season_absent' IN v_def) > 0 THEN CONTINUE; END IF;
    v_new := regexp_replace(
      v_def,
      E'\\nBEGIN\\n',
      E'\nBEGIN\n'
      || E'  IF public.club_is_season_absent(p_club, NULL) THEN\n'
      || E'    RETURN jsonb_build_object(''club'', btrim(p_club), ''processed'', 0, ''total_paid'', 0,\n'
      || E'      ''skipped_insufficient'', 0, ''errors'', 0, ''reason'', ''season_absence'');\n'
      || E'  END IF;\n',
      1,
      1
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      RAISE NOTICE 'Season-absence loan pause added to %', v_oid::regprocedure;
    END IF;
  END LOOP;
END $$;

-- Monthly interest: skip absent clubs in loop
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'competition_post_monthly_interest' AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('club_is_season_absent' IN v_def) > 0 THEN CONTINUE; END IF;
    v_new := replace(
      v_def,
      'LOOP\n    IF r.balance > 0 THEN',
      E'LOOP\n    IF public.club_is_season_absent(r.club, p_season_id) THEN\n      CONTINUE;\n    END IF;\n    IF r.balance > 0 THEN'
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      RAISE NOTICE 'Season-absence interest skip added';
    ELSE
      RAISE WARNING 'Could not inject interest skip';
    END IF;
  END LOOP;
END $$;

-- Owner salary
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'owner_season_salary_pay' AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('club_is_season_absent' IN v_def) > 0 THEN CONTINUE; END IF;
    v_new := regexp_replace(
      v_def,
      E'\\nBEGIN\\n',
      E'\nBEGIN\n'
      || E'  IF public.club_is_season_absent(p_club_short_name, p_season_id) THEN\n'
      || E'    RETURN jsonb_build_object(''paid'', false, ''reason'', ''season_absence'');\n'
      || E'  END IF;\n',
      1,
      1
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
    END IF;
  END LOOP;
END $$;

-- Board fine (personal)
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'board_fine_owner_personal_pct' AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('club_is_season_absent' IN v_def) > 0 THEN CONTINUE; END IF;
    v_new := regexp_replace(
      v_def,
      E'\\nBEGIN\\n',
      E'\nBEGIN\n'
      || E'  IF public.club_is_season_absent(p_club_short_name, p_season_id) THEN\n'
      || E'    RETURN 0;\n'
      || E'  END IF;\n',
      1,
      1
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
    END IF;
  END LOOP;
END $$;

-- Friendlies prizes: skip absent clubs (and bump next place still from ordered set —
-- simplest: skip posting for that row)
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'gpsl_friendlies_pay_month_prizes_internal'
      AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('club_is_season_absent' IN v_def) > 0 THEN CONTINUE; END IF;
    v_new := replace(
      v_def,
      'v_place := v_place + 1;\n    EXIT WHEN v_place > coalesce(array_length(v_prizes, 1), 0);',
      E'v_place := v_place + 1;\n    EXIT WHEN v_place > coalesce(array_length(v_prizes, 1), 0);\n\n'
      || E'    IF public.club_is_season_absent(r.club, p_season_id) THEN\n'
      || E'      v_skipped := v_skipped + 1;\n'
      || E'      CONTINUE;\n'
      || E'    END IF;'
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
    ELSE
      RAISE WARNING 'Could not inject friendlies prize skip';
    END IF;
  END LOOP;
END $$;

-- Stadium maintenance: skip absent in infra loop if function iterates clubs
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'competition_post_infra_maintenance' AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('club_is_season_absent' IN v_def) > 0 THEN CONTINUE; END IF;
    -- Common pattern: FOR v_club IN SELECT ... LOOP
    v_new := regexp_replace(
      v_def,
      E'(FOR\\s+v_club\\s+IN[\\s\\S]*?LOOP\\n)',
      E'\\1  IF public.club_is_season_absent(v_club, p_season_id) THEN CONTINUE; END IF;\n',
      1,
      1
    );
    IF v_new IS DISTINCT FROM v_def AND position('club_is_season_absent' IN v_new) > 0 THEN
      EXECUTE v_new;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 6) Underperformance: keep forced TR, skip when on_target already; fine already
--    skipped via board_fine inject. Still create listing for rock-bottom.
--    Also skip stadium-fill soft punishment paths if present in process_club —
--    fine is the main soft path; TR remains.
-- ---------------------------------------------------------------------------
-- (board_fine inject covers personal fine; TR creation unchanged)

-- ---------------------------------------------------------------------------
-- 7) Market lock trigger on Player_Transfer_Listings
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_club_season_absence_block_listing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_club text := upper(btrim(coalesce(NEW.seller_club_id, '')));
  v_allow boolean := false;
  v_src text := lower(coalesce(NEW.special_rules ->> 'source', ''));
  v_guc text := lower(coalesce(current_setting('gpsl.force_listing_reason', true), ''));
BEGIN
  IF v_club = '' THEN
    RETURN NEW;
  END IF;

  IF v_src IN ('underperformance', 'ffp', 'ffp_force', 'season_absence_ffp')
     OR v_guc IN ('ffp', 'underperformance', 'force')
  THEN
    v_allow := true;
  END IF;

  PERFORM public.club_season_absence_assert_market_open(v_club, NULL, v_allow);
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_season_absence_block_listing ON public."Player_Transfer_Listings";
CREATE TRIGGER trg_season_absence_block_listing
  BEFORE INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_club_season_absence_block_listing();

-- ---------------------------------------------------------------------------
-- 8) Block voluntary release / manager market while absent
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'player_voluntary_contract_release',
        'manager_sack',
        'manager_list_for_transfer',
        'player_new_owner_transfer_list',
        'player_new_owner_release'
      )
      AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('club_season_absence_assert_market_open' IN v_def) > 0 THEN
      CONTINUE;
    END IF;
    v_new := regexp_replace(
      v_def,
      E'\\nBEGIN\\n',
      E'\nBEGIN\n'
      || E'  BEGIN\n'
      || E'    PERFORM public.club_season_absence_assert_market_open(\n'
      || E'      coalesce(public.my_club_shortname(), ''''), NULL, false);\n'
      || E'  EXCEPTION WHEN OTHERS THEN\n'
      || E'    IF SQLERRM ILIKE ''%season absence%'' THEN RAISE; END IF;\n'
      || E'  END;\n',
      1,
      1
    );
    IF v_new IS DISTINCT FROM v_def THEN
      BEGIN
        EXECUTE v_new;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Could not gate %: %', v_oid::regprocedure, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 9) Verify helpers exist
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure('public.club_is_season_absent(text,bigint)') IS NULL THEN
    RAISE EXCEPTION 'club_is_season_absent missing';
  END IF;
  IF to_regprocedure('public.admin_club_season_absence_activate(text,text)') IS NULL THEN
    RAISE EXCEPTION 'admin activate missing';
  END IF;
  RAISE NOTICE 'club_season_absence_20261017 installed';
END $$;
