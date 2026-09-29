-- =============================================================================
-- Automatic fines on/off switch (ease-in period)
--
-- When OFF:
--   * Every automatic fine through competition_apply_club_fine_tariff
--     (scheduling, check-in no-shows, missing match video, video breaches,
--     squad minimum / overflow / star cap …) is recorded as WAIVED:
--     no ledger entry, no balance change.
--   * The owner gets a "you would have been fined" inbox message instead.
--   * The end-of-season board fine (owner wallet %) is waived the same way.
--   * Missing match video: fine waived AND no points ladder (suspended /
--     full −1 / 3-strike −9); the points inbox message explains the waiver.
--   * Warnings, reminders and deadlines still fire as normal.
--   * Manual fines from Admin → Fines still apply.
--   * Compensation tariffs are never paused.
--
-- Optional auto switch-on: auto_fines_live_from (fines go live at that time).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS auto_fines_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS auto_fines_live_from timestamptz;

ALTER TABLE public.competition_fine_applied
  ADD COLUMN IF NOT EXISTS waived boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.gpsl_auto_fines_active()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT gs.auto_fines_enabled
         OR (gs.auto_fines_live_from IS NOT NULL AND gs.auto_fines_live_from <= now())
     FROM public.global_settings gs
     WHERE gs.id = 1),
    true
  );
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_auto_fines_active() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_auto_fines_live_label()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN gs.auto_fines_live_from IS NOT NULL THEN
      'Automatic fines go live on '
        || to_char(gs.auto_fines_live_from AT TIME ZONE 'Europe/London', 'FMDD Mon YYYY') || '.'
    ELSE 'Automatic fines will switch on after the ease-in period.'
  END
  FROM public.global_settings gs
  WHERE gs.id = 1;
$$;

