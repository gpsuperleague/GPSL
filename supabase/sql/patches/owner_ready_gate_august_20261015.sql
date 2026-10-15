-- =============================================================================
-- "Ready for August" checklist becomes mandatory to play matches.
--
-- From GPSL August unlock (competition_season_calendar 'august'.unlock_at):
--   • Every required item ticked  → club cleared for the season, checklist hidden.
--   • Anything left unticked      → club locked: cannot check in (so cannot play
--     or enter results), inbox message sent, site-wide warning on every page.
--   • Once the owner completes it → cleared, matches unlock, inbox confirmation.
-- Once cleared, a club stays cleared for that season (later changes don't re-lock).
-- "Recommended" items (sponsor) are not required.
--
--   owner_ready_gate                        per club/season cleared + notified stamps
--   gpsl_owner_ready_refresh(club, season)  evaluate + stamp + inbox
--   owner_season_ready_checklist()          dashboard panel (now stays visible while locked)
--   owner_ready_lock_status()               site-wide warning banner
--   gpsl_owner_ready_gate_sweep()           cron every 10 min from August
--   admin_owner_ready_force_clear(club)     admin override
--   club_matchday_checkin_ready             adds the lock as the first check-in issue
--
-- Depends on owner_season_ready_checklist_20261015.sql. Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.owner_ready_gate (
  club_short_name text NOT NULL,
  season_id bigint NOT NULL,
  owner_id uuid,
  cleared_at timestamptz,
  cleared_by text,
  notified_at timestamptz,
  PRIMARY KEY (club_short_name, season_id)
);

ALTER TABLE public.owner_ready_gate ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_ready_gate_read ON public.owner_ready_gate;
CREATE POLICY owner_ready_gate_read ON public.owner_ready_gate
  FOR SELECT TO authenticated
  USING (
    upper(club_short_name) = upper(coalesce(public.my_club_shortname(), ''))
    OR public.is_gpsl_admin()
  );
REVOKE ALL ON public.owner_ready_gate FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.owner_ready_gate TO authenticated;

-- ---------------------------------------------------------------------------
-- Inbox types
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL
     OR (position('''owner_ready_locked''' IN v_def) > 0 AND position('''owner_ready_unlocked''' IN v_def) > 0) THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t FROM public.competition_inbox WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(v_def, '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'owner_ready_locked'
    UNION
    SELECT 'owner_ready_unlocked'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Read-only helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_august_at(p_season bigint)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT cal.unlock_at
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = p_season AND lower(btrim(cal.gpsl_month)) = 'august'
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_gate_active(p_season bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(now() >= public.gpsl_owner_ready_august_at(p_season), false);
$$;

CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_missing(p_club text, p_season bigint)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(array_agg(i->>'label'), ARRAY[]::text[])
  FROM jsonb_array_elements(public.gpsl_owner_ready_items(p_club, p_season)) i
  WHERE i->>'kind' <> 'recommended'
    AND NOT coalesce((i->>'done')::boolean, false);
$$;

CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_is_cleared(p_club text, p_season bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.owner_ready_gate g
    JOIN public."Clubs" c ON upper(c."ShortName") = upper(g.club_short_name)
    WHERE upper(g.club_short_name) = upper(btrim(p_club))
      AND g.season_id = p_season
      AND g.cleared_at IS NOT NULL
      AND g.owner_id IS NOT DISTINCT FROM c.owner_id
  );
$$;

-- NULL = free to play; otherwise the reason shown at check-in
CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_lock_reason(p_club text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_season bigint := public.gpsl_owner_ready_current_season();
  v_missing text[];
  v_n int;
BEGIN
  IF v_club IS NULL OR v_season IS NULL THEN RETURN NULL; END IF;
  IF NOT public.gpsl_owner_ready_gate_active(v_season) THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE upper(c."ShortName") = v_club AND c.owner_id IS NOT NULL) THEN
    RETURN NULL;
  END IF;
  IF public.gpsl_owner_ready_is_cleared(v_club, v_season) THEN RETURN NULL; END IF;

  v_missing := public.gpsl_owner_ready_missing(v_club, v_season);
  v_n := coalesce(array_length(v_missing, 1), 0);
  IF v_n = 0 THEN RETURN NULL; END IF;

  RETURN format(
    'Matches are locked until your Ready for August checklist is complete (%s item%s left) — finish it on your Dashboard.',
    v_n, CASE WHEN v_n = 1 THEN '' ELSE 's' END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_issue_prepend(p_club text, p_issues text[])
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_reason text;
BEGIN
  BEGIN
    v_reason := public.gpsl_owner_ready_lock_reason(p_club);
  EXCEPTION WHEN OTHERS THEN
    v_reason := NULL;
  END;
  IF v_reason IS NULL THEN
    RETURN coalesce(p_issues, ARRAY[]::text[]);
  END IF;
  RETURN array_prepend(v_reason, coalesce(p_issues, ARRAY[]::text[]));
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_owner_ready_missing(text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_owner_ready_lock_reason(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_owner_ready_issue_prepend(text, text[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- Evaluate + stamp + inbox (internal)
-- state: not_active | no_owner | cleared | just_cleared | locked
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_refresh(
  p_club text,
  p_season bigint,
  p_notify boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_owner uuid;
  v_gate public.owner_ready_gate;
  v_missing text[];
  v_n int;
  v_body text;
BEGIN
  IF v_club IS NULL OR p_season IS NULL THEN
    RETURN jsonb_build_object('state', 'not_active');
  END IF;
  IF NOT public.gpsl_owner_ready_gate_active(p_season) THEN
    RETURN jsonb_build_object('state', 'not_active');
  END IF;

  SELECT c.owner_id INTO v_owner FROM public."Clubs" c WHERE upper(c."ShortName") = v_club;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('state', 'no_owner');
  END IF;

  SELECT * INTO v_gate
  FROM public.owner_ready_gate g
  WHERE upper(g.club_short_name) = v_club AND g.season_id = p_season;

  -- New owner since the stamp: start fresh
  IF FOUND AND v_gate.owner_id IS DISTINCT FROM v_owner THEN
    DELETE FROM public.owner_ready_gate g
    WHERE upper(g.club_short_name) = v_club AND g.season_id = p_season;
    v_gate := NULL;
  END IF;

  IF v_gate.cleared_at IS NOT NULL THEN
    RETURN jsonb_build_object('state', 'cleared', 'cleared_at', v_gate.cleared_at);
  END IF;

  v_missing := public.gpsl_owner_ready_missing(v_club, p_season);
  v_n := coalesce(array_length(v_missing, 1), 0);

  IF v_n = 0 THEN
    INSERT INTO public.owner_ready_gate (club_short_name, season_id, owner_id, cleared_at, cleared_by)
    VALUES (v_club, p_season, v_owner, now(), 'complete')
    ON CONFLICT (club_short_name, season_id)
    DO UPDATE SET owner_id = EXCLUDED.owner_id, cleared_at = now(), cleared_by = 'complete';

    IF v_gate.notified_at IS NOT NULL THEN
      BEGIN
        PERFORM public.owner_inbox_send(
          p_message_type => 'owner_ready_unlocked',
          p_title => '✅ Matches unlocked — checklist complete',
          p_body => E'Your Ready for August checklist is complete, so your club can now check in and play matches.\n\nThe checklist has been removed from your Dashboard. Good luck this season!',
          p_recipient_club => v_club,
          p_owner_id => v_owner,
          p_action_href => 'dashboard.html',
          p_dedupe_key => format('owner_ready_unlocked:%s:%s', p_season, v_club),
          p_season_id => p_season
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'owner_ready unlocked inbox failed for %: %', v_club, SQLERRM;
      END;
    END IF;

    RETURN jsonb_build_object('state', CASE WHEN v_gate.notified_at IS NOT NULL THEN 'just_cleared' ELSE 'cleared' END);
  END IF;

  IF p_notify AND v_gate.notified_at IS NULL THEN
    v_body := E'GPSL August has opened, but your Ready for August checklist is not complete yet.\n\n'
      || E'Until every required item is ticked, your club cannot check in or play matches. '
      || E'Missed check-ins are treated as no-shows, so please sort this quickly.\n\n'
      || E'Still to do:\n• ' || array_to_string(v_missing, E'\n• ')
      || E'\n\nOpen your Dashboard to see the checklist and fix each item. Matches unlock as soon as it is complete.';
    BEGIN
      PERFORM public.owner_inbox_send(
        p_message_type => 'owner_ready_locked',
        p_title => '⚠️ Complete your checklist to play matches',
        p_body => v_body,
        p_recipient_club => v_club,
        p_owner_id => v_owner,
        p_action_href => 'dashboard.html#seasonReadyPanel',
        p_dedupe_key => format('owner_ready_locked:%s:%s', p_season, v_club),
        p_season_id => p_season
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'owner_ready locked inbox failed for %: %', v_club, SQLERRM;
    END;

    INSERT INTO public.owner_ready_gate (club_short_name, season_id, owner_id, notified_at)
    VALUES (v_club, p_season, v_owner, now())
    ON CONFLICT (club_short_name, season_id)
    DO UPDATE SET owner_id = EXCLUDED.owner_id, notified_at = coalesce(public.owner_ready_gate.notified_at, now());
  END IF;

  RETURN jsonb_build_object('state', 'locked', 'missing', to_jsonb(v_missing), 'missing_count', v_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_owner_ready_refresh(text, bigint, boolean) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Owner dashboard panel
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_season_ready_checklist()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint := public.gpsl_owner_ready_current_season();
  v_aug timestamptz;
  v_state jsonb;
  v_items jsonb;
BEGIN
  IF v_club IS NULL OR v_season IS NULL THEN
    RETURN jsonb_build_object('visible', false);
  END IF;

  v_aug := public.gpsl_owner_ready_august_at(v_season);

  IF v_aug IS NOT NULL AND now() >= v_aug THEN
    v_state := public.gpsl_owner_ready_refresh(v_club, v_season, true);
    IF v_state->>'state' IN ('cleared', 'just_cleared', 'no_owner', 'not_active') THEN
      RETURN jsonb_build_object(
        'visible', false,
        'august_unlock_at', v_aug,
        'just_cleared', v_state->>'state' = 'just_cleared'
      );
    END IF;
  END IF;

  v_items := public.gpsl_owner_ready_items(v_club, v_season);

  RETURN jsonb_build_object(
    'visible', true,
    'locked', v_state IS NOT NULL AND v_state->>'state' = 'locked',
    'club_short_name', v_club,
    'season_id', v_season,
    'august_unlock_at', v_aug,
    'items', v_items
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_season_ready_checklist() TO authenticated;

-- ---------------------------------------------------------------------------
-- Site-wide warning banner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_ready_lock_status()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint := public.gpsl_owner_ready_current_season();
  v_state jsonb;
BEGIN
  IF v_club IS NULL OR v_season IS NULL THEN
    RETURN jsonb_build_object('locked', false);
  END IF;
  IF NOT public.gpsl_owner_ready_gate_active(v_season) THEN
    RETURN jsonb_build_object('locked', false);
  END IF;
  IF public.gpsl_owner_ready_is_cleared(v_club, v_season) THEN
    RETURN jsonb_build_object('locked', false);
  END IF;

  v_state := public.gpsl_owner_ready_refresh(v_club, v_season, true);
  RETURN jsonb_build_object(
    'locked', v_state->>'state' = 'locked',
    'just_cleared', v_state->>'state' = 'just_cleared',
    'missing_count', coalesce((v_state->>'missing_count')::int, 0),
    'missing', coalesce(v_state->'missing', '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_ready_lock_status() TO authenticated;

-- ---------------------------------------------------------------------------
-- Sweep: stamps / messages every owned club once August is open
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_owner_ready_gate_sweep()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpsl_owner_ready_current_season();
  c record;
  v_state jsonb;
  v_cleared int := 0;
  v_locked int := 0;
BEGIN
  IF v_season IS NULL OR NOT public.gpsl_owner_ready_gate_active(v_season) THEN
    RETURN jsonb_build_object('active', false);
  END IF;

  FOR c IN
    SELECT cl."ShortName" AS short
    FROM public."Clubs" cl
    WHERE cl.owner_id IS NOT NULL
      AND cl."ShortName" <> 'FOREIGN'
      AND NOT public.gpsl_owner_ready_is_cleared(cl."ShortName", v_season)
  LOOP
    BEGIN
      v_state := public.gpsl_owner_ready_refresh(c.short, v_season, true);
      IF v_state->>'state' IN ('cleared', 'just_cleared') THEN
        v_cleared := v_cleared + 1;
      ELSIF v_state->>'state' = 'locked' THEN
        v_locked := v_locked + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'owner_ready sweep failed for %: %', c.short, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object('active', true, 'newly_cleared', v_cleared, 'locked', v_locked);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_owner_ready_gate_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_owner_ready_gate_sweep() TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-owner-ready-gate-sweep');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-owner-ready-gate-sweep',
      '*/10 * * * *',
      $$SELECT public.gpsl_owner_ready_gate_sweep();$$
    );
  END IF;
END
$cron$;

-- ---------------------------------------------------------------------------
-- Admin override (e.g. item needs an admin, like the Discord tag)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_owner_ready_force_clear(
  p_club text,
  p_season bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_season bigint := coalesce(p_season, public.gpsl_owner_ready_current_season());
  v_owner uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT c.owner_id INTO v_owner FROM public."Clubs" c WHERE upper(c."ShortName") = v_club;
  IF NOT FOUND THEN RAISE EXCEPTION 'Club % not found', p_club; END IF;

  INSERT INTO public.owner_ready_gate (club_short_name, season_id, owner_id, cleared_at, cleared_by)
  VALUES (v_club, v_season, v_owner, now(), 'admin')
  ON CONFLICT (club_short_name, season_id)
  DO UPDATE SET owner_id = EXCLUDED.owner_id, cleared_at = now(), cleared_by = 'admin';

  RETURN jsonb_build_object('ok', true, 'club', v_club, 'season_id', v_season);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_owner_ready_force_clear(text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_ready_force_clear(text, bigint) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Check-in readiness: lock is the first issue (blocks fixture_check_in)
-- ---------------------------------------------------------------------------
DO $inject$
DECLARE
  v_oid oid := to_regprocedure('public.club_matchday_checkin_ready(bigint)');
  v_src text;
  v_needle text := 'RETURN jsonb_build_object(';
  v_hits int;
BEGIN
  IF v_oid IS NULL THEN
    RAISE WARNING 'club_matchday_checkin_ready(bigint) missing — check-in lock not wired';
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF position('gpsl_owner_ready_issue_prepend' IN v_src) > 0 THEN
    RAISE NOTICE 'club_matchday_checkin_ready already has the ready lock';
    RETURN;
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_needle, ''))) / length(v_needle);
  IF v_hits <> 1 THEN
    RAISE WARNING 'club_matchday_checkin_ready: expected 1 RETURN jsonb_build_object, found % — patch manually', v_hits;
    RETURN;
  END IF;

  EXECUTE replace(
    v_src,
    v_needle,
    'v_issues := public.gpsl_owner_ready_issue_prepend(v_club, v_issues);' || chr(10) || '  ' || v_needle
  );
END
$inject$;

NOTIFY pgrst, 'reload schema';

-- Report: wiring + each owned club's state right now (read-only, no stamping)
SELECT
  'check-in lock wired' AS what,
  (position('gpsl_owner_ready_issue_prepend' IN
     pg_get_functiondef('public.club_matchday_checkin_ready(bigint)'::regprocedure)) > 0)::text AS value
UNION ALL
SELECT 'august unlock_at', coalesce(public.gpsl_owner_ready_august_at(public.gpsl_owner_ready_current_season())::text, 'none')
UNION ALL
SELECT 'gate active now', public.gpsl_owner_ready_gate_active(public.gpsl_owner_ready_current_season())::text
UNION ALL
SELECT 'cron job', coalesce((SELECT schedule FROM cron.job WHERE jobname = 'gpsl-owner-ready-gate-sweep'), 'missing')
UNION ALL
SELECT 'club ' || cl."ShortName",
       CASE
         WHEN public.gpsl_owner_ready_is_cleared(cl."ShortName", public.gpsl_owner_ready_current_season()) THEN 'cleared'
         ELSE coalesce(array_length(public.gpsl_owner_ready_missing(cl."ShortName", public.gpsl_owner_ready_current_season()), 1), 0)::text
              || ' required item(s) missing'
       END
FROM public."Clubs" cl
WHERE cl.owner_id IS NOT NULL AND cl."ShortName" <> 'FOREIGN';
