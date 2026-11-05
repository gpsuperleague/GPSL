-- Mutual "Already played" bypass
-- Both clubs confirm on Schedule → stamp agreed KO + both check-ins +
-- unlock Match Day enter result. Each club: ₿500k + 1 season no-show strike
-- (same ladder / every-3rd ₿2.5m). Not for dual match-system OFF (black-box).

INSERT INTO public.competition_fine_tariff AS t (
  code, label, category, direction, amount, amount_mode, sort_order, is_active, updated_at
)
VALUES (
  'match_already_played_bypass',
  'Already played without arranging',
  'matchday',
  'fine',
  500000,
  'fixed',
  74,
  true,
  now()
)
ON CONFLICT (code) DO UPDATE
SET amount = 500000,
    label = excluded.label,
    is_active = true,
    updated_at = now();

CREATE TABLE IF NOT EXISTS public.competition_fixture_already_played (
  fixture_id bigint PRIMARY KEY
    REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  home_pressed_at timestamptz,
  away_pressed_at timestamptz,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'completed', 'cancelled')),
  completed_at timestamptz,
  home_strike_after integer,
  away_strike_after integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.competition_fixture_already_played IS
  'Mutual Already played confirmations; on both press apply ₿500k + season strike each and unlock result entry.';

-- Inbox type (best-effort widen)
DO $inbox$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND t.relname = 'competition_inbox_messages'
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL THEN
    RETURN;
  END IF;
  IF position('''match_already_played''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_def := regexp_replace(
    v_def,
    '\)$',
    ', ''match_already_played'')'
  );
  EXECUTE 'ALTER TABLE public.competition_inbox_messages DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check';
  EXECUTE 'ALTER TABLE public.competition_inbox_messages ADD CONSTRAINT competition_inbox_message_type_check '
    || v_def;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'match_already_played inbox type: %', SQLERRM;
END;
$inbox$;

CREATE OR REPLACE FUNCTION public.match_schedule_already_played_json(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_sched public.competition_fixture_schedule;
  v_row public.competition_fixture_already_played;
  v_club text;
  v_my_pressed boolean := false;
  v_can_press boolean := false;
  v_can_cancel boolean := false;
  v_blocked text := NULL;
  v_pending_result boolean := false;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('available', false, 'reason', 'not_found');
  END IF;

  BEGIN
    v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
  EXCEPTION WHEN OTHERS THEN
    v_club := NULL;
  END;

  SELECT * INTO v_sched
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  SELECT * INTO v_row
  FROM public.competition_fixture_already_played a
  WHERE a.fixture_id = p_fixture_id;

  v_pending_result := EXISTS (
    SELECT 1 FROM public.competition_result_submissions rs
    WHERE rs.fixture_id = p_fixture_id AND rs.status = 'pending'
  );

  IF v_fixture.status = 'played' THEN
    v_blocked := 'already_played_fixture';
  ELSIF v_fixture.status <> 'scheduled' THEN
    v_blocked := 'not_open';
  ELSIF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    v_blocked := 'manual_black_box';
  ELSIF v_pending_result THEN
    v_blocked := 'result_pending';
  ELSIF coalesce(v_sched.status, 'unscheduled') = 'agreed'
        AND v_sched.agreed_kickoff_at IS NOT NULL
        AND coalesce(v_row.status, '') IS DISTINCT FROM 'completed' THEN
    v_blocked := 'already_agreed';
  ELSIF v_club IS NULL
        OR v_club NOT IN (
          upper(v_fixture.home_club_short_name),
          upper(v_fixture.away_club_short_name)
        ) THEN
    v_blocked := 'not_in_fixture';
  END IF;

  IF v_row.status = 'completed' THEN
    RETURN jsonb_build_object(
      'available', false,
      'completed', true,
      'status', 'completed',
      'completed_at', v_row.completed_at,
      'home_pressed', true,
      'away_pressed', true,
      'my_pressed', true,
      'fine_each', 500000,
      'reason', 'completed'
    );
  END IF;

  IF v_row.status = 'open' THEN
    IF v_club = upper(v_fixture.home_club_short_name) THEN
      v_my_pressed := v_row.home_pressed_at IS NOT NULL;
    ELSIF v_club = upper(v_fixture.away_club_short_name) THEN
      v_my_pressed := v_row.away_pressed_at IS NOT NULL;
    END IF;
    v_can_cancel := v_my_pressed AND v_blocked IS NULL;
    v_can_press := NOT v_my_pressed AND v_blocked IS NULL;
  ELSE
    v_can_press := v_blocked IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'available', v_blocked IS NULL OR (v_row.status = 'open'),
    'completed', false,
    'status', coalesce(v_row.status, 'none'),
    'home_pressed', coalesce(v_row.home_pressed_at IS NOT NULL, false),
    'away_pressed', coalesce(v_row.away_pressed_at IS NOT NULL, false),
    'my_pressed', v_my_pressed,
    'can_press', v_can_press,
    'can_cancel', v_can_cancel,
    'fine_each', 500000,
    'reason', v_blocked,
    'warning',
      'Both clubs confirm → ₿500k fine + 1 season no-show strike each, then enter the result on Match Day.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_already_played_press(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_sched public.competition_fixture_schedule;
  v_row public.competition_fixture_already_played;
  v_club text;
  v_is_home boolean;
  v_opp text;
  v_home_owner uuid;
  v_away_owner uuid;
  v_home_strikes integer := 0;
  v_away_strikes integer := 0;
  v_href text;
  v_both boolean := false;
  v_ko timestamptz;
BEGIN
  v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;
  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open';
  END IF;
  IF v_club NOT IN (
       upper(v_fixture.home_club_short_name),
       upper(v_fixture.away_club_short_name)
     )
  THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RAISE EXCEPTION 'Use Match Day directly — both clubs have match system OFF';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_result_submissions rs
    WHERE rs.fixture_id = p_fixture_id AND rs.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is already pending confirmation';
  END IF;

  SELECT * INTO v_sched
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.match_schedule_ensure_row(p_fixture_id);
    SELECT * INTO v_sched
    FROM public.competition_fixture_schedule s
    WHERE s.fixture_id = p_fixture_id
    FOR UPDATE;
  END IF;

  IF coalesce(v_sched.status, 'unscheduled') = 'agreed'
     AND v_sched.agreed_kickoff_at IS NOT NULL THEN
    RAISE EXCEPTION 'Kick-off is already agreed — use the normal check-in / result path';
  END IF;

  SELECT * INTO v_row
  FROM public.competition_fixture_already_played a
  WHERE a.fixture_id = p_fixture_id
  FOR UPDATE;

  IF v_row.status = 'completed' THEN
    RETURN jsonb_build_object('ok', true, 'completed', true, 'already_done', true);
  END IF;

  v_is_home := v_club = upper(v_fixture.home_club_short_name);
  v_opp := CASE
    WHEN v_is_home THEN v_fixture.away_club_short_name
    ELSE v_fixture.home_club_short_name
  END;

  IF NOT FOUND OR v_row.fixture_id IS NULL THEN
    INSERT INTO public.competition_fixture_already_played (
      fixture_id, home_pressed_at, away_pressed_at, status, updated_at
    )
    VALUES (
      p_fixture_id,
      CASE WHEN v_is_home THEN now() ELSE NULL END,
      CASE WHEN NOT v_is_home THEN now() ELSE NULL END,
      'open',
      now()
    )
    RETURNING * INTO v_row;
  ELSE
    IF v_is_home AND v_row.home_pressed_at IS NOT NULL THEN
      RAISE EXCEPTION 'Your club already confirmed Already played — waiting for opponent';
    END IF;
    IF NOT v_is_home AND v_row.away_pressed_at IS NOT NULL THEN
      RAISE EXCEPTION 'Your club already confirmed Already played — waiting for opponent';
    END IF;

    UPDATE public.competition_fixture_already_played
    SET
      home_pressed_at = CASE WHEN v_is_home THEN now() ELSE home_pressed_at END,
      away_pressed_at = CASE WHEN NOT v_is_home THEN now() ELSE away_pressed_at END,
      updated_at = now()
    WHERE fixture_id = p_fixture_id
    RETURNING * INTO v_row;
  END IF;

  v_both := v_row.home_pressed_at IS NOT NULL AND v_row.away_pressed_at IS NOT NULL;

  IF NOT v_both THEN
    v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;
    BEGIN
      PERFORM public.match_schedule_notify_opponent(
        v_fixture,
        'match_already_played',
        'Opponent: Already played — confirm?',
        coalesce(public.club_display_name(v_club), v_club)
          || ' confirmed you already played this fixture without arranging on site. '
          || 'If you agree, confirm Already played (₿500k + 1 season strike each) to unlock result entry.',
        v_opp,
        'already_played_press:' || p_fixture_id::text || ':' || v_club
      );
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        PERFORM public.owner_inbox_send(
          'match_noshow_warning',
          'Opponent: Already played — confirm?',
          coalesce(public.club_display_name(v_club), v_club)
            || ' confirmed you already played. Confirm on Schedule to unlock result entry (₿500k + 1 season strike each).',
          v_opp,
          NULL, p_fixture_id, NULL, NULL, NULL, v_href,
          'already_played_press:' || p_fixture_id::text || ':' || v_club,
          v_fixture.gpsl_month, v_fixture.season_id, NULL
        );
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END;

    RETURN jsonb_build_object(
      'ok', true,
      'completed', false,
      'waiting_for_opponent', true,
      'fine_each', 500000
    );
  END IF;

  -- Both confirmed — complete
  v_ko := now();

  -- Drop pending mutual / Discord override
  BEGIN
    UPDATE public.competition_fixture_mutual_override
    SET status = 'cancelled'
    WHERE fixture_id = p_fixture_id AND status = 'pending';
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    NULL;
  END;

  BEGIN
    UPDATE public.competition_fixture_schedule_proposal
    SET status = 'superseded'
    WHERE fixture_id = p_fixture_id
      AND status = 'pending';
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    NULL;
  END;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'agreed',
    agreed_kickoff_at = v_ko,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    admin_result_unlock_at = coalesce(admin_result_unlock_at, now()),
    admin_result_unlock_note = coalesce(
      admin_result_unlock_note,
      'already_played_mutual: both confirmed; ₿500k + season strike each'
    ),
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name)
  VALUES
    (p_fixture_id, v_fixture.home_club_short_name),
    (p_fixture_id, v_fixture.away_club_short_name)
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  -- Fines
  PERFORM public.competition_apply_club_fine_tariff(
    v_fixture.home_club_short_name,
    'match_already_played_bypass',
    NULL,
    'Already played without arranging (mutual confirm)',
    p_fixture_id,
    v_fixture.season_id
  );
  PERFORM public.competition_apply_club_fine_tariff(
    v_fixture.away_club_short_name,
    'match_already_played_bypass',
    NULL,
    'Already played without arranging (mutual confirm)',
    p_fixture_id,
    v_fixture.season_id
  );

  -- Season no-show strikes (same ladder)
  v_home_owner := public.match_schedule_club_owner_id(v_fixture.home_club_short_name);
  v_away_owner := public.match_schedule_club_owner_id(v_fixture.away_club_short_name);
  v_home_strikes := public.match_schedule_add_season_strike(
    v_fixture.season_id, v_home_owner, p_fixture_id, v_fixture.home_club_short_name
  );
  v_away_strikes := public.match_schedule_add_season_strike(
    v_fixture.season_id, v_away_owner, p_fixture_id, v_fixture.away_club_short_name
  );

  UPDATE public.competition_fixture_already_played
  SET
    status = 'completed',
    completed_at = now(),
    home_strike_after = v_home_strikes,
    away_strike_after = v_away_strikes,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  v_href := 'matchday.html?fixture=' || p_fixture_id::text;
  BEGIN
    PERFORM public.owner_inbox_send(
      'match_already_played',
      'Already played — ₿500k + strike',
      'Both clubs confirmed this fixture was played without arranging on site. '
        || '₿500k fine and 1 season no-show strike applied. Enter / confirm the result on Match Day.',
      v_fixture.home_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'already_played_done:' || p_fixture_id::text || ':home',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
    PERFORM public.owner_inbox_send(
      'match_already_played',
      'Already played — ₿500k + strike',
      'Both clubs confirmed this fixture was played without arranging on site. '
        || '₿500k fine and 1 season no-show strike applied. Enter / confirm the result on Match Day.',
      v_fixture.away_club_short_name,
      NULL, p_fixture_id, NULL, NULL, NULL, v_href,
      'already_played_done:' || p_fixture_id::text || ':away',
      v_fixture.gpsl_month, v_fixture.season_id, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      PERFORM public.owner_inbox_send(
        'match_noshow_fine',
        'Already played — ₿500k + strike',
        'Both clubs confirmed Already played. ₿500k + 1 season strike each. Enter the result on Match Day.',
        v_fixture.home_club_short_name,
        NULL, p_fixture_id, NULL, NULL, NULL, v_href,
        'already_played_done:' || p_fixture_id::text || ':home',
        v_fixture.gpsl_month, v_fixture.season_id, NULL
      );
      PERFORM public.owner_inbox_send(
        'match_noshow_fine',
        'Already played — ₿500k + strike',
        'Both clubs confirmed Already played. ₿500k + 1 season strike each. Enter the result on Match Day.',
        v_fixture.away_club_short_name,
        NULL, p_fixture_id, NULL, NULL, NULL, v_href,
        'already_played_done:' || p_fixture_id::text || ':away',
        v_fixture.gpsl_month, v_fixture.season_id, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'completed', true,
    'kickoff_at', v_ko,
    'fine_each', 500000,
    'home_season_strikes', v_home_strikes,
    'away_season_strikes', v_away_strikes,
    'matchday_href', v_href
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fixture_already_played_cancel(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_row public.competition_fixture_already_played;
  v_club text;
  v_is_home boolean;
BEGIN
  v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT * INTO v_row
  FROM public.competition_fixture_already_played
  WHERE fixture_id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_row.status IS DISTINCT FROM 'open' THEN
    RAISE EXCEPTION 'Nothing to cancel';
  END IF;

  IF v_row.home_pressed_at IS NOT NULL AND v_row.away_pressed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Already completed — cannot cancel';
  END IF;

  v_is_home := v_club = upper(v_fixture.home_club_short_name);
  IF v_is_home AND v_row.home_pressed_at IS NULL THEN
    RAISE EXCEPTION 'Your club has not confirmed';
  END IF;
  IF NOT v_is_home AND v_row.away_pressed_at IS NULL THEN
    RAISE EXCEPTION 'Your club has not confirmed';
  END IF;

  -- If only this side pressed, delete row; if somehow both, leave alone
  IF (v_is_home AND v_row.away_pressed_at IS NULL)
     OR (NOT v_is_home AND v_row.home_pressed_at IS NULL) THEN
    DELETE FROM public.competition_fixture_already_played WHERE fixture_id = p_fixture_id;
  ELSE
    UPDATE public.competition_fixture_already_played
    SET
      home_pressed_at = CASE WHEN v_is_home THEN NULL ELSE home_pressed_at END,
      away_pressed_at = CASE WHEN NOT v_is_home THEN NULL ELSE away_pressed_at END,
      updated_at = now()
    WHERE fixture_id = p_fixture_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'cancelled', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_already_played_json(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fixture_already_played_press(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fixture_already_played_cancel(bigint) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.match_schedule_already_played_json(bigint)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fixture_already_played_press(bigint)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fixture_already_played_cancel(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
