-- =============================================================================
-- Discord #gpsl-results — daily digest by division + week (not per fixture)
--
-- Before: every played fixture enqueued one Discord notification immediately.
-- After: results wait for a daily tick; one post per (division × matchday) or
--        (cup × round) with new scores — far fewer owner notifications.
--
-- Clinch announcements (#gpsl-news) are unchanged.
--
-- Setup:
--   1) Run this patch
--   2) Optional: Admin → Discord News → “Publish results digest now”
--   3) Cron runs daily 20:00 UTC (approx evening UK)
--
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS discord_results_digested_at timestamptz;

COMMENT ON COLUMN public.competition_fixtures.discord_results_digested_at IS
  'When this result was included in a Discord #gpsl-results daily digest.';

-- Do not re-post the whole history on first digest run
UPDATE public.competition_fixtures
SET discord_results_digested_at = coalesce(discord_results_digested_at, now())
WHERE status = 'played'
  AND discord_results_digested_at IS NULL;

-- Drop any already-queued per-fixture result spam still pending
UPDATE public.gpsl_discord_feed_queue
SET status = 'skipped',
    last_error = 'Superseded by daily results digest (gpsl_discord_results_daily_digest)'
WHERE status IN ('pending', 'error', 'posting')
  AND event_type = 'result'
  AND dedupe_key LIKE 'fixture:%';

