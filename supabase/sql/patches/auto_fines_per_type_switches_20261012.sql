-- =============================================================================
-- Automatic fines: per-type on/off ticks (2026-10-12)
-- =============================================================================
-- The master switch (auto_fines_ease_in_switch_20260929.sql) stays:
--   master OFF  → every automatic fine is waived (as before)
--   master ON   → each fine type follows its own tick
-- Ticks:
--   * every tariff with direction 'fine'  (competition_fine_tariff.auto_enabled)
--   * board_fine          — end-of-season board fine (owner wallet %)
--   * match_video_points  — missing match video points ladder
-- An unticked type is waived exactly like the ease-in: no ledger, no balance
-- change, owner gets the "would have been fined" message.
-- Manual fines from Admin → Fines always apply. Compensation is never paused.
-- Requires auto_fines_ease_in_switch_20260929.sql. Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_fine_tariff
  ADD COLUMN IF NOT EXISTS auto_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS auto_board_fine_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS auto_mv_points_enabled boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.gpsl_auto_fine_code_active(p_code text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpsl_auto_fines_active()
    AND coalesce(
      CASE p_code
        WHEN 'board_fine' THEN (SELECT gs.auto_board_fine_enabled FROM public.global_settings gs WHERE gs.id = 1)
        WHEN 'match_video_points' THEN (SELECT gs.auto_mv_points_enabled FROM public.global_settings gs WHERE gs.id = 1)
        ELSE (SELECT t.auto_enabled FROM public.competition_fine_tariff t WHERE t.code = p_code)
      END,
      true
    );
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_auto_fine_code_active(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Point the live fine functions at the per-type check
-- ---------------------------------------------------------------------------
DO $swap$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.competition_apply_club_fine_tariff(text, text, numeric, text, bigint, bigint)'::regprocedure
  ) INTO v_def;
  IF position('gpsl_auto_fine_code_active' IN v_def) = 0 THEN
    IF position('NOT public.gpsl_auto_fines_active()' IN v_def) = 0 THEN
      RAISE EXCEPTION 'competition_apply_club_fine_tariff has no auto-fines switch — run auto_fines_ease_in_switch_20260929.sql first';
    END IF;
    EXECUTE replace(v_def, 'NOT public.gpsl_auto_fines_active()',
                    'NOT public.gpsl_auto_fine_code_active(v_tariff.code)');
  END IF;

  SELECT pg_get_functiondef(
    'public.board_fine_owner_personal_pct(text, numeric, text, bigint, jsonb)'::regprocedure
  ) INTO v_def;
  IF position('gpsl_auto_fine_code_active' IN v_def) = 0 THEN
    IF position('NOT public.gpsl_auto_fines_active()' IN v_def) = 0 THEN
      RAISE EXCEPTION 'board_fine_owner_personal_pct has no auto-fines switch — run auto_fines_ease_in_switch_20260929.sql first';
    END IF;
    EXECUTE replace(v_def, 'NOT public.gpsl_auto_fines_active()',
                    'NOT public.gpsl_auto_fine_code_active(''board_fine'')');
  END IF;
END
$swap$;

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
  END IF;
  IF NOT public.gpsl_auto_fine_code_active('match_video_points') THEN
    NEW.pts_status := 'cleared';
    NEW.pts_suspend_until := NULL;
    NEW.pts_cleared_at := now();
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_inbox_mv_points_ease_in()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.dedupe_key LIKE 'mv_pts_suspend:%'
     AND NOT public.gpsl_auto_fine_code_active('match_video_points') THEN
    NEW.title := 'Match video — points waived';
    NEW.body := concat_ws(
      E'\n',
      'No match video was uploaded for this fixture within the upload window.',
      'Normally a 1 point deduction would now be suspended, becoming a full −1 if the video is still missing, and a 3rd strike in a season costs an extra −9 points.',
      'Match video points deductions are currently switched off, so no points are deducted.'
    );
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_fine_applied_inbox_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_master boolean := public.gpsl_auto_fines_active();
BEGIN
  IF coalesce(NEW.waived, false) THEN
    PERFORM public.owner_inbox_send(
      'fine_applied',
      CASE WHEN v_master THEN 'Fine waived' ELSE 'Fine waived — ease-in period' END,
      concat_ws(
        E'\n',
        'No money has been taken.',
        format(
          'You would have been fined %s for: %s',
          public.transfer_format_money(NEW.amount),
          regexp_replace(NEW.description, '^Fine — ', '')
        ),
        CASE WHEN v_master
          THEN 'Automatic fines of this type are currently switched off.'
          ELSE public.gpsl_auto_fines_live_label()
        END
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
-- Status + admin RPCs
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
    'waived_total', (SELECT coalesce(sum(amount), 0) FROM public.competition_fine_applied WHERE waived),
    'switches', (
      SELECT coalesce(jsonb_agg(x.j ORDER BY x.cat_order, x.sort_order, x.label), '[]'::jsonb)
      FROM (
        SELECT jsonb_build_object(
                 'code', t.code, 'label', t.label, 'category', t.category,
                 'amount', t.amount, 'amount_mode', t.amount_mode,
                 'enabled', t.auto_enabled,
                 'waived_count', (SELECT count(*) FROM public.competition_fine_applied a
                                  WHERE a.waived AND a.tariff_code = t.code)
               ) AS j,
               CASE t.category WHEN 'matchday' THEN 1 WHEN 'squad' THEN 2 WHEN 'transfer' THEN 3
                               WHEN 'manager' THEN 4 ELSE 5 END AS cat_order,
               t.sort_order, t.label
        FROM public.competition_fine_tariff t
        WHERE t.direction = 'fine' AND t.is_active
        UNION ALL
        SELECT jsonb_build_object('code', 'board_fine', 'label', 'End-of-season board fine (owner wallet %)',
                                  'category', 'other', 'enabled', gs.auto_board_fine_enabled),
               6, 1, 'board'
        UNION ALL
        SELECT jsonb_build_object('code', 'match_video_points', 'label', 'Missing match video — points deductions',
                                  'category', 'matchday', 'enabled', gs.auto_mv_points_enabled),
               1, 32000, 'mv'
      ) x
    )
  )
  FROM public.global_settings gs
  WHERE gs.id = 1;
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_auto_fines_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_auto_fine_switch(p_code text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_code = 'board_fine' THEN
    UPDATE public.global_settings SET auto_board_fine_enabled = coalesce(p_enabled, true) WHERE id = 1;
  ELSIF p_code = 'match_video_points' THEN
    UPDATE public.global_settings SET auto_mv_points_enabled = coalesce(p_enabled, true) WHERE id = 1;
  ELSE
    UPDATE public.competition_fine_tariff
    SET auto_enabled = coalesce(p_enabled, true), updated_at = now()
    WHERE code = p_code AND direction = 'fine';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown fine type %', p_code;
    END IF;
  END IF;

  RETURN public.gpsl_auto_fines_status();
END;
$fn$;

REVOKE ALL ON FUNCTION public.admin_set_auto_fine_switch(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_auto_fine_switch(text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  s->>'label' AS fine_type,
  s->>'code' AS code,
  s->>'category' AS category,
  (s->>'enabled')::boolean AS ticked,
  public.gpsl_auto_fines_active() AS master_on,
  public.gpsl_auto_fine_code_active(s->>'code') AS charging_now
FROM jsonb_array_elements(public.gpsl_auto_fines_status()->'switches') s;
