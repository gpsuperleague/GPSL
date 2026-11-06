import json
from pathlib import Path

with open("tmp_tick_out.json", "r", encoding="utf-8-sig") as f:
    d = json.load(f)
fn = d["rows"][0]["pg_get_functiondef"].replace("\r\n", "\n")

fn = fn.replace(
    """  v_new_event boolean := false;
  v_event_ko timestamptz;
BEGIN""",
    """  v_new_event boolean := false;
  v_event_ko timestamptz;
  v_agreed_ko timestamptz;
  v_ko_open timestamptz;
  v_ko_close timestamptz;
BEGIN""",
)

old = """  -- Only one side pressed → expire quietly
  IF v_sess.home_pressed_at IS NULL OR v_sess.away_pressed_at IS NULL THEN
    DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;
    UPDATE public.competition_fixture_play_now_session
    SET status = 'expired',
        ko_forfeit_suspended = false,
        updated_at = now()
    WHERE fixture_id = p_fixture_id;
    RETURN;
  END IF;"""

new = """  -- Only one side pressed → expire quietly (no Play Now fine).
  -- If the session overlapped the agreed-KO check-in window, keep check-in
  -- rows so fixture_try_checkin_forfeit can see who showed for KO. Wiping
  -- them first caused both_miss after a valid KO check-in (9426 BES/FLA).
  IF v_sess.home_pressed_at IS NULL OR v_sess.away_pressed_at IS NULL THEN
    v_agreed_ko := public.match_schedule_agreed_kickoff(p_fixture_id);
    IF v_agreed_ko IS NOT NULL THEN
      v_ko_open := public.match_schedule_checkin_opens_at(v_agreed_ko);
      v_ko_close := v_agreed_ko
        + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
    END IF;

    IF v_agreed_ko IS NULL
       OR v_ko_open IS NULL
       OR NOT (
         v_sess.window_started_at < v_ko_close
         AND v_sess.window_ends_at > v_ko_open
       )
    THEN
      DELETE FROM public.competition_fixture_checkin WHERE fixture_id = p_fixture_id;
    END IF;

    UPDATE public.competition_fixture_play_now_session
    SET status = 'expired',
        ko_forfeit_suspended = false,
        updated_at = now()
    WHERE fixture_id = p_fixture_id;
    RETURN;
  END IF;"""

if old not in fn:
    raise SystemExit("old block missing")
fn = fn.replace(old, new)

header = """-- =============================================================================
-- Play Now one-press expire: keep overlapping KO check-ins (2026-11-06)
--
-- Bug: fixture_try_checkin_forfeit calls play_now_session_tick first. One-press
-- expiry deleted ALL check-ins, then KO forfeit saw both missing → both_miss
-- even when a club had checked in for the agreed KO (BES 9426 @ 19:20).
--
-- Fix: on one-press expire, only wipe check-ins when the Play Now window did
-- not overlap the agreed-KO check-in window.
-- Also corrects fixture 9426: reverse BES both_miss strike; FLA stays no-show.
-- Safe re-run.
-- =============================================================================

"""

corr = """

-- ---------------------------------------------------------------------------
-- Correct BES vs FLA fixture 9426 (2026-11-05 19:30 UK)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bes_owner uuid;
  v_season bigint;
BEGIN
  SELECT owner_id INTO v_bes_owner FROM public."Clubs" WHERE "ShortName" = 'BES';
  SELECT season_id INTO v_season FROM public.competition_fixtures WHERE id = 9426;

  -- Drop erroneous BES both_miss event (BES Discord check-in 19:20:48)
  DELETE FROM public.competition_fixture_no_show_events
  WHERE fixture_id = 9426
    AND club_short_name = 'BES'
    AND both_miss = true
    AND kickoff_at = '2026-11-05 19:30:00+00'::timestamptz;

  -- FLA really missed; keep event but clear both_miss flag
  UPDATE public.competition_fixture_no_show_events
  SET both_miss = false
  WHERE fixture_id = 9426
    AND club_short_name = 'FLA'
    AND kickoff_at = '2026-11-05 19:30:00+00'::timestamptz
    AND both_miss = true;

  IF v_bes_owner IS NOT NULL AND v_season IS NOT NULL THEN
    UPDATE public.competition_owner_season_strikes
    SET strike_count = greatest(strike_count - 1, 0),
        updated_at = now()
    WHERE season_id = v_season
      AND owner_id = v_bes_owner
      AND strike_count > 0;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET admin_result_unlock_note = 'onesided_checkin_auto: BES may submit or either may reschedule; FLA missed check-in (corrected 2026-11-06: Play Now one-press expire had wiped BES KO check-in before both_miss)',
      updated_at = now()
  WHERE fixture_id = 9426
    AND coalesce(admin_result_unlock_note, '') ILIKE '%both_miss%';
END $$;
"""

out_path = Path("supabase/sql/patches/play_now_one_press_keep_ko_checkin_20261106.sql")
out_path.write_text(header + fn + "\n" + corr, encoding="utf-8", newline="\n")
print("wrote", out_path, "chars", out_path.stat().st_size)