-- ---------------------------------------------------------------------------
-- Stop immediate per-fixture Discord results (keep clinch scan)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF NEW.home_goals IS NULL OR NEW.away_goals IS NULL THEN
    RETURN NEW;
  END IF;

  -- Results go via gpsl_discord_results_digest_tick() (daily, by division/week).
  -- Clinch scan after league results only.
  IF coalesce(NEW.competition_type, 'league') = 'league'
     AND nullif(btrim(coalesce(NEW.cup_code, '')), '') IS NULL THEN
    BEGIN
      PERFORM public.competition_process_league_clinches(NEW.season_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_fixture_played ON public.competition_fixtures;
CREATE TRIGGER trg_gpsl_discord_feed_fixture_played
  AFTER INSERT OR UPDATE OF status, home_goals, away_goals
  ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_fixture_played();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_results_division_label(p_division text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_division, '')))
    WHEN 'superleague' THEN 'SuperLeague'
    WHEN 'championship_a' THEN 'Championship A'
    WHEN 'championship_b' THEN 'Championship B'
    ELSE coalesce(nullif(initcap(replace(btrim(coalesce(p_division, '')), '_', ' ')), ''), 'League')
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_results_cup_label(p_cup_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_cup_code, '')))
    WHEN 'super8' THEN 'Super8'
    WHEN 'plate' THEN 'Plate'
    WHEN 'shield' THEN 'Shield'
    WHEN 'bowl' THEN 'Bowl'
    WHEN 'league_cup' THEN 'League Cup'
    WHEN 'spoon' THEN 'Bowl'
    ELSE coalesce(nullif(initcap(replace(btrim(coalesce(p_cup_code, '')), '_', ' ')), ''), 'Cup')
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_results_club_name(p_short text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
BEGIN
  SELECT c."Club" INTO v_name
  FROM public."Clubs" c
  WHERE c."ShortName" = p_short;
  RETURN coalesce(nullif(btrim(v_name), ''), nullif(btrim(p_short), ''), '?');
END;
$function$;

-- ---------------------------------------------------------------------------
-- Build + enqueue digests for undigested played fixtures
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_results_digest_tick(
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
  v_week_label text;
  v_comp_label text;
  v_pen text;
  v_qid bigint;
  v_ids bigint[];
  v_posted int := 0;
  v_fixtures int := 0;
  v_groups jsonb := '[]'::jsonb;
  v_dedupe text;
  v_day text := to_char((now() AT TIME ZONE 'Europe/London')::date, 'YYYY-MM-DD');
BEGIN
  FOR v_group IN
    WITH pending AS (
      SELECT
        f.id,
        f.season_id,
        f.home_club_short_name,
        f.away_club_short_name,
        f.home_goals,
        f.away_goals,
        f.cup_pen_winner_club_short_name,
        f.gpsl_month,
        CASE
          WHEN coalesce(f.competition_type, 'league') = 'cup'
            OR nullif(btrim(coalesce(f.cup_code, '')), '') IS NOT NULL
            THEN 'cup'
          ELSE 'league'
        END AS kind,
        CASE
          WHEN coalesce(f.competition_type, 'league') = 'cup'
            OR nullif(btrim(coalesce(f.cup_code, '')), '') IS NOT NULL
            THEN lower(btrim(f.cup_code))
          ELSE lower(btrim(coalesce(f.division, 'league')))
        END AS group_key,
        CASE
          WHEN coalesce(f.competition_type, 'league') = 'cup'
            OR nullif(btrim(coalesce(f.cup_code, '')), '') IS NOT NULL
            THEN coalesce(f.cup_round, 0)::int
          ELSE coalesce(f.matchday, f.week_in_month, 0)::int
        END AS week_no
      FROM public.competition_fixtures f
      WHERE f.status = 'played'
        AND f.home_goals IS NOT NULL
        AND f.away_goals IS NOT NULL
        AND f.discord_results_digested_at IS NULL
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    ),
    grouped AS (
      SELECT
        p.season_id,
        p.kind,
        p.group_key,
        p.week_no,
        coalesce(nullif(btrim(p.gpsl_month), ''), 'unknown') AS gpsl_month,
        array_agg(p.id ORDER BY p.id) AS fixture_ids,
        count(*)::int AS cnt,
        CASE p.kind WHEN 'league' THEN 0 ELSE 1 END AS kind_sort,
        CASE p.group_key
          WHEN 'superleague' THEN 1
          WHEN 'championship_a' THEN 2
          WHEN 'championship_b' THEN 3
          WHEN 'super8' THEN 10
          WHEN 'league_cup' THEN 11
          WHEN 'shield' THEN 12
          WHEN 'bowl' THEN 13
          WHEN 'plate' THEN 14
          ELSE 50
        END AS group_sort
      FROM pending p
      GROUP BY
        p.season_id,
        p.kind,
        p.group_key,
        p.week_no,
        coalesce(nullif(btrim(p.gpsl_month), ''), 'unknown')
    )
    SELECT *
    FROM grouped
    ORDER BY kind_sort, group_sort, week_no, gpsl_month
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

    IF v_group.kind = 'league' THEN
      v_comp_label := public.gpsl_discord_results_division_label(v_group.group_key);
      v_week_label := CASE
        WHEN v_group.week_no > 0 THEN 'Matchday ' || v_group.week_no::text
        ELSE 'Week'
      END;
    ELSE
      v_comp_label := public.gpsl_discord_results_cup_label(v_group.group_key);
      v_week_label := CASE
        WHEN v_group.week_no > 0 THEN 'Round ' || v_group.week_no::text
        ELSE 'Cup'
      END;
    END IF;

    FOR v_fx IN
      SELECT *
      FROM public.competition_fixtures f
      WHERE f.id = ANY (v_ids)
      ORDER BY f.id
    LOOP
      v_lines := v_lines
        || public.gpsl_discord_results_club_name(v_fx.home_club_short_name)
        || ' '
        || v_fx.home_goals::text
        || '–'
        || v_fx.away_goals::text
        || ' '
        || public.gpsl_discord_results_club_name(v_fx.away_club_short_name);

      IF nullif(btrim(coalesce(v_fx.cup_pen_winner_club_short_name, '')), '') IS NOT NULL THEN
        v_pen := public.gpsl_discord_results_club_name(v_fx.cup_pen_winner_club_short_name);
        v_lines := v_lines || ' (pens ' || v_pen || ')';
      END IF;

      v_lines := v_lines || E'\n';
    END LOOP;

    v_body := v_month_label || ' · ' || v_week_label || E'\n\n' || rtrim(v_lines);
    IF length(v_body) > 3900 THEN
      v_body := left(v_body, 3890) || E'\n…';
    END IF;

    v_headline := format(
      '📊 RESULTS — %s · %s',
      v_comp_label,
      v_week_label
    );

    v_dedupe := format(
      'results_digest:%s:%s:%s:%s:%s:%s',
      v_group.season_id,
      v_group.kind,
      v_group.group_key,
      v_group.week_no,
      v_day,
      v_ids[1]
    );
    v_qid := public.gpsl_discord_feed_enqueue(
      'result',
      v_headline,
      v_body,
      14747136,
      v_dedupe,
      jsonb_build_object(
        'channel', 'results',
        'digest', true,
        'kind', v_group.kind,
        'group_key', v_group.group_key,
        'week_no', v_group.week_no,
        'gpsl_month', v_group.gpsl_month,
        'fixture_ids', to_jsonb(v_ids),
        'fixture_count', v_group.cnt,
        'digest_day', v_day
      )
    );

    UPDATE public.competition_fixtures
    SET discord_results_digested_at = now()
    WHERE id = ANY (v_ids)
      AND discord_results_digested_at IS NULL;

    v_posted := v_posted + 1;
    v_fixtures := v_fixtures + v_group.cnt;
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object(
        'kind', v_group.kind,
        'group', v_comp_label,
        'week', v_week_label,
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

CREATE OR REPLACE FUNCTION public.admin_discord_results_digest_now(
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
  RETURN public.gpsl_discord_results_digest_tick(p_max_posts);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_results_digest_tick(int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_discord_results_digest_now(int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_results_division_label(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_results_cup_label(text) TO authenticated;

-- Daily cron (20:00 UTC). Unschedule prior job name if present.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-discord-results-digest');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-results-digest',
      '0 20 * * *',
      $$SELECT public.gpsl_discord_results_digest_tick(10);$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Manual now:
--   SELECT public.admin_discord_results_digest_now();
-- Then Push queue / wait for auto-flush.
-- =============================================================================
