-- =============================================================================
-- Match videos — editable payout + missing-video fine + owner-board metrics
--
-- Settings (Admin → Match videos):
--   payout_amount              default ₿200,000 (Matchday revenue)
--   missing_fine_amount        default ₿500,000 (Fines category)
--   missing_fine_grace_hours   default 48 (hours after GPSL month lock_at)
--
-- Fine rule:
--   For each *played* league/cup fixture in a locked GPSL month, each *owned*
--   side must have a fixture_match_videos row by lock_at + grace_hours.
--   Otherwise apply tariff match_video_missing (gov_fine_compensation).
--
-- Metrics (Season owner board):
--   video_late_count   — uploads matched after that month’s lock_at
--   video_failed_count — missing at grace deadline (recorded; stays if later upload)
--
-- Run after: match_video_uploads_cron_20260912.sql + score_verify / poster guard.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpsl_discord_match_videos_settings
  ADD COLUMN IF NOT EXISTS payout_amount numeric NOT NULL DEFAULT 200000,
  ADD COLUMN IF NOT EXISTS missing_fine_amount numeric NOT NULL DEFAULT 500000,
  ADD COLUMN IF NOT EXISTS missing_fine_grace_hours int NOT NULL DEFAULT 48;

UPDATE public.gpsl_discord_match_videos_settings
SET
  payout_amount = coalesce(nullif(payout_amount, 0), 200000),
  missing_fine_amount = coalesce(missing_fine_amount, 500000),
  missing_fine_grace_hours = greatest(1, coalesce(missing_fine_grace_hours, 48))
WHERE id = 1;

COMMENT ON COLUMN public.gpsl_discord_match_videos_settings.payout_amount IS
  '₿ credited once per club per fixture when their match video is matched.';
COMMENT ON COLUMN public.gpsl_discord_match_videos_settings.missing_fine_amount IS
  '₿ fine when an owned side has no video by lock_at + grace hours. 0 = fines off.';
COMMENT ON COLUMN public.gpsl_discord_match_videos_settings.missing_fine_grace_hours IS
  'Hours after GPSL month lock_at before a missing video is fined.';

-- ---------------------------------------------------------------------------
-- Amount helpers (settings-backed)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_payout_amount()
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v numeric;
BEGIN
  SELECT s.payout_amount INTO v
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;
  IF v IS NULL OR v <= 0 THEN
    RETURN 200000::numeric;
  END IF;
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_missing_fine_amount()
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v numeric;
BEGIN
  SELECT s.missing_fine_amount INTO v
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;
  RETURN greatest(0, coalesce(v, 0));
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_missing_fine_grace_hours()
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v int;
BEGIN
  SELECT s.missing_fine_grace_hours INTO v
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;
  RETURN greatest(1, coalesce(v, 48));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Failure ledger (season metrics; one row per fixture side)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fixture_match_video_failures (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures(id) ON DELETE CASCADE,
  side text NOT NULL CHECK (side IN ('home', 'away')),
  club_short_name text NOT NULL,
  gpsl_month text,
  assessed_at timestamptz NOT NULL DEFAULT now(),
  deadline_at timestamptz,
  fine_amount numeric NOT NULL DEFAULT 0,
  ledger_id bigint,
  fine_applied_id bigint,
  CONSTRAINT fixture_match_video_failures_fixture_side_uidx UNIQUE (fixture_id, side)
);

CREATE INDEX IF NOT EXISTS fixture_match_video_failures_season_club_idx
  ON public.fixture_match_video_failures (season_id, club_short_name);

ALTER TABLE public.fixture_match_video_failures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixture_match_video_failures_admin ON public.fixture_match_video_failures;
CREATE POLICY fixture_match_video_failures_admin
  ON public.fixture_match_video_failures
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.fixture_match_video_failures TO authenticated;
GRANT ALL ON public.fixture_match_video_failures TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.fixture_match_video_failures_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Fine tariff (amount overridden from settings at apply time)
-- ---------------------------------------------------------------------------
INSERT INTO public.competition_fine_tariff (
  code, label, category, direction, amount, amount_mode, sort_order, is_active
)
VALUES (
  'match_video_missing',
  'Missing match video',
  'matchday',
  'fine',
  500000,
  'manual',
  125,
  true
)
ON CONFLICT (code) DO UPDATE
SET
  label = EXCLUDED.label,
  category = EXCLUDED.category,
  direction = EXCLUDED.direction,
  amount_mode = EXCLUDED.amount_mode,
  is_active = true;

