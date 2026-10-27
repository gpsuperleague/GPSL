-- =============================================================================
-- Friendlies month prizes — durable auto-pay + #gpsl-news winners
--
-- • Catch-up pays every locked month still missing prize rows
-- • Soft-wires catch-up into month-lock jobs
-- • Announces 1st / 2nd in Discord #gpsl-news when prizes are paid
-- • Backfills June + July news posts (dedupe-safe)
--
-- Safe re-run. Does NOT require friendlies_table_discord_daily.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Announce winners → #gpsl-news
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_announce_month_winners(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_label text;
  v_body text;
  v_qid bigint;
  v_n int;
BEGIN
  IF p_season_id IS NULL OR v_month = '' OR v_month = 'playoffs' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_args');
  END IF;

  IF to_regprocedure('public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'discord_enqueue_missing');
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.gpsl_friendlies_prize_payouts p
  WHERE p.season_id = p_season_id AND p.gpsl_month = v_month;

  IF coalesce(v_n, 0) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_payouts');
  END IF;

  v_label := coalesce(public.competition_gpsl_month_label(v_month), initcap(v_month));

  SELECT string_agg(
           format('%s **%s**%s · %s pts · **₿%s**',
                  CASE p.place WHEN 1 THEN '🥇' WHEN 2 THEN '🥈' ELSE '🏅' END,
                  coalesce(nullif(btrim(c."Club"), ''), p.club_short_name),
                  CASE
                    WHEN nullif(btrim(c."ShortName"), '') IS NOT NULL
                      THEN format(' (%s)', c."ShortName")
                    ELSE ''
                  END,
                  to_char(p.points, 'FM9990.0'),
                  to_char(p.amount, 'FM999,999,999')),
           E'\n' ORDER BY p.place)
  INTO v_body
  FROM public.gpsl_friendlies_prize_payouts p
  LEFT JOIN public."Clubs" c ON upper(c."ShortName") = upper(p.club_short_name)
  WHERE p.season_id = p_season_id AND p.gpsl_month = v_month;

  v_body := coalesce(v_body, '') || E'\n\nPaid to the owners'' accounts. Gate money from friendlies is separate.';

  v_qid := public.gpsl_discord_feed_enqueue(
    'friendlies_winners',
    format('🏆 FRIENDLIES TABLE — %s WINNERS', upper(v_label)),
    left(v_body, 3900),
    15844367,
    format('friendlies_winners_news:%s:%s', p_season_id, v_month),
    jsonb_build_object(
      'channel', 'news',
      'kind', 'friendlies_winners',
      'season_id', p_season_id,
      'gpsl_month', v_month
    )
  );

  IF v_qid IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_discord_feed_request_flush();
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'queue_id', v_qid,
    'posted', v_qid IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_announce_month_winners(bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_announce_month_winners(bigint, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Pay one month (idempotent) + announce when anything new was paid
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_pay_month_prizes_internal(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_prizes numeric[] := public.gpsl_friendlies_table_prizes();
  v_place int := 0;
  v_paid int := 0;
  v_skipped int := 0;
  v_total numeric := 0;
  v_ledger bigint;
  v_label text;
  v_announce jsonb;
  r record;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;
  IF v_month = '' OR v_month = 'playoffs' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'not_a_prize_month', 'gpsl_month', v_month);
  END IF;

  PERFORM public.gpsl_friendlies_fill_difficulty(p_season_id, v_month);

  v_label := coalesce(public.competition_gpsl_month_label(v_month), initcap(v_month));

  FOR r IN
    SELECT t.*
    FROM public.gpsl_friendlies_month_table_rows(p_season_id, v_month) t
    WHERE t.qualified AND t.owner_id IS NOT NULL
    ORDER BY t.place
  LOOP
    v_place := v_place + 1;
    EXIT WHEN v_place > coalesce(array_length(v_prizes, 1), 0);

    IF EXISTS (
      SELECT 1 FROM public.gpsl_friendlies_prize_payouts p
      WHERE p.season_id = p_season_id AND p.gpsl_month = v_month AND p.place = v_place
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_ledger := public._post_owner_ledger_internal(
      r.owner_id,
      'friendlies_prize',
      v_prizes[v_place],
      format('Friendlies table — %s place, %s (%s, %s pts)',
        CASE v_place WHEN 1 THEN '1st' WHEN 2 THEN '2nd' ELSE v_place::text || 'th' END,
        v_label,
        r.club,
        to_char(r.points, 'FM999990.0')),
      jsonb_build_object(
        'source', 'friendlies_month_table',
        'season_id', p_season_id,
        'gpsl_month', v_month,
        'place', v_place,
        'club', r.club,
        'points', r.points
      ),
      p_season_id,
      true
    );

    INSERT INTO public.gpsl_friendlies_prize_payouts (
      season_id, gpsl_month, place, club_short_name, owner_id, amount, points, owner_ledger_id
    )
    VALUES (
      p_season_id, v_month, v_place, r.club, r.owner_id, v_prizes[v_place], r.points, v_ledger
    );

    v_paid := v_paid + 1;
    v_total := v_total + v_prizes[v_place];
  END LOOP;

  -- News post whenever this month has winners (new pay or already paid — dedupe key)
  BEGIN
    v_announce := public.gpsl_friendlies_announce_month_winners(p_season_id, v_month);
  EXCEPTION WHEN OTHERS THEN
    v_announce := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'season_id', p_season_id,
    'paid', v_paid,
    'skipped', v_skipped,
    'total_amount', v_total,
    'announce', v_announce
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_pay_month_prizes_internal(bigint, text)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Catch-up: every locked month still missing payouts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_pay_locked_months_catchup(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_month text;
  v_lock timestamptz;
  v_result jsonb;
  v_paid jsonb := '[]'::jsonb;
  v_n int := 0;
BEGIN
  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOREACH v_month IN ARRAY ARRAY[
    'june','july','august','september','october','november','december',
    'january','february','march','april','may'
  ]
  LOOP
    SELECT cal.lock_at INTO v_lock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season
      AND lower(btrim(cal.gpsl_month)) = v_month
    LIMIT 1;

    IF v_lock IS NULL OR v_lock > now() THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.gpsl_friendlies_prize_payouts p
      WHERE p.season_id = v_season
        AND p.gpsl_month = v_month
    ) THEN
      CONTINUE;
    END IF;

    v_result := public.gpsl_friendlies_pay_month_prizes_internal(v_season, v_month);
    v_n := v_n + 1;
    v_paid := v_paid || jsonb_build_array(
      jsonb_build_object('gpsl_month', v_month, 'result', v_result)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'months_attempted', v_n,
    'paid', v_paid
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_pay_locked_months_catchup(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_pay_locked_months_catchup(bigint)
  TO service_role;

CREATE OR REPLACE FUNCTION public.admin_gpsl_friendlies_pay_locked_months_catchup(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpsl_friendlies_pay_locked_months_catchup(p_season_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_gpsl_friendlies_pay_locked_months_catchup(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_gpsl_friendlies_pay_locked_months_catchup(bigint)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_gpsl_friendlies_announce_month_winners(
  p_gpsl_month text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  RETURN public.gpsl_friendlies_announce_month_winners(v_season, p_gpsl_month);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_gpsl_friendlies_announce_month_winners(text, bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_gpsl_friendlies_announce_month_winners(text, bigint)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Soft-wire catch-up into month-lock jobs
-- ---------------------------------------------------------------------------
DO $wire$
DECLARE
  v_oid oid;
  v_def text;
  v_marker text := 'gpsl_friendlies_pay_locked_months_catchup';
  v_insert text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs missing — friendlies catch-up wire skipped';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_def := replace(replace(v_def, E'\r\n', E'\n'), E'\r', E'\n');

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Friendlies locked-months catch-up already wired into month-lock jobs';
    RETURN;
  END IF;

  v_insert :=
    E'  -- Friendlies table prizes: pay any locked month still missing payouts\n'
    || E'  IF coalesce(nullif(v_stage, ''''), ''all'') IN (\n'
    || E'       ''all'', ''tables'', ''league_tables'', ''awards'', ''friendlies'', ''scheduling''\n'
    || E'     )\n'
    || E'  THEN\n'
    || E'    BEGIN\n'
    || E'      IF to_regprocedure(''public.gpsl_friendlies_pay_locked_months_catchup(bigint)'') IS NOT NULL THEN\n'
    || E'        v_out := v_out || jsonb_build_object(\n'
    || E'          ''friendlies_prizes_catchup'',\n'
    || E'          public.gpsl_friendlies_pay_locked_months_catchup(p_season_id)\n'
    || E'        );\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''friendlies_prizes_catchup'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'    END;\n'
    || E'  END IF;\n\n';

  IF v_def !~ E'RETURN v_out;[[:space:]]*END;[[:space:]]*\\$function\\$[[:space:]]*$' THEN
    RAISE EXCEPTION
      'Could not wire friendlies catch-up — RETURN v_out ending not found. Tail:%',
      chr(10) || right(v_def, 500);
  END IF;

  v_new := regexp_replace(
    v_def,
    E'RETURN v_out;[[:space:]]*END;[[:space:]]*\\$function\\$[[:space:]]*$',
    v_insert || E'  RETURN v_out;\n\nEND;\n$function$\n'
  );

  IF v_new IS NOT DISTINCT FROM v_def OR position(v_marker IN v_new) = 0 THEN
    RAISE EXCEPTION 'Wire replace did not insert friendlies catch-up marker';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'Wired friendlies locked-months catch-up into competition_run_month_lock_jobs';
END;
$wire$;

-- ---------------------------------------------------------------------------
-- Backfill: #gpsl-news for June + July (already paid; dedupe-safe)
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
  v_season bigint;
  v_month text;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE NOTICE 'No current season — winners backfill skipped';
    RETURN;
  END IF;

  FOREACH v_month IN ARRAY ARRAY['june', 'july']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.gpsl_friendlies_prize_payouts p
      WHERE p.season_id = v_season AND p.gpsl_month = v_month
    ) THEN
      v_results := v_results || jsonb_build_array(
        jsonb_build_object('gpsl_month', v_month, 'skipped', true, 'reason', 'no_payouts')
      );
      CONTINUE;
    END IF;

    v_result := public.gpsl_friendlies_announce_month_winners(v_season, v_month);
    v_results := v_results || jsonb_build_array(v_result);
  END LOOP;

  RAISE NOTICE 'Friendlies winners news backfill: %', v_results;
END;
$backfill$;

NOTIFY pgrst, 'reload schema';

-- Verify (safe if optional functions are missing — no ::regprocedure casts)
SELECT
  (to_regprocedure('public.gpsl_friendlies_pay_locked_months_catchup(bigint)') IS NOT NULL)
    AS catchup_fn,
  (to_regprocedure('public.gpsl_friendlies_announce_month_winners(bigint,text)') IS NOT NULL)
    AS announce_fn,
  COALESCE(
    (
      SELECT position('gpsl_friendlies_pay_locked_months_catchup' IN pg_get_functiondef(oid)) > 0
      FROM (SELECT to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') AS oid) s
      WHERE oid IS NOT NULL
    ),
    false
  ) AS wired_month_lock,
  (
    SELECT jsonb_agg(jsonb_build_object(
      'month', p.gpsl_month,
      'place', p.place,
      'club', p.club_short_name,
      'amount', p.amount
    ) ORDER BY p.gpsl_month, p.place)
    FROM public.gpsl_friendlies_prize_payouts p
    WHERE p.season_id = (
      SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
    )
      AND p.gpsl_month IN ('june', 'july')
  ) AS june_july_winners;
