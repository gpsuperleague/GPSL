-- =============================================================================
-- Discord: international results → #gpsl-intl-results (separate from club)
--
-- Club league/cup digests stay on #gpsl-results.
-- International played fixtures digest daily into #gpsl-intl-results.
--
-- Setup:
-- 1) Discord → create #gpsl-intl-results → Webhooks → copy URL
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_INTL_RESULTS_WEBHOOK_URL = that webhook
-- 3) Run this SQL
-- 4) Redeploy: supabase functions deploy discord-sky-feed
--
-- Cron: same evening tick as club results (20:00 UTC). Safe re-run.
-- =============================================================================

ALTER TABLE public.international_fixtures
  ADD COLUMN IF NOT EXISTS discord_results_digested_at timestamptz;

COMMENT ON COLUMN public.international_fixtures.discord_results_digested_at IS
  'When this intl result was included in a Discord #gpsl-intl-results daily digest.';

-- Do not dump historic results on first run
UPDATE public.international_fixtures
SET discord_results_digested_at = coalesce(discord_results_digested_at, now())
WHERE (coalesce(played, false) = true OR coalesce(status, '') = 'played')
  AND discord_results_digested_at IS NULL
  AND home_goals IS NOT NULL
  AND away_goals IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Enqueue helper
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_intl_result(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 14747136, -- 0xe10600
  p_dedupe_key text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.gpsl_discord_feed_enqueue(
    coalesce(nullif(btrim(p_event_type), ''), 'intl_result'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'intl_results')
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_intl_result(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Daily digest tick (group by phase × GPSL month)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_intl_results_digest_tick(
  p_max_posts int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int := greatest(1, least(coalesce(p_max_posts, 10), 20));
  v_group record;
  v_fx record;
  v_lines text;
  v_body text;
  v_headline text;
  v_month_label text;
  v_phase_label text;
  v_home text;
  v_away text;
  v_score text;
  v_qid bigint;
  v_ids bigint[];
  v_posted int := 0;
  v_fixtures int := 0;
  v_groups jsonb := '[]'::jsonb;
  v_dedupe text;
  v_day text := to_char((now() AT TIME ZONE 'Europe/London')::date, 'YYYY-MM-DD');
BEGIN
  IF to_regclass('public.international_fixtures') IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'posts_queued', 0, 'reason', 'no_intl_table');
  END IF;

  FOR v_group IN
    WITH pending AS (
      SELECT
        f.id,
        f.season_id,
        f.home_nation,
        f.away_nation,
        f.home_goals,
        f.away_goals,
        f.gpsl_month,
        coalesce(nullif(btrim(f.phase), ''), 'international') AS phase_key
      FROM public.international_fixtures f
      WHERE (coalesce(f.played, false) = true OR coalesce(f.status, '') = 'played')
        AND f.home_goals IS NOT NULL
        AND f.away_goals IS NOT NULL
        AND f.discord_results_digested_at IS NULL
    ),
    grouped AS (
      SELECT
        p.season_id,
        p.phase_key,
        coalesce(nullif(btrim(p.gpsl_month), ''), 'unknown') AS gpsl_month,
        array_agg(p.id ORDER BY p.id) AS fixture_ids,
        count(*)::int AS cnt,
        CASE lower(p.phase_key)
          WHEN 'qualifying' THEN 1
          WHEN 'finals_group' THEN 2
          WHEN 'knockout' THEN 3
          WHEN 'final' THEN 4
          ELSE 50
        END AS phase_sort
      FROM pending p
      GROUP BY
        p.season_id,
        p.phase_key,
        coalesce(nullif(btrim(p.gpsl_month), ''), 'unknown')
    )
    SELECT *
    FROM grouped
    ORDER BY phase_sort, gpsl_month
    LIMIT v_max
  LOOP
    v_ids := v_group.fixture_ids;
    v_lines := '';

    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_group.gpsl_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_group.gpsl_month);
    END;
    v_month_label := coalesce(nullif(btrim(v_month_label), ''), initcap(v_group.gpsl_month), 'Month');

    BEGIN
      v_phase_label := public.international_fixture_phase_label(v_group.phase_key);
    EXCEPTION WHEN OTHERS THEN
      v_phase_label := initcap(replace(v_group.phase_key, '_', ' '));
    END;
    v_phase_label := coalesce(nullif(btrim(v_phase_label), ''), 'International');

    FOR v_fx IN
      SELECT
        f.*,
        s.home_goals_et,
        s.away_goals_et,
        s.home_pens,
        s.away_pens
      FROM public.international_fixtures f
      LEFT JOIN LATERAL (
        SELECT sub.home_goals_et, sub.away_goals_et, sub.home_pens, sub.away_pens
        FROM public.international_result_submissions sub
        WHERE sub.fixture_id = f.id
          AND sub.status = 'confirmed'
        ORDER BY sub.resolved_at DESC NULLS LAST, sub.id DESC
        LIMIT 1
      ) s ON true
      WHERE f.id = ANY (v_ids)
      ORDER BY f.id
    LOOP
      BEGIN
        v_home := public.international_nation_display_name(v_fx.home_nation);
      EXCEPTION WHEN OTHERS THEN
        v_home := v_fx.home_nation;
      END;
      BEGIN
        v_away := public.international_nation_display_name(v_fx.away_nation);
      EXCEPTION WHEN OTHERS THEN
        v_away := v_fx.away_nation;
      END;
      v_home := coalesce(nullif(btrim(v_home), ''), v_fx.home_nation, 'Home');
      v_away := coalesce(nullif(btrim(v_away), ''), v_fx.away_nation, 'Away');

      IF v_fx.home_goals_et IS NOT NULL AND v_fx.away_goals_et IS NOT NULL THEN
        v_score := v_fx.home_goals_et::text || '–' || v_fx.away_goals_et::text || ' aet';
        IF v_fx.home_pens IS NOT NULL AND v_fx.away_pens IS NOT NULL THEN
          v_score := v_score
            || ' (' || v_fx.home_pens::text || '–' || v_fx.away_pens::text || ' pens)';
        END IF;
      ELSE
        v_score := v_fx.home_goals::text || '–' || v_fx.away_goals::text;
      END IF;

      v_lines := v_lines || v_home || ' ' || v_score || ' ' || v_away || E'\n';
    END LOOP;

    v_body := v_month_label || ' · ' || v_phase_label || E'\n\n' || rtrim(v_lines);
    IF length(v_body) > 3900 THEN
      v_body := left(v_body, 3890) || E'\n…';
    END IF;

    v_headline := format('🌍 INTL RESULTS — %s', v_phase_label);

    v_dedupe := format(
      'intl_results_digest:%s:%s:%s:%s:%s',
      coalesce(v_group.season_id::text, '0'),
      v_group.phase_key,
      v_group.gpsl_month,
      v_day,
      v_ids[1]
    );

    v_qid := public.gpsl_discord_feed_enqueue_intl_result(
      'intl_result',
      v_headline,
      v_body,
      14747136,
      v_dedupe,
      jsonb_build_object(
        'digest', true,
        'phase', v_group.phase_key,
        'gpsl_month', v_group.gpsl_month,
        'fixture_ids', to_jsonb(v_ids),
        'fixture_count', v_group.cnt,
        'digest_day', v_day
      )
    );

    UPDATE public.international_fixtures
    SET discord_results_digested_at = now()
    WHERE id = ANY (v_ids)
      AND discord_results_digested_at IS NULL;

    v_posted := v_posted + 1;
    v_fixtures := v_fixtures + v_group.cnt;
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object(
        'phase', v_phase_label,
        'month', v_month_label,
        'fixtures', v_group.cnt,
        'queue_id', v_qid,
        'dedupe_key', v_dedupe
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'digest_day', v_day,
    'posts_queued', v_posted,
    'fixtures_marked', v_fixtures,
    'max_posts', v_max,
    'groups', v_groups
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_intl_results_digest_now(
  p_max_posts int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpsl_discord_intl_results_digest_tick(p_max_posts);
END;
$function$;

-- Combined admin helper: club + intl digests in one click
CREATE OR REPLACE FUNCTION public.admin_discord_all_results_digest_now(
  p_max_posts int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club jsonb;
  v_intl jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_club := public.gpsl_discord_results_digest_tick(p_max_posts);

  BEGIN
    v_intl := public.gpsl_discord_intl_results_digest_tick(p_max_posts);
  EXCEPTION WHEN OTHERS THEN
    v_intl := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'intl', v_intl,
    'posts_queued',
      coalesce((v_club ->> 'posts_queued')::int, 0)
      + coalesce((v_intl ->> 'posts_queued')::int, 0),
    'fixtures_marked',
      coalesce((v_club ->> 'fixtures_marked')::int, 0)
      + coalesce((v_intl ->> 'fixtures_marked')::int, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_intl_results_digest_tick(int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_discord_intl_results_digest_now(int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_discord_all_results_digest_now(int)
  TO authenticated, service_role;

-- Same evening cron as club results: also digest intl
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-discord-intl-results-digest');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-intl-results-digest',
      '0 20 * * *',
      $$SELECT public.gpsl_discord_intl_results_digest_tick(10);$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron intl results schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- Manual:
--   SELECT public.admin_discord_intl_results_digest_now();
--   SELECT public.admin_discord_all_results_digest_now();
-- Then Push queue / wait for auto-flush.