-- ---------------------------------------------------------------------------
-- Record a waived fine (no ledger, no balance change)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_record_waived_fine(
  p_club_short_name text,
  p_tariff_code text,
  p_amount numeric,
  p_note text DEFAULT NULL,
  p_fixture_id bigint DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_label text;
  v_season_id bigint := p_season_id;
  v_desc text;
  v_applied_id bigint;
BEGIN
  SELECT label INTO v_label
  FROM public.competition_fine_tariff
  WHERE code = p_tariff_code;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  v_desc := format('Fine — %s', coalesce(v_label, p_tariff_code));
  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    v_desc := v_desc || ' — ' || btrim(p_note);
  END IF;

  INSERT INTO public.competition_fine_applied (
    season_id, tariff_code, club_short_name, amount, direction,
    description, note, fixture_id, ledger_id, applied_by, waived
  )
  VALUES (
    v_season_id, p_tariff_code, btrim(p_club_short_name), abs(p_amount), 'fine',
    v_desc, p_note, p_fixture_id, NULL, 'SYSTEM', true
  )
  RETURNING id INTO v_applied_id;

  RETURN jsonb_build_object(
    'applied_id', v_applied_id,
    'ledger_id', NULL,
    'club_short_name', btrim(p_club_short_name),
    'tariff_code', p_tariff_code,
    'amount', abs(p_amount),
    'direction', 'fine',
    'ledger_amount', 0,
    'waived', true,
    'inbox_notified', true
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.competition_record_waived_fine(text, text, numeric, text, bigint, bigint) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Inbox: waived rows get the "would have been fined" message
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_fine_applied_inbox_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(NEW.waived, false) THEN
    PERFORM public.owner_inbox_send(
      'fine_applied',
      'Fine waived — ease-in period',
      concat_ws(
        E'\n',
        'No money has been taken.',
        format(
          'You would have been fined %s for: %s',
          public.transfer_format_money(NEW.amount),
          regexp_replace(NEW.description, '^Fine — ', '')
        ),
        public.gpsl_auto_fines_live_label()
      ),
      NEW.club_short_name,
      NULL,
      NEW.fixture_id,
      NULL, NULL, NULL,
      'finances.html',
      'fine:' || NEW.id::text,
      NULL,
      NEW.season_id
    );
  ELSE
    PERFORM public.owner_inbox_notify_fine_applied(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Inject the switch into the live fine functions (keeps mod permission rewrites)
-- ---------------------------------------------------------------------------
DO $inject_tariff$
DECLARE
  v_def text;
  v_anchor text := 'IF p_season_id IS NULL THEN';
  v_block text := $blk$IF v_tariff.direction = 'fine'
     AND NOT public.gpsl_auto_fines_active()
     AND coalesce(current_setting('gpsl.manual_fine', true), '') <> '1' THEN
    RETURN public.competition_record_waived_fine(
      v_club, v_tariff.code, v_amount, p_note, p_fixture_id, p_season_id
    );
  END IF;

  $blk$;
  v_pos int;
BEGIN
  SELECT pg_get_functiondef(
    'public.competition_apply_club_fine_tariff(text, text, numeric, text, bigint, bigint)'::regprocedure
  ) INTO v_def;

  IF position('gpsl_auto_fines_active' IN v_def) > 0 THEN
    RAISE NOTICE 'competition_apply_club_fine_tariff already has the auto-fines switch';
    RETURN;
  END IF;

  v_pos := position(v_anchor IN v_def);
  IF v_pos = 0 THEN
    RAISE EXCEPTION 'competition_apply_club_fine_tariff: anchor not found — switch not applied';
  END IF;

  EXECUTE overlay(v_def PLACING v_block || v_anchor FROM v_pos FOR length(v_anchor));
END;
$inject_tariff$;

DO $inject_manual$
DECLARE
  v_def text;
  v_anchor text := 'RETURN public.competition_apply_club_fine_tariff(';
  v_pos int;
BEGIN
  SELECT pg_get_functiondef(
    'public.competition_admin_apply_fine(text, text, numeric, text, bigint)'::regprocedure
  ) INTO v_def;

  IF position('gpsl.manual_fine' IN v_def) > 0 THEN
    RAISE NOTICE 'competition_admin_apply_fine already flags manual fines';
    RETURN;
  END IF;

  v_pos := position(v_anchor IN v_def);
  IF v_pos = 0 THEN
    RAISE EXCEPTION 'competition_admin_apply_fine: anchor not found — manual bypass not applied';
  END IF;

  EXECUTE overlay(
    v_def
    PLACING E'PERFORM set_config(''gpsl.manual_fine'', ''1'', true);\n  ' || v_anchor
    FROM v_pos FOR length(v_anchor)
  );
END;
$inject_manual$;

DO $inject_board$
DECLARE
  v_def text;
  v_anchor text := 'PERFORM public._post_owner_ledger_internal(';
  v_block text := $blk$IF NOT public.gpsl_auto_fines_active() THEN
    PERFORM public.owner_inbox_send(
      'fine_applied',
      'Board fine waived — ease-in period',
      concat_ws(
        E'\n',
        'No money has been taken from your Building Society account.',
        format(
          'You would have been fined %s (%s%% of your balance): %s',
          public.transfer_format_money(v_fine),
          v_pct,
          coalesce(nullif(btrim(p_reason), ''), 'Board fine')
        ),
        public.gpsl_auto_fines_live_label()
      ),
      btrim(p_club_short_name),
      NULL, NULL, NULL, NULL, NULL,
      'owners_bank.html',
      'board_fine_waived:' || btrim(p_club_short_name) || ':' || coalesce(p_season_id, 0)::text,
      NULL,
      p_season_id
    );
    RETURN 0;
  END IF;

  $blk$;
  v_pos int;
BEGIN
  SELECT pg_get_functiondef(
    'public.board_fine_owner_personal_pct(text, numeric, text, bigint, jsonb)'::regprocedure
  ) INTO v_def;

  IF position('gpsl_auto_fines_active' IN v_def) > 0 THEN
    RAISE NOTICE 'board_fine_owner_personal_pct already has the auto-fines switch';
    RETURN;
  END IF;

  v_pos := position(v_anchor IN v_def);
  IF v_pos = 0 THEN
    RAISE EXCEPTION 'board_fine_owner_personal_pct: anchor not found — switch not applied';
  END IF;

  EXECUTE overlay(v_def PLACING v_block || v_anchor FROM v_pos FOR length(v_anchor));
END;
$inject_board$;

-- ---------------------------------------------------------------------------
-- Missing match video: no points ladder and no rescind refund while off
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_match_video_failure_ease_in()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.gpsl_auto_fines_active() THEN
    NEW.fine_amount := 0;
    NEW.ledger_id := NULL;
    NEW.pts_status := 'cleared';
    NEW.pts_suspend_until := NULL;
    NEW.pts_cleared_at := now();
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS match_video_failure_ease_in ON public.fixture_match_video_failures;
CREATE TRIGGER match_video_failure_ease_in
  BEFORE INSERT ON public.fixture_match_video_failures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_match_video_failure_ease_in();

CREATE OR REPLACE FUNCTION public.trg_inbox_mv_points_ease_in()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.dedupe_key LIKE 'mv_pts_suspend:%' AND NOT public.gpsl_auto_fines_active() THEN
    NEW.title := 'Match video — points waived (ease-in period)';
    NEW.body := concat_ws(
      E'\n',
      'No match video was uploaded for this fixture within the upload window.',
      'Normally a 1 point deduction would now be suspended, becoming a full −1 if the video is still missing, and a 3rd strike in a season costs an extra −9 points.',
      'During the ease-in period no points are deducted.',
      public.gpsl_auto_fines_live_label()
    );
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS inbox_mv_points_ease_in ON public.competition_inbox;
CREATE TRIGGER inbox_mv_points_ease_in
  BEFORE INSERT ON public.competition_inbox
  FOR EACH ROW
  WHEN (NEW.dedupe_key LIKE 'mv_pts_suspend:%')
  EXECUTE FUNCTION public.trg_inbox_mv_points_ease_in();

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_auto_fines_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'enabled', coalesce(gs.auto_fines_enabled, true),
    'live_from', gs.auto_fines_live_from,
    'active', public.gpsl_auto_fines_active(),
    'waived_count', (SELECT count(*) FROM public.competition_fine_applied WHERE waived),
    'waived_total', (SELECT coalesce(sum(amount), 0) FROM public.competition_fine_applied WHERE waived)
  )
  FROM public.global_settings gs
  WHERE gs.id = 1;
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_auto_fines_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_auto_fines(
  p_enabled boolean,
  p_live_from timestamptz DEFAULT NULL
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

  UPDATE public.global_settings
  SET auto_fines_enabled = coalesce(p_enabled, true),
      auto_fines_live_from = CASE WHEN coalesce(p_enabled, true) THEN NULL ELSE p_live_from END
  WHERE id = 1;

  RETURN public.gpsl_auto_fines_status();
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_set_auto_fines(boolean, timestamptz) TO authenticated;

NOTIFY pgrst, 'reload schema';
