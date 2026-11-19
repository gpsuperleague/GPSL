-- Join plus one: a new owner keeps a league match open through the GPSL month
-- they joined, plus one. Cups stay on their own window.
-- The arrange switch belongs to the owner who set it. A new owner starts on
-- the GPSL system. A manual mutual forfeit waits one GPSL month when a current
-- owner arrived during that match's month.
-- Also reopens Wolves vs Celta (9070), voided at the November lock, and
-- returns the mutual-forfeit fines.

CREATE OR REPLACE FUNCTION public.club_new_owner_catchup_extra_months()
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$ SELECT 1 $function$;

COMMENT ON FUNCTION public.club_new_owner_catchup_through_sort(bigint, text) IS
  'Last GPSL month sort a new owner''s league fixtures stay open (join month + 1).';

DO $do$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_schedule_fixture_within_play_window(bigint,timestamptz)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('match_schedule_fixture_new_owner_catchup_through_sort' IN v_def) = 0 THEN
    v_old := replace($old$
  IF v_active_sort <= v_play_sort + v_grace THEN
    RETURN true;
  END IF;

  -- play window is the hard end

  RETURN false;$old$, E'\r\n', E'\n');
    v_new := replace($new$
  IF v_active_sort <= v_play_sort + v_grace THEN
    RETURN true;
  END IF;

  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_active_sort <= v_owner_through THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'within_play_window owner block not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(
    pg_get_functiondef('public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('match_schedule_fixture_new_owner_catchup_through_sort' IN v_def) = 0 THEN
    v_old := replace($old$
  IF v_closed_sort < v_play_sort + v_grace THEN
    RETURN false;
  END IF;

  -- play window is the hard end

  RETURN true;$old$, E'\r\n', E'\n');
    v_new := replace($new$
  IF v_closed_sort < v_play_sort + v_grace THEN
    RETURN false;
  END IF;

  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_closed_sort <= v_owner_through THEN
      RETURN false;
    END IF;
  END IF;

  RETURN true;$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'play_window_expired owner block not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$do$;

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
    RETURN true;
  END IF;

  -- Only the current owner's own switch counts. A previous owner's off does not carry over.
  IF v_half = 'h2' THEN
    SELECT p.gpsl_system_on INTO v_on
    FROM public.club_match_system_preference p
    JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
    WHERE p.club_short_name = p_club
      AND p.season_id = p_season_id
      AND p.half = 'h2'
      AND c.owner_id IS NOT NULL
      AND p.set_by_owner_id IS NOT DISTINCT FROM c.owner_id;
    IF FOUND THEN
      RETURN coalesce(v_on, true);
    END IF;
  END IF;

  SELECT p.gpsl_system_on INTO v_on
  FROM public.club_match_system_preference p
  JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
  WHERE p.club_short_name = p_club
    AND p.season_id = p_season_id
    AND p.half = 'h1'
    AND c.owner_id IS NOT NULL
    AND p.set_by_owner_id IS NOT DISTINCT FROM c.owner_id;

  RETURN coalesce(v_on, true);
END;
$function$;

DO $do$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.owner_match_system_status()'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$
  SELECT gpsl_system_on INTO v_h1
  FROM public.club_match_system_preference
  WHERE club_short_name = v_club AND season_id = v_season_id AND half = 'h1';
$old$, E'\r\n', E'\n');
  v_new := replace($new$
  SELECT gpsl_system_on INTO v_h1
  FROM public.club_match_system_preference
  WHERE club_short_name = v_club AND season_id = v_season_id AND half = 'h1'
    AND set_by_owner_id IS NOT DISTINCT FROM v_uid;
$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'owner status h1 select not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$
  SELECT gpsl_system_on INTO v_h2
  FROM public.club_match_system_preference
  WHERE club_short_name = v_club AND season_id = v_season_id AND half = 'h2';
$old$, E'\r\n', E'\n');
  v_new := replace($new$
  SELECT gpsl_system_on INTO v_h2
  FROM public.club_match_system_preference
  WHERE club_short_name = v_club AND season_id = v_season_id AND half = 'h2'
    AND set_by_owner_id IS NOT DISTINCT FROM v_uid;
$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'owner status h2 select not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;
  EXECUTE v_def;

  v_def := replace(
    pg_get_functiondef('public.owners_match_system_directory()'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$
    LEFT JOIN public.club_match_system_preference h1
      ON h1.club_short_name = c."ShortName"
     AND h1.season_id = v_season_id
     AND h1.half = 'h1'
$old$, E'\r\n', E'\n');
  v_new := replace($new$
    LEFT JOIN public.club_match_system_preference h1
      ON h1.club_short_name = c."ShortName"
     AND h1.season_id = v_season_id
     AND h1.half = 'h1'
     AND h1.set_by_owner_id IS NOT DISTINCT FROM c.owner_id
$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'directory h1 join not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$
    LEFT JOIN public.club_match_system_preference h2
      ON h2.club_short_name = c."ShortName"
     AND h2.season_id = v_season_id
     AND h2.half = 'h2'
$old$, E'\r\n', E'\n');
  v_new := replace($new$
    LEFT JOIN public.club_match_system_preference h2
      ON h2.club_short_name = c."ShortName"
     AND h2.season_id = v_season_id
     AND h2.half = 'h2'
     AND h2.set_by_owner_id IS NOT DISTINCT FROM c.owner_id
$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'directory h2 join not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;
  EXECUTE v_def;
END;
$do$;

CREATE OR REPLACE FUNCTION public.trg_clubs_new_owner_match_system_on()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.owner_id IS NULL OR NEW.owner_id IS NOT DISTINCT FROM OLD.owner_id THEN
    RETURN NEW;
  END IF;

  DELETE FROM public.club_match_system_preference p
  WHERE upper(btrim(p.club_short_name)) = upper(btrim(NEW."ShortName"));

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_new_owner_match_system_on ON public."Clubs";
CREATE TRIGGER clubs_new_owner_match_system_on
  AFTER UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clubs_new_owner_match_system_on();

-- A previous owner's off switch is not this owner's choice.
UPDATE public.club_match_system_preference p
SET gpsl_system_on = true,
    set_by_owner_id = c.owner_id,
    set_at = now(),
    updated_at = now()
FROM public."Clubs" c
WHERE p.club_short_name = c."ShortName"
  AND c.owner_id IS NOT NULL
  AND p.gpsl_system_on IS FALSE
  AND p.set_by_owner_id IS DISTINCT FROM c.owner_id;

CREATE OR REPLACE FUNCTION public.fixture_manual_forfeit_due(
  p_fixture_id bigint,
  p_closed_gpsl_month text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_month text;
  v_home text;
  v_away text;
  v_play int;
  v_closed int;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_hold boolean := false;
BEGIN
  SELECT f.season_id, f.gpsl_month, f.home_club_short_name, f.away_club_short_name
  INTO v_season, v_month, v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF v_month IS NULL OR p_closed_gpsl_month IS NULL THEN
    RETURN false;
  END IF;

  v_play := public.competition_gpsl_month_sort(v_month);
  v_closed := public.competition_gpsl_month_sort(p_closed_gpsl_month);
  IF v_play IS NULL OR v_closed IS NULL THEN
    RETURN false;
  END IF;

  SELECT c.unlock_at, c.lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND lower(btrim(c.gpsl_month)) = lower(btrim(v_month))
  ORDER BY c.lock_at
  LIMIT 1;

  IF v_unlock IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public."Clubs" cl
      WHERE upper(btrim(cl."ShortName")) IN (upper(btrim(v_home)), upper(btrim(v_away)))
        AND cl.owner_id IS NOT NULL
        AND cl.owner_assigned_at IS NOT NULL
        AND cl.owner_assigned_at >= v_unlock
        AND (v_lock IS NULL OR cl.owner_assigned_at < v_lock)
    ) INTO v_hold;
  END IF;

  -- New owner during the match's month: the manual void waits until the next GPSL month.
  IF v_hold THEN
    RETURN v_closed = v_play + 1;
  END IF;

  RETURN v_closed = v_play;
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_manual_forfeit_due(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_manual_forfeit_due(bigint, text) TO service_role;

DO $do$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_enforce_manual_black_box_forfeits(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('fixture_manual_forfeit_due' IN v_def) = 0 THEN
    v_old := replace($old$
      AND lower(btrim(coalesce(f.gpsl_month, ''))) = lower(btrim(coalesce(p_closed_gpsl_month, '')))
      AND public.fixture_is_manual_black_box(f.id)
$old$, E'\r\n', E'\n');
    v_new := replace($new$
      AND public.fixture_is_manual_black_box(f.id)
      AND public.fixture_manual_forfeit_due(f.id, p_closed_gpsl_month)
$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'manual forfeit month filter not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$do$;

DO $fix$
DECLARE
  v_stats int;
  v_ledger int;
  v_bank int;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = 9070
      AND f.status = 'played'
      AND f.is_void
      AND f.home_goals IS NULL
      AND f.away_goals IS NULL
      AND f.award_note ILIKE 'Mutual forfeit%'
  ) THEN
    RETURN;
  END IF;

  SELECT count(*) INTO v_stats
  FROM public.competition_match_player_stats s
  WHERE s.fixture_id = 9070;
  IF v_stats <> 0 THEN
    RAISE EXCEPTION '9070 has player stats';
  END IF;

  SELECT count(*) INTO v_ledger
  FROM public.competition_finance_ledger l
  WHERE l.fixture_id = 9070
    AND l.entry_type = 'gov_fine_compensation'
    AND l.amount = -2500000;
  IF v_ledger <> 2 THEN
    RAISE EXCEPTION '9070 fine rows are %', v_ledger;
  END IF;

  SELECT count(*) INTO v_bank
  FROM public.bank_ledger b
  WHERE b.club_ledger_id IN (845945, 845946)
    AND b.amount = 2500000;
  IF v_bank <> 2 THEN
    RAISE EXCEPTION '9070 bank rows are %', v_bank;
  END IF;

  PERFORM public.competition_credit_club_balance('WOL', 2500000);
  PERFORM public.competition_credit_club_balance('CVI', 2500000);

  DELETE FROM public.bank_ledger b
  WHERE b.club_ledger_id IN (845945, 845946);

  DELETE FROM public.competition_finance_ledger l
  WHERE l.id IN (845945, 845946);

  UPDATE public.gpsl_bank_account
  SET reserves = reserves - 5000000;

  UPDATE public.competition_fixtures f
  SET status = 'scheduled',
      is_void = false,
      is_forfeit = false,
      forfeit_loser_club = NULL,
      home_goals = NULL,
      away_goals = NULL,
      award_note = NULL,
      result_posted_at = NULL,
      result_posted_gpsl_month = NULL
  WHERE f.id = 9070;

  PERFORM public.owner_inbox_send(
    'match_rescheduled',
    'November MD12 reopened',
    E'Wolves vs Celta was voided at the November lock because arranging was off. That switch belonged to the previous owner. Celta is on the GPSL system. The void is lifted and the 2,500,000 fine is returned. Agree a time and play the match.',
    'WOL', NULL, 9070,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=9070',
    'manual_void_reopened:9070:home',
    'november', 1, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_rescheduled',
    'November MD12 reopened',
    E'Wolves vs Celta was voided at the November lock because arranging was off. That switch belonged to the previous owner. Celta is on the GPSL system. The void is lifted and the 2,500,000 fine is returned. Agree a time and play the match.',
    'CVI', NULL, 9070,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=9070',
    'manual_void_reopened:9070:away',
    'november', 1, NULL
  );
END;
$fix$;

SELECT jsonb_build_object(
  'extra_months', public.club_new_owner_catchup_extra_months(),
  'cvi_through', public.club_new_owner_catchup_through_sort(1, 'CVI'),
  'within_wired', position(
    'new_owner_catchup_through_sort' IN pg_get_functiondef('public.match_schedule_fixture_within_play_window(bigint,timestamptz)'::regprocedure)
  ) > 0,
  'expired_wired', position(
    'new_owner_catchup_through_sort' IN pg_get_functiondef('public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure)
  ) > 0,
  'cvi_on', public.club_gpsl_match_system_on('CVI', 1, 'november'),
  'wol_on', public.club_gpsl_match_system_on('WOL', 1, 'november'),
  'liv_on', public.club_gpsl_match_system_on('LIV', 1, 'november'),
  'black_box', public.fixture_is_manual_black_box(9070),
  'due_december', public.fixture_manual_forfeit_due(9070, 'december'),
  'fx', (
    SELECT jsonb_build_object(
      'status', f.status,
      'void', f.is_void,
      'goals', f.home_goals,
      'note', f.award_note
    )
    FROM public.competition_fixtures f
    WHERE f.id = 9070
  ),
  'fines_left', (
    SELECT count(*) FROM public.competition_finance_ledger l WHERE l.fixture_id = 9070
  ),
  'balances', (
    SELECT jsonb_object_agg(b.club_name, b.balance)
    FROM public."Club_Finances" b
    WHERE b.club_name IN ('WOL', 'CVI', 'LIV')
  )
) AS result;
