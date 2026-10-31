-- =============================================================================
-- Admin: unlock result entry when one club missed check-in — KEEP fines/strikes
-- =============================================================================
-- Use when clubs already played (or will enter the score) but only one side
-- checked in. Inserts the missing check-in row(s) so Match Day submit works.
--
-- Does NOT:
--   • delete competition_fixture_no_show_events
--   • waive / delete competition_fine_applied
--   • reduce competition_owner_season_strikes
--   • call match_schedule_clear_no_show (schedule flag left alone until natural
--     clear paths; events + ledger stay)
--
-- Does:
--   • ensure no-show is recorded first (fixture_try_checkin_forfeit) if window
--     already closed and one side missing
--   • insert missing competition_fixture_checkin rows
--   • stamp schedule.admin_result_unlock_* for audit
--
-- Apply, then optionally run the BEN vs ARS MD4 one-shot at the bottom.
-- =============================================================================

ALTER TABLE public.competition_fixture_schedule
  ADD COLUMN IF NOT EXISTS admin_result_unlock_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_result_unlock_by uuid,
  ADD COLUMN IF NOT EXISTS admin_result_unlock_note text;

CREATE OR REPLACE FUNCTION public.admin_fixture_unlock_result_entry(
  p_fixture_id bigint,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%ROWTYPE;
  v_kickoff timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_inserted text[] := ARRAY[]::text[];
  v_noshow_events int := 0;
  v_fines int := 0;
  v_fines_amt numeric := 0;
  v_resolve boolean := false;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
BEGIN
  -- SQL Editor (postgres) counts as admin via is_gpsl_admin(); JWT admins too.
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_fixture_id IS NULL OR p_fixture_id < 1 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_fixture_id');
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_fixture.status = 'played' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'already_played',
      'fixture_id', p_fixture_id
    );
  END IF;

  IF v_fixture.status IS DISTINCT FROM 'scheduled' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_scheduled',
      'status', v_fixture.status
    );
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_agreed_kickoff');
  END IF;

  -- Record no-show / fine / strike first if window closed (idempotent).
  IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
    v_resolve := public.fixture_try_checkin_forfeit(p_fixture_id);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ), EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  )
  INTO v_home_in, v_away_in;

  IF v_home_in AND v_away_in THEN
    -- Already unlocked for submit; still stamp audit if first unlock
    UPDATE public.competition_fixture_schedule
    SET admin_result_unlock_at = coalesce(admin_result_unlock_at, now()),
        admin_result_unlock_by = coalesce(admin_result_unlock_by, auth.uid()),
        admin_result_unlock_note = coalesce(admin_result_unlock_note, v_note),
        updated_at = now()
    WHERE fixture_id = p_fixture_id;

    SELECT count(*)::int INTO v_noshow_events
    FROM public.competition_fixture_no_show_events e
    WHERE e.fixture_id = p_fixture_id;

    SELECT count(*)::int, coalesce(sum(fa.amount), 0)
    INTO v_fines, v_fines_amt
    FROM public.competition_fine_applied fa
    WHERE fa.fixture_id = p_fixture_id
      AND fa.tariff_code ILIKE '%no_show%'
      AND coalesce(fa.waived, false) = false;

    RETURN jsonb_build_object(
      'ok', true,
      'already_both_checked_in', true,
      'fixture_id', p_fixture_id,
      'home', v_fixture.home_club_short_name,
      'away', v_fixture.away_club_short_name,
      'inserted', '[]'::jsonb,
      'resolve_ran', v_resolve,
      'preserved_noshow_events', v_noshow_events,
      'preserved_noshow_fines', v_fines,
      'preserved_noshow_fines_amount', v_fines_amt,
      'note', 'Both already checked in — fines/strikes untouched'
    );
  END IF;

  IF NOT v_home_in THEN
    INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name, checked_in_at)
    VALUES (p_fixture_id, v_fixture.home_club_short_name, now())
    ON CONFLICT (fixture_id, club_short_name) DO NOTHING;
    v_inserted := array_append(v_inserted, v_fixture.home_club_short_name);
  END IF;

  IF NOT v_away_in THEN
    INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name, checked_in_at)
    VALUES (p_fixture_id, v_fixture.away_club_short_name, now())
    ON CONFLICT (fixture_id, club_short_name) DO NOTHING;
    v_inserted := array_append(v_inserted, v_fixture.away_club_short_name);
  END IF;

  UPDATE public.competition_fixture_schedule
  SET admin_result_unlock_at = now(),
      admin_result_unlock_by = auth.uid(),
      admin_result_unlock_note = coalesce(
        v_note,
        'Admin unlock result entry — keep no-show fines/strikes'
      ),
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  -- Explicitly do NOT clear no-show events / fines / strikes.
  SELECT count(*)::int INTO v_noshow_events
  FROM public.competition_fixture_no_show_events e
  WHERE e.fixture_id = p_fixture_id;

  SELECT count(*)::int, coalesce(sum(fa.amount), 0)
  INTO v_fines, v_fines_amt
  FROM public.competition_fine_applied fa
  WHERE fa.fixture_id = p_fixture_id
    AND fa.tariff_code ILIKE '%no_show%'
    AND coalesce(fa.waived, false) = false;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home', v_fixture.home_club_short_name,
    'away', v_fixture.away_club_short_name,
    'matchday', v_fixture.matchday,
    'inserted_checkins', to_jsonb(v_inserted),
    'resolve_ran', v_resolve,
    'preserved_noshow_events', v_noshow_events,
    'preserved_noshow_fines', v_fines,
    'preserved_noshow_fines_amount', v_fines_amt,
    'fines_waived', false,
    'strikes_cleared', false,
    'note', coalesce(v_note, 'Admin unlock — missing check-in(s) added; penalties kept')
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_fixture_unlock_result_entry(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_fixture_unlock_result_entry(bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- One-shot: Championship A MD4 Benfica (H) vs Arsenal (A) — fixture 9376
-- Benfica checked in; Arsenal missed. Unlock submit; keep ARS no-show penalties.
-- Safe re-run.
-- ---------------------------------------------------------------------------
DO $fix$
DECLARE
  v_fixture_id bigint := 9376;
  v_home text;
  v_away text;
  v_md int;
  v_status text;
  v_result jsonb;
BEGIN
  SELECT f.home_club_short_name, f.away_club_short_name, f.matchday, f.status
  INTO v_home, v_away, v_md, v_status
  FROM public.competition_fixtures f
  JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
  WHERE f.id = v_fixture_id;

  IF v_home IS NULL THEN
    RAISE EXCEPTION 'Fixture % not found in current season', v_fixture_id;
  END IF;

  IF upper(v_home) <> 'BEN' OR upper(v_away) <> 'ARS' OR coalesce(v_md, 0) <> 4 THEN
    RAISE EXCEPTION 'Fixture % is % vs % MD% — expected BEN vs ARS MD4',
      v_fixture_id, v_home, v_away, v_md;
  END IF;

  IF v_status <> 'scheduled' THEN
    RAISE NOTICE 'Fixture % status is % — skip unlock (already done?)', v_fixture_id, v_status;
    RETURN;
  END IF;

  -- Ensure no-show recorded, then unlock without clearing penalties
  IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
    PERFORM public.fixture_try_checkin_forfeit(v_fixture_id);
  END IF;

  v_result := public.admin_fixture_unlock_result_entry(
    v_fixture_id,
    'MD4 BEN vs ARS — Arsenal missed check-in; unlock result entry; keep fines/strikes'
  );

  RAISE NOTICE 'BEN/ARS MD4 unlock: %', v_result;
END;
$fix$;

SELECT
  to_regprocedure('public.admin_fixture_unlock_result_entry(bigint,text)') IS NOT NULL AS unlock_rpc,
  f.id,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  f.matchday,
  f.status,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
  ) AS home_checked_in,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
  ) AS away_checked_in,
  s.no_show_club_short_name,
  s.admin_result_unlock_at,
  (SELECT count(*) FROM public.competition_fixture_no_show_events e WHERE e.fixture_id = f.id) AS noshow_events,
  (SELECT count(*) FROM public.competition_fine_applied fa
    WHERE fa.fixture_id = f.id AND fa.tariff_code ILIKE '%no_show%' AND coalesce(fa.waived, false) = false
  ) AS active_noshow_fines
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.id = 9376;