-- ---------------------------------------------------------------------------
-- Admin get / set money settings
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_match_video_get_amounts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  INSERT INTO public.gpsl_discord_match_videos_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  RETURN (
    SELECT jsonb_build_object(
      'ok', true,
      'payout_amount', s.payout_amount,
      'missing_fine_amount', s.missing_fine_amount,
      'missing_fine_grace_hours', s.missing_fine_grace_hours
    )
    FROM public.gpsl_discord_match_videos_settings s
    WHERE s.id = 1
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_match_video_set_amounts(
  p_payout_amount numeric DEFAULT NULL,
  p_missing_fine_amount numeric DEFAULT NULL,
  p_missing_fine_grace_hours int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_payout numeric;
  v_fine numeric;
  v_grace int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  INSERT INTO public.gpsl_discord_match_videos_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  SELECT payout_amount, missing_fine_amount, missing_fine_grace_hours
  INTO v_payout, v_fine, v_grace
  FROM public.gpsl_discord_match_videos_settings
  WHERE id = 1;

  IF p_payout_amount IS NOT NULL THEN
    IF p_payout_amount <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'payout_amount must be > 0');
    END IF;
    v_payout := round(p_payout_amount);
  END IF;

  IF p_missing_fine_amount IS NOT NULL THEN
    IF p_missing_fine_amount < 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_fine_amount must be >= 0');
    END IF;
    v_fine := round(p_missing_fine_amount);
  END IF;

  IF p_missing_fine_grace_hours IS NOT NULL THEN
    IF p_missing_fine_grace_hours < 1 OR p_missing_fine_grace_hours > 24 * 30 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'grace hours must be 1–720');
    END IF;
    v_grace := p_missing_fine_grace_hours;
  END IF;

  UPDATE public.gpsl_discord_match_videos_settings
  SET
    payout_amount = v_payout,
    missing_fine_amount = v_fine,
    missing_fine_grace_hours = v_grace,
    updated_at = now()
  WHERE id = 1;

  -- Keep tariff catalogue default in sync for display (apply still uses settings)
  UPDATE public.competition_fine_tariff
  SET amount = v_fine
  WHERE code = 'match_video_missing';

  RETURN public.admin_match_video_get_amounts();
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_video_get_amounts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_match_video_set_amounts(numeric, numeric, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_match_video_get_amounts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_match_video_set_amounts(numeric, numeric, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_match_video_get_amounts() TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_match_video_set_amounts(numeric, numeric, int) TO service_role;

-- ---------------------------------------------------------------------------
-- Assess missing-video fines (idempotent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_process_missing_fines(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_fine numeric := public.match_video_missing_fine_amount();
  v_grace int := public.match_video_missing_fine_grace_hours();
  v_r record;
  v_apply jsonb;
  v_fined int := 0;
  v_skipped int := 0;
  v_already int := 0;
  v_no_owner int := 0;
  v_deadline timestamptz;
  v_note text;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'No active season');
  END IF;

  IF v_fine <= 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'missing_fine_amount is 0 (fines off)',
      'fined', 0
    );
  END IF;

  FOR v_r IN
    SELECT
      f.id AS fixture_id,
      f.gpsl_month,
      f.home_club_short_name,
      f.away_club_short_name,
      cal.lock_at,
      side.side,
      side.club_short_name
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    CROSS JOIN LATERAL (
      VALUES
        ('home', upper(btrim(f.home_club_short_name))),
        ('away', upper(btrim(f.away_club_short_name)))
    ) AS side(side, club_short_name)
    WHERE f.season_id = v_season_id
      AND f.status = 'played'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND nullif(btrim(f.gpsl_month), '') IS NOT NULL
      AND cal.lock_at IS NOT NULL
      AND cal.lock_at <= now()
      AND cal.lock_at + make_interval(hours => v_grace) <= now()
      AND side.club_short_name IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE upper(btrim(c."ShortName")) = side.club_short_name
          AND c.owner_id IS NOT NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id
          AND v.side = side.side
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_video_failures fail
        WHERE fail.fixture_id = f.id
          AND fail.side = side.side
      )
  LOOP
    v_deadline := v_r.lock_at + make_interval(hours => v_grace);
    v_note := format(
      'No match video within %s h of %s month lock · fixture %s · %s',
      v_grace,
      coalesce(v_r.gpsl_month, '?'),
      v_r.fixture_id,
      v_r.side
    );

    BEGIN
      v_apply := public.competition_apply_club_fine_tariff(
        v_r.club_short_name,
        'match_video_missing',
        v_fine,
        v_note,
        v_r.fixture_id,
        v_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END;

    INSERT INTO public.fixture_match_video_failures (
      season_id, fixture_id, side, club_short_name, gpsl_month,
      assessed_at, deadline_at, fine_amount, ledger_id, fine_applied_id
    ) VALUES (
      v_season_id,
      v_r.fixture_id,
      v_r.side,
      v_r.club_short_name,
      v_r.gpsl_month,
      now(),
      v_deadline,
      v_fine,
      nullif(v_apply->>'ledger_id', '')::bigint,
      nullif(v_apply->>'applied_id', '')::bigint
    )
    ON CONFLICT (fixture_id, side) DO NOTHING;

    v_fined := v_fined + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'fine_amount', v_fine,
    'grace_hours', v_grace,
    'fined', v_fined,
    'already', v_already,
    'skipped_errors', v_skipped,
    'no_owner_skipped_note', v_no_owner
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_process_missing_fines(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_process_missing_fines(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_process_missing_fines(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Owner-board metrics (merge in admin UI by club_short_name)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_match_video_owner_metrics(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'season_id', null, 'by_club', '{}'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'by_club', coalesce(
      (
        WITH late AS (
          SELECT
            upper(btrim(v.club_short_name)) AS club,
            count(*)::int AS video_late_count
          FROM public.fixture_match_videos v
          JOIN public.competition_fixtures f ON f.id = v.fixture_id
          JOIN public.competition_season_calendar cal
            ON cal.season_id = f.season_id
           AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
          WHERE v.season_id = v_season_id
            AND cal.lock_at IS NOT NULL
            AND v.matched_at > cal.lock_at
          GROUP BY 1
        ),
        failed AS (
          SELECT
            upper(btrim(fail.club_short_name)) AS club,
            count(*)::int AS video_failed_count
          FROM public.fixture_match_video_failures fail
          WHERE fail.season_id = v_season_id
          GROUP BY 1
        ),
        clubs AS (
          SELECT club FROM late
          UNION
          SELECT club FROM failed
        )
        SELECT jsonb_object_agg(
          c.club,
          jsonb_build_object(
            'video_late_count', coalesce(l.video_late_count, 0),
            'video_failed_count', coalesce(f.video_failed_count, 0)
          )
        )
        FROM clubs c
        LEFT JOIN late l ON l.club = c.club
        LEFT JOIN failed f ON f.club = c.club
      ),
      '{}'::jsonb
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_video_owner_metrics(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_match_video_owner_metrics(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_match_video_owner_metrics(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Extend auto-poll get/set to include amounts (non-breaking extras)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_discord_match_videos_get_auto()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_url text;
  v_enabled boolean;
  v_key text;
  v_payout numeric;
  v_fine numeric;
  v_grace int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  INSERT INTO public.gpsl_discord_match_videos_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  SELECT
    s.edge_function_url,
    s.auto_poll_enabled,
    s.invoke_key,
    s.payout_amount,
    s.missing_fine_amount,
    s.missing_fine_grace_hours
  INTO v_url, v_enabled, v_key, v_payout, v_fine, v_grace
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'edge_function_url', v_url,
    'auto_poll_enabled', coalesce(v_enabled, false),
    'has_key', nullif(btrim(coalesce(v_key, '')), '') IS NOT NULL,
    'payout_amount', coalesce(v_payout, 200000),
    'missing_fine_amount', coalesce(v_fine, 500000),
    'missing_fine_grace_hours', coalesce(v_grace, 48)
  );
END;
$function$;

-- Run missing-video fines from the Discord poll cron (after invoke)
CREATE OR REPLACE FUNCTION public.gpsl_discord_match_videos_request_poll()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_enabled boolean;
  v_url text;
  v_key text;
BEGIN
  SELECT auto_poll_enabled, edge_function_url, invoke_key
  INTO v_enabled, v_url, v_key
  FROM public.gpsl_discord_match_videos_settings
  WHERE id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN;
  END IF;
  IF nullif(btrim(coalesce(v_url, '')), '') IS NULL THEN
    RETURN;
  END IF;
  IF nullif(btrim(coalesce(v_key, '')), '') IS NULL THEN
    RETURN;
  END IF;

  BEGIN
    PERFORM net.http_post(
      url := v_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_key
      ),
      body := jsonb_build_object('limit', 40, 'poll', true),
      timeout_milliseconds := 55000
    );
  EXCEPTION
    WHEN undefined_function THEN
      RAISE WARNING 'gpsl_discord_match_videos_request_poll: pg_net missing';
    WHEN OTHERS THEN
      RAISE WARNING 'gpsl_discord_match_videos_request_poll failed: %', SQLERRM;
  END;

  BEGIN
    PERFORM public.match_video_process_missing_fines(NULL);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'match_video_process_missing_fines: %', SQLERRM;
  END;
END;
$function$;

NOTIFY pgrst, 'reload schema';
