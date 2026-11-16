-- Month-lock interest health check, award notes on fixtures, replay inbox.
-- Safe re-run.

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS award_note text;

COMMENT ON COLUMN public.competition_fixtures.award_note IS
  'Why an awarded, 0–0 or void result was written. Shown on the fixtures status.';

-- Interest step reads the lock snapshot when one exists, so a later balance
-- movement in the same lock does not change the month's interest.
DO $interest$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_post_monthly_interest(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('club_month_end_balances' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := $old$
    SELECT f.club_name AS club, coalesce(f.balance, 0) AS balance
    FROM public."Club_Finances" f
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = f.club_name
     AND ccs.season_id = p_season_id
    WHERE f.club_name <> 'FOREIGN'
      AND coalesce(f.balance, 0) <> 0$old$;
  v_new := $new$
    SELECT ccs.club_short_name AS club,
           coalesce(snap.balance, f.balance, 0) AS balance
    FROM public.competition_club_seasons ccs
    JOIN public."Club_Finances" f
      ON f.club_name = ccs.club_short_name
    LEFT JOIN public.club_month_end_balances snap
      ON snap.season_id = ccs.season_id
     AND snap.gpsl_month = v_month
     AND snap.club_short_name = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND f.club_name <> 'FOREIGN'
      AND coalesce(snap.balance, f.balance, 0) <> 0$new$;
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'interest balance select not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END
$interest$;

CREATE OR REPLACE FUNCTION public.competition_monthly_interest_health(
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
  v_enabled boolean;
  v_credit_pct numeric;
  v_debt_pct numeric;
  v_debt_pct_club numeric;
  v_label text;
  v_amount numeric;
  v_missing int;
  v_credit int;
  v_debt int;
  v_still int;
  v_errors jsonb := '[]'::jsonb;
  v_months jsonb := '[]'::jsonb;
  v_one text;
  r record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id and gpsl_month required');
  END IF;

  SELECT b.monthly_interest_enabled,
         greatest(coalesce(b.monthly_balance_interest_pct, 0.25), 0),
         greatest(coalesce(b.monthly_debt_interest_pct, 0.50), 0)
  INTO v_enabled, v_credit_pct, v_debt_pct
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'monthly_interest_disabled');
  END IF;

  FOR v_one IN
    SELECT m.gpsl_month
    FROM (
      SELECT v_month AS gpsl_month, 0 AS ord
      UNION
      SELECT lower(btrim(c.gpsl_month)), c.sort_order
      FROM public.competition_season_calendar c
      WHERE c.season_id = p_season_id
        AND c.lock_at IS NOT NULL
        AND c.lock_at <= now()
        AND lower(btrim(c.gpsl_month)) <> 'playoffs'
        AND EXISTS (
          SELECT 1
          FROM public.club_month_end_balances b
          WHERE b.season_id = p_season_id
            AND b.gpsl_month = lower(btrim(c.gpsl_month))
            AND b.balance <> 0
            AND NOT EXISTS (
              SELECT 1
              FROM public.club_monthly_interest mi
              WHERE mi.season_id = b.season_id
                AND mi.gpsl_month = b.gpsl_month
                AND mi.club_short_name = b.club_short_name
            )
        )
    ) m
    GROUP BY m.gpsl_month
    ORDER BY min(m.ord), m.gpsl_month
  LOOP
    SELECT count(*) INTO v_missing
    FROM public.club_month_end_balances b
    WHERE b.season_id = p_season_id
      AND b.gpsl_month = v_one
      AND b.balance <> 0
      AND NOT EXISTS (
        SELECT 1 FROM public.club_monthly_interest mi
        WHERE mi.season_id = b.season_id
          AND mi.gpsl_month = b.gpsl_month
          AND mi.club_short_name = b.club_short_name
      );

    v_credit := 0;
    v_debt := 0;
    v_errors := '[]'::jsonb;

    BEGIN
      v_label := public.competition_gpsl_month_label(v_one);
    EXCEPTION WHEN OTHERS THEN
      v_label := initcap(v_one);
    END;

    FOR r IN
      SELECT b.club_short_name AS club, b.balance
      FROM public.club_month_end_balances b
      WHERE b.season_id = p_season_id
        AND b.gpsl_month = v_one
        AND b.balance <> 0
        AND NOT EXISTS (
          SELECT 1 FROM public.club_monthly_interest mi
          WHERE mi.season_id = b.season_id
            AND mi.gpsl_month = b.gpsl_month
            AND mi.club_short_name = b.club_short_name
        )
      ORDER BY b.club_short_name
    LOOP
      BEGIN
        IF r.balance > 0 THEN
          v_amount := round(r.balance * v_credit_pct / 100.0, 0);
          IF v_amount > 0 THEN
            PERFORM public.post_club_ledger(
              r.club, 'eos_balance_interest', v_amount,
              format('%s balance interest — %s%% on ₿%s',
                     v_label, to_char(v_credit_pct, 'FM990.00'),
                     to_char(r.balance, 'FM999,999,999,999')),
              jsonb_build_object(
                'monthly', true, 'gpsl_month', v_one,
                'rate_pct', v_credit_pct, 'balance_snapshot', r.balance,
                'source', 'interest_health'
              ),
              p_season_id, NULL, true, true
            );
            INSERT INTO public.club_monthly_interest (
              season_id, gpsl_month, club_short_name, kind, rate_pct, balance_snapshot, amount
            ) VALUES (
              p_season_id, v_one, r.club, 'balance', v_credit_pct, r.balance, v_amount
            );
            v_credit := v_credit + 1;
          END IF;
        ELSE
          BEGIN
            v_debt_pct_club := public.club_monthly_debt_interest_rate(r.club);
          EXCEPTION WHEN OTHERS THEN
            v_debt_pct_club := v_debt_pct;
          END;
          v_amount := round(abs(r.balance) * v_debt_pct_club / 100.0, 0);
          IF v_amount > 0 THEN
            PERFORM public.post_club_ledger(
              r.club, 'eos_debt_interest', -v_amount,
              format('%s overdraft interest — %s%% on ₿%s overdrawn%s',
                     v_label, to_char(v_debt_pct_club, 'FM990.00'),
                     to_char(abs(r.balance), 'FM999,999,999,999'),
                     CASE WHEN v_debt_pct_club > v_debt_pct THEN ' (bad credit rate)' ELSE '' END),
              jsonb_build_object(
                'monthly', true, 'gpsl_month', v_one,
                'rate_pct', v_debt_pct_club, 'base_rate_pct', v_debt_pct,
                'bad_credit_rate', v_debt_pct_club > v_debt_pct,
                'balance_snapshot', r.balance, 'source', 'interest_health'
              ),
              p_season_id, NULL,
              public.finance_entry_via_central_bank('eos_debt_interest'),
              true
            );
            INSERT INTO public.club_monthly_interest (
              season_id, gpsl_month, club_short_name, kind, rate_pct, balance_snapshot, amount
            ) VALUES (
              p_season_id, v_one, r.club, 'debt', v_debt_pct_club, r.balance, -v_amount
            );
            v_debt := v_debt + 1;
          END IF;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_array(
          jsonb_build_object('club', r.club, 'error', SQLERRM)
        );
      END;
    END LOOP;

    SELECT count(*) INTO v_still
    FROM public.club_month_end_balances b
    WHERE b.season_id = p_season_id
      AND b.gpsl_month = v_one
      AND b.balance <> 0
      AND NOT EXISTS (
        SELECT 1 FROM public.club_monthly_interest mi
        WHERE mi.season_id = b.season_id
          AND mi.gpsl_month = b.gpsl_month
          AND mi.club_short_name = b.club_short_name
      );

    v_months := v_months || jsonb_build_array(jsonb_build_object(
      'gpsl_month', v_one,
      'missing_before', v_missing,
      'posted_credit', v_credit,
      'posted_debt', v_debt,
      'still_missing', v_still,
      'errors', v_errors
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'checked_month', v_month,
    'months', v_months
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_monthly_interest_health(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_monthly_interest_health(bigint, text)
  TO service_role;

INSERT INTO public.competition_month_lock_hooks (hook_key, sort_order, enabled, proc_name, notes)
VALUES (
  'monthly_interest_health',
  5,
  true,
  'competition_monthly_interest_health',
  'After the interest step, post any club still missing from the month-end snapshot. Also catches an earlier locked month that was missed.'
)
ON CONFLICT (hook_key) DO UPDATE
SET enabled = true,
    sort_order = EXCLUDED.sort_order,
    proc_name = EXCLUDED.proc_name,
    notes = EXCLUDED.notes;

DO $award$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.fixture_apply_forfeit(bigint,text,text,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('award_note' IN v_def) = 0 THEN
    v_old := E'    is_forfeit = true,\n    forfeit_loser_club = p_loser_club\n  WHERE id = p_fixture_id;';
    v_new := E'    is_forfeit = true,\n    forfeit_loser_club = p_loser_club,\n    award_note = nullif(left(btrim(coalesce(p_reason, '''')), 400), '''')\n  WHERE id = p_fixture_id;';
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'forfeit update not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(
    pg_get_functiondef('public.fixture_apply_score_draw_0_0(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('award_note' IN v_def) = 0 THEN
    v_old := E'    home_goals = 0,\n    away_goals = 0,\n    status = ''played'',\n    is_forfeit = false,\n    forfeit_loser_club = NULL\n  WHERE id = p_fixture_id;';
    v_new := E'    home_goals = 0,\n    away_goals = 0,\n    status = ''played'',\n    is_forfeit = false,\n    forfeit_loser_club = NULL,\n    award_note = nullif(left(btrim(coalesce(p_reason, '''')), 400), '''')\n  WHERE id = p_fixture_id;';
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'draw update not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(
    pg_get_functiondef('public.fixture_apply_manual_mutual_forfeit(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('award_note' IN v_def) = 0 THEN
    v_old := E'      is_void = true,\n      home_goals = NULL,\n      away_goals = NULL,\n      is_forfeit = false,\n      forfeit_loser_club = NULL\n  WHERE id = p_fixture_id;';
    v_new := E'      is_void = true,\n      home_goals = NULL,\n      away_goals = NULL,\n      is_forfeit = false,\n      forfeit_loser_club = NULL,\n      award_note = ''Mutual forfeit — both clubs had arranging switched off''\n  WHERE id = p_fixture_id;';
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'mutual forfeit update not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END
$award$;

UPDATE public.competition_fixtures f
SET award_note = left(btrim(src.note), 400)
FROM (
  SELECT DISTINCT ON (i.fixture_id)
    i.fixture_id,
    substring(i.body FROM 'forfeited 3[^0-9]0\.[[:space:]]*(.*)$') AS note
  FROM public.competition_inbox i
  WHERE i.message_type = 'match_forfeit_applied'
    AND i.fixture_id IS NOT NULL
    AND i.body ~ 'forfeited 3'
  ORDER BY i.fixture_id, i.id DESC
) src
WHERE f.id = src.fixture_id
  AND f.is_forfeit = true
  AND coalesce(f.award_note, '') = ''
  AND coalesce(btrim(src.note), '') <> '';

UPDATE public.competition_fixtures f
SET award_note = left(btrim(src.body), 400)
FROM (
  SELECT DISTINCT ON (i.fixture_id) i.fixture_id, i.body
  FROM public.competition_inbox i
  WHERE i.message_type = 'match_window_draw'
    AND i.fixture_id IS NOT NULL
  ORDER BY i.fixture_id, i.id DESC
) src
WHERE f.id = src.fixture_id
  AND f.status = 'played'
  AND f.home_goals = 0
  AND f.away_goals = 0
  AND coalesce(f.is_forfeit, false) = false
  AND coalesce(f.award_note, '') = ''
  AND coalesce(btrim(src.body), '') <> '';

UPDATE public.competition_fixtures f
SET award_note = 'Mutual forfeit — both clubs had arranging switched off'
WHERE f.is_void = true
  AND f.status = 'played'
  AND coalesce(f.award_note, '') = ''
  AND EXISTS (
    SELECT 1
    FROM public.competition_inbox i
    WHERE i.fixture_id = f.id
      AND i.body ILIKE '%arranging switched OFF%'
  );

DO $view$
DECLARE
  v_def text;
  v_sql text;
BEGIN
  v_def := replace(pg_get_viewdef('public.competition_fixtures_public'::regclass, true), E'\r\n', E'\n');
  v_def := regexp_replace(v_def, ';\s*$', '');
  IF position('award_note' IN v_def) > 0 THEN
    RETURN;
  END IF;
  v_sql := format($fmt$
CREATE OR REPLACE VIEW public.competition_fixtures_public
WITH (security_invoker = false) AS
SELECT base.*, fx.award_note
FROM (
%s
) base
JOIN public.competition_fixtures fx ON fx.id = base.id
$fmt$, v_def);
  EXECUTE v_sql;
END
$view$;

DO $replay_type$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NOT NULL AND position('''match_replay''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'match_replay'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$replay_type$;

DO $replay$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_fixture_reset_for_replay(bigint,text,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('match_replay' IN v_def) > 0 THEN
    RETURN;
  END IF;
  v_old := E'  v_after := public.admin_fixture_reset_preview(v_fid);';
  v_new := $new$
  PERFORM public.owner_inbox_send(
    'match_replay',
    public.competition_fixture_inbox_title(v_fid, 'Match to be replayed'),
    public.competition_fixture_inbox_body(
      v_fid,
      'This match will be replayed. ' || coalesce(nullif(btrim(v_reason), ''), '')
    ),
    v_home, NULL, v_fid,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || v_fid::text,
    'replay:' || v_fid::text || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS'),
    v_f.gpsl_month, v_f.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_replay',
    public.competition_fixture_inbox_title(v_fid, 'Match to be replayed'),
    public.competition_fixture_inbox_body(
      v_fid,
      'This match will be replayed. ' || coalesce(nullif(btrim(v_reason), ''), '')
    ),
    v_away, NULL, v_fid,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || v_fid::text,
    'replay:' || v_fid::text || ':away:' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS'),
    v_f.gpsl_month, v_f.season_id, NULL
  );

  v_after := public.admin_fixture_reset_preview(v_fid);$new$;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'replay return anchor not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$replay$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'health', public.competition_monthly_interest_health(1, 'october'),
  'hook', (
    SELECT h.enabled FROM public.competition_month_lock_hooks h
    WHERE h.hook_key = 'monthly_interest_health'
  ),
  'interest_uses_snapshot', position(
    'club_month_end_balances' IN pg_get_functiondef('public.competition_post_monthly_interest(bigint,text)'::regprocedure)
  ) > 0,
  'replay_inbox', position(
    'match_replay' IN pg_get_functiondef('public.admin_fixture_reset_for_replay(bigint,text,text)'::regprocedure)
  ) > 0,
  'forfeit_notes', (
    SELECT count(*) FROM public.competition_fixtures f
    WHERE f.is_forfeit = true AND coalesce(f.award_note, '') <> ''
  ),
  'forfeit_blank', (
    SELECT count(*) FROM public.competition_fixtures f
    WHERE f.is_forfeit = true AND f.status = 'played' AND coalesce(f.award_note, '') = ''
  ),
  'view_note', EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'competition_fixtures_public'
      AND c.column_name = 'award_note'
  ),
  'sample', (
    SELECT f.award_note FROM public.competition_fixtures f
    WHERE f.is_forfeit = true AND coalesce(f.award_note, '') <> ''
    ORDER BY f.id DESC
    LIMIT 1
  )
);
