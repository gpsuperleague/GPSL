-- Free-agent locks (foreign sale, first-season release, contract paid up)
-- last only for the rest of the window the player leaves in.
--   Summer window (June–August, and pre-season) → signable from the January window.
--   Any later release, including January and the months before it → the following summer.

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS foreign_contract_unlock_window text;

ALTER TABLE public."Players"
  DROP CONSTRAINT IF EXISTS players_foreign_contract_unlock_window_check;

ALTER TABLE public."Players"
  ADD CONSTRAINT players_foreign_contract_unlock_window_check
  CHECK (
    foreign_contract_unlock_window IS NULL
    OR foreign_contract_unlock_window IN ('january', 'summer')
  );

COMMENT ON COLUMN public."Players".foreign_contract_unlock_window IS
  'january = signable when that season reaches January; summer = signable when the next season starts.';

CREATE OR REPLACE FUNCTION public.player_release_in_summer_window(p_at timestamptz DEFAULT now())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_status text;
  v_month text;
  v_phase text;
BEGIN
  v_season := public.gpsl_season_id_for_locks();
  IF v_season IS NULL THEN
    RETURN false;
  END IF;

  SELECT s.status INTO v_status
  FROM public.competition_seasons s
  WHERE s.id = v_season;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season, coalesce(p_at, now())), ''));

  IF v_month IN ('june', 'july', 'august') THEN
    RETURN true;
  END IF;
  IF v_month <> '' THEN
    RETURN false;
  END IF;

  IF lower(coalesce(v_status, '')) IN ('preseason', 'setup') THEN
    RETURN true;
  END IF;

  IF to_regclass('public.competition_calendar_status_public') IS NOT NULL THEN
    SELECT st.calendar_phase INTO v_phase
    FROM public.competition_calendar_status_public st
    WHERE st.season_id = v_season
    LIMIT 1;
    IF lower(coalesce(v_phase, '')) = 'pre_season' THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_release_unlock_window(p_at timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN public.player_release_in_summer_window(coalesce(p_at, now())) THEN 'january'
    ELSE 'summer'
  END;
$$;

CREATE OR REPLACE FUNCTION public.player_release_unlock_label(p_at timestamptz DEFAULT now())
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE public.player_release_unlock_window(coalesce(p_at, now()))
    WHEN 'january' THEN 'the January window'
    ELSE 'the summer window'
  END;
$$;

CREATE OR REPLACE FUNCTION public.player_release_lock_cleared(
  p_sold_season_id bigint,
  p_window text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cur bigint;
  v_month text;
  v_window text := lower(btrim(coalesce(p_window, 'summer')));
BEGIN
  IF p_sold_season_id IS NULL THEN
    RETURN true;
  END IF;

  v_cur := public.gpsl_season_id_for_locks();
  IF v_cur IS NULL THEN
    RETURN false;
  END IF;

  IF v_window = 'january' THEN
    IF v_cur > p_sold_season_id THEN
      RETURN true;
    END IF;
    IF v_cur <> p_sold_season_id THEN
      RETURN false;
    END IF;
    v_month := lower(coalesce(public.competition_active_gpsl_month(p_sold_season_id, now()), ''));
    RETURN coalesce(public.competition_gpsl_month_sort(v_month), 0)
        >= public.competition_gpsl_month_sort('january');
  END IF;

  RETURN v_cur > p_sold_season_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_foreign_contract_locked(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND nullif(btrim(p.foreign_contract_club), '') IS NOT NULL
      AND p.foreign_contract_sold_season_id IS NOT NULL
      AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), 'foreign')
            IN ('foreign', 'paid_up')
      AND NOT public.player_release_lock_cleared(
        p.foreign_contract_sold_season_id,
        coalesce(nullif(btrim(p.foreign_contract_unlock_window), ''), 'summer')
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.player_apply_foreign_contract_lock(
  p_player_id text,
  p_foreign_club_name text,
  p_sold_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_foreign_club_name);
  v_sold_season_id bigint;
  v_unlock_label text;
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_apply_foreign_contract_lock: player_id required';
  END IF;

  IF v_club = '' THEN
    v_club := 'Foreign club';
  END IF;

  v_sold_season_id := coalesce(p_sold_season_id, public.gpsl_season_id_for_locks());
  IF v_sold_season_id IS NULL THEN
    RAISE EXCEPTION 'No competition season — cannot record foreign contract lock';
  END IF;

  v_unlock_label := public.player_release_unlock_label();

  UPDATE public."Players"
  SET
    foreign_contract_club = v_club,
    foreign_contract_sold_season_id = v_sold_season_id,
    foreign_contract_unlock_season_label = v_unlock_label,
    foreign_contract_unlock_window = public.player_release_unlock_window(),
    foreign_contract_lock_kind = 'foreign'
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_apply_overflow_paid_up_lock(
  p_player_id text,
  p_previous_club_short_name text,
  p_sold_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_previous_club_short_name);
  v_sold_season_id bigint;
  v_unlock_label text;
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_apply_overflow_paid_up_lock: player_id required';
  END IF;
  IF v_club = '' THEN
    RAISE EXCEPTION 'player_apply_overflow_paid_up_lock: previous club required';
  END IF;

  v_sold_season_id := coalesce(p_sold_season_id, public.gpsl_season_id_for_locks());
  IF v_sold_season_id IS NULL THEN
    RAISE EXCEPTION 'No competition season — cannot record paid-up overflow lock';
  END IF;

  v_unlock_label := public.player_release_unlock_label();

  UPDATE public."Players"
  SET
    foreign_contract_club = v_club,
    foreign_contract_sold_season_id = v_sold_season_id,
    foreign_contract_unlock_season_label = v_unlock_label,
    foreign_contract_unlock_window = public.player_release_unlock_window(),
    foreign_contract_lock_kind = 'paid_up'
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

DO $relabel$
DECLARE
  r record;
  v_def text;
  v_new text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'player_new_owner_release',
        'player_foreign_contract_status',
        'backfill_squad_overflow_mv_fines',
        'club_release_player_foreign_overflow',
        'club_release_player_mv_overflow',
        'player_voluntary_contract_release',
        'sell_player_to_foreign_club'
      )
  LOOP
    v_def := replace(pg_get_functiondef(r.oid), E'\r\n', E'\n');
    v_new := v_def;
    v_new := replace(v_new, 'public.next_gpsl_season_label(v_sold_season_id)', 'public.player_release_unlock_label()');
    v_new := replace(v_new, 'public.next_gpsl_season_label(v_season_id)', 'public.player_release_unlock_label()');
    v_new := replace(v_new, 'public.next_gpsl_season_label(public.current_gpsl_season_id())', 'public.player_release_unlock_label()');
    v_new := replace(v_new, 'public.next_gpsl_season_label(v_release_season_id)', 'public.player_release_unlock_label()');
    v_new := replace(v_new, 'public.next_gpsl_season_label(v_player.foreign_contract_sold_season_id)', 'public.player_release_unlock_label()');
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
    END IF;
  END LOOP;
END
$relabel$;

UPDATE public."Players" p
SET
  foreign_contract_unlock_window = public.player_release_unlock_window(h.transfer_time),
  foreign_contract_unlock_season_label = public.player_release_unlock_label(h.transfer_time)
FROM (
  SELECT DISTINCT ON (th.player_id::text)
    th.player_id::text AS pid,
    th.transfer_time
  FROM public."Transfer_History" th
  ORDER BY th.player_id::text, th.transfer_time DESC
) h
WHERE p."Konami_ID"::text = h.pid
  AND coalesce(p.foreign_contract_lock_kind, '') IN ('foreign', 'paid_up')
  AND p.foreign_contract_sold_season_id IS NOT NULL;

UPDATE public."Players" p
SET
  foreign_contract_unlock_window = 'summer',
  foreign_contract_unlock_season_label = 'the summer window'
WHERE coalesce(p.foreign_contract_lock_kind, '') IN ('foreign', 'paid_up')
  AND p.foreign_contract_sold_season_id IS NOT NULL
  AND p.foreign_contract_unlock_window IS NULL;

GRANT EXECUTE ON FUNCTION public.player_release_in_summer_window(timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.player_release_unlock_window(timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.player_release_unlock_label(timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.player_release_lock_cleared(bigint, text) TO authenticated, service_role;

SELECT jsonb_build_object(
  'now_window', public.player_release_unlock_window(now()),
  'july_window', public.player_release_unlock_window('2026-07-15 12:00:00+00'::timestamptz),
  'still_locked', (
    SELECT count(*)
    FROM public."Players" p
    WHERE coalesce(p.foreign_contract_lock_kind, '') IN ('foreign', 'paid_up')
      AND public.player_foreign_contract_locked(p."Konami_ID"::text)
  ),
  'labels', (
    SELECT coalesce(jsonb_agg(jsonb_build_object('window', w, 'label', lb, 'n', n) ORDER BY w), '[]'::jsonb)
    FROM (
      SELECT p.foreign_contract_unlock_window AS w,
             p.foreign_contract_unlock_season_label AS lb,
             count(*) AS n
      FROM public."Players" p
      WHERE coalesce(p.foreign_contract_lock_kind, '') IN ('foreign', 'paid_up')
      GROUP BY 1, 2
    ) s
  )
);
