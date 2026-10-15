-- =============================================================================
-- Friendlies table → Discord, every evening at 21:00 UK (2026-10-15)
--
-- • Posts the live monthly friendlies table (current GPSL month, June → May)
--   to #gpsl-news via the discord-sky-feed queue (metadata.channel =
--   'friendlies_table'; DISCORD_FRIENDLIES_TABLE_WEBHOOK_URL, if ever set,
--   moves it to its own channel).
-- • Once a month's prizes are paid (month lock), the next 21:00 run also posts
--   that month's FINAL table with the winners. Once per month.
-- • Cron at 20:00 and 21:00 UTC; only the run landing on 21:xx UK posts, so it
--   stays at 9pm through BST/GMT. Dedupe per UK date.
-- • Admin: SELECT public.admin_discord_friendlies_table_post_now();
-- Requires friendlies_monthly_table_20261015.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_table_discord_body(
  p_season_id bigint,
  p_gpsl_month text,
  p_limit int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_lines text;
  v_rows int := 0;
  v_min int := public.gpsl_friendlies_table_min_games();
  v_prizes numeric[] := public.gpsl_friendlies_table_prizes();
BEGIN
  SELECT count(*)::int,
         string_agg(
           lpad(t.place::text, 2) || '  ' ||
           rpad(t.club, 5) ||
           lpad(t.counted::text, 3) || '  ' ||
           rpad(t.won || '-' || t.drawn || '-' || t.lost, 8) ||
           lpad(to_char(t.avg_difficulty, 'FM0.0'), 4) ||
           lpad(to_char(t.points, 'FM9990.0'), 7) ||
           CASE WHEN t.qualified THEN '' ELSE ' *' END,
           E'\n' ORDER BY t.place
         )
  INTO v_rows, v_lines
  FROM public.gpsl_friendlies_month_table_rows(p_season_id, p_gpsl_month) t
  WHERE t.place <= greatest(coalesce(p_limit, 20), 1);

  IF coalesce(v_rows, 0) = 0 THEN
    RETURN jsonb_build_object('rows', 0, 'body', NULL);
  END IF;

  RETURN jsonb_build_object(
    'rows', v_rows,
    'body',
      '```' || E'\n' ||
      ' #  Club    G  W-D-L   Dif    Pts' || E'\n' ||
      v_lines || E'\n' ||
      '```' || E'\n' ||
      format('🏆 Month prize: 1st **₿%s**, 2nd **₿%s** to the owner account.',
             to_char(v_prizes[1], 'FM999,999,999'), to_char(v_prizes[2], 'FM999,999,999')) || E'\n' ||
      format('G = counted friendlies (first 2 per opponent each month, max %s). Dif = average opponent difficulty (1–5). * = needs %s+ games to win a prize.',
             public.gpsl_friendlies_month_cap(), v_min)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_table_discord_body(bigint, text, int) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_table_discord_post(
  p_dedupe_key text,
  p_manual boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_active text;
  v_body jsonb;
  v_qid bigint;
  v_final_qid bigint;
  v_final record;
  v_winners text;
  v_label text;
  v_out jsonb := '{}'::jsonb;
BEGIN
  v_season := public.gpsl_friendlies_live_season_id();
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;
  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No current season');
  END IF;

  -- 1) FINAL table for the latest month whose prizes were paid (once per month)
  SELECT p.gpsl_month, max(p.created_at) AS paid_at
  INTO v_final
  FROM public.gpsl_friendlies_prize_payouts p
  WHERE p.season_id = v_season
  GROUP BY p.gpsl_month
  ORDER BY max(p.created_at) DESC
  LIMIT 1;

  IF v_final.gpsl_month IS NOT NULL THEN
    v_label := coalesce(public.competition_gpsl_month_label(v_final.gpsl_month), initcap(v_final.gpsl_month));
    v_body := public.gpsl_friendlies_table_discord_body(v_season, v_final.gpsl_month, 20);

    SELECT string_agg(
             format('%s **%s** · %s pts · ₿%s',
                    CASE p.place WHEN 1 THEN '🥇' WHEN 2 THEN '🥈' ELSE '🏅' END,
                    coalesce(nullif(btrim(c."Club"), ''), p.club_short_name),
                    to_char(p.points, 'FM9990.0'),
                    to_char(p.amount, 'FM999,999,999')),
             E'\n' ORDER BY p.place)
    INTO v_winners
    FROM public.gpsl_friendlies_prize_payouts p
    LEFT JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
    WHERE p.season_id = v_season AND p.gpsl_month = v_final.gpsl_month;

    IF v_body->>'body' IS NOT NULL THEN
      v_final_qid := public.gpsl_discord_feed_enqueue(
        'friendlies_table',
        format('🤝 FRIENDLIES TABLE — %s FINAL', upper(v_label)),
        left(coalesce(v_winners || E'\n\n', '') || (v_body->>'body'), 3900),
        15844367,
        format('friendlies_table_final:%s:%s', v_season, v_final.gpsl_month),
        jsonb_build_object('channel', 'friendlies_table', 'kind', 'friendlies_table_final',
                           'season_id', v_season, 'gpsl_month', v_final.gpsl_month)
      );
    END IF;
  END IF;
  v_out := v_out || jsonb_build_object('final_queue_id', v_final_qid);
  IF v_final_qid IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_discord_feed_request_flush();
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  -- 2) Live table for the current month
  v_active := lower(public.competition_active_gpsl_month(v_season, now()));
  IF v_active IS NULL OR v_active = 'playoffs' THEN
    RETURN v_out || jsonb_build_object('ok', true, 'posted', false, 'reason', 'no active friendlies month');
  END IF;

  -- Month already paid out (locked early) — the final post covers it
  IF EXISTS (
    SELECT 1 FROM public.gpsl_friendlies_prize_payouts p
    WHERE p.season_id = v_season AND p.gpsl_month = v_active
  ) THEN
    RETURN v_out || jsonb_build_object('ok', true, 'posted', false, 'reason', 'month already final');
  END IF;

  v_body := public.gpsl_friendlies_table_discord_body(v_season, v_active, 20);
  IF v_body->>'body' IS NULL THEN
    RETURN v_out || jsonb_build_object('ok', true, 'posted', false, 'reason', 'no friendlies this month yet');
  END IF;

  v_label := coalesce(public.competition_gpsl_month_label(v_active), initcap(v_active));
  v_qid := public.gpsl_discord_feed_enqueue(
    'friendlies_table',
    format('🤝 FRIENDLIES TABLE — %s (live)', upper(v_label)),
    left(v_body->>'body', 3900),
    3066993,
    p_dedupe_key,
    jsonb_build_object('channel', 'friendlies_table', 'kind', 'friendlies_table_live',
                       'season_id', v_season, 'gpsl_month', v_active,
                       'manual', coalesce(p_manual, false))
  );

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_out || jsonb_build_object(
    'ok', true, 'posted', v_qid IS NOT NULL, 'queue_id', v_qid,
    'gpsl_month', v_active, 'rows', (v_body->>'rows')::int
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_table_discord_post(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_table_discord_post(text, boolean) TO service_role;

-- Daily 21:00 UK
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_table_discord_daily_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uk timestamp := now() AT TIME ZONE 'Europe/London';
BEGIN
  IF extract(hour FROM v_uk) <> 21 THEN
    RETURN jsonb_build_object('ok', true, 'posted', false, 'reason', 'not 21:00 UK');
  END IF;
  RETURN public.gpsl_friendlies_table_discord_post(
    'friendlies_table_daily:' || to_char(v_uk::date, 'YYYY-MM-DD'),
    false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_table_discord_daily_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_table_discord_daily_tick() TO service_role;

-- Admin: post now
CREATE OR REPLACE FUNCTION public.admin_discord_friendlies_table_post_now()
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
  RETURN public.gpsl_friendlies_table_discord_post(
    'friendlies_table_now:' || floor(extract(epoch FROM now()))::bigint::text,
    true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_friendlies_table_post_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_discord_friendlies_table_post_now() TO authenticated, service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-discord-friendlies-table-daily');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-friendlies-table-daily',
      '0 20,21 * * *',
      $$SELECT public.gpsl_friendlies_table_discord_daily_tick();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- Report: cron job + a preview of tonight's post
SELECT
  (SELECT schedule FROM cron.job WHERE jobname = 'gpsl-discord-friendlies-table-daily') AS cron_schedule,
  m.gpsl_month AS live_month,
  public.gpsl_friendlies_table_discord_body(m.season_id, m.gpsl_month, 20)->>'body' AS preview
FROM (
  SELECT s.id AS season_id, lower(public.competition_active_gpsl_month(s.id, now())) AS gpsl_month
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1
) m;
