-- Catch-up: Team / Owner / Manager of the Month for locked months
-- =============================================================================
-- Context:
--   • Owner of the Month shipped 2026-10-22 — August (and earlier) locks never
--     awarded it.
--   • Team of the Month is idempotent via competition_season_calendar_jobs;
--     August admin replay left those job rows in place, so lock retries skip.
--   • MotM calls also award OotM (competition_compute_manager_of_month).
--
-- This patch:
--   1) Forces August TOTM + MotM/OotM recompute (clear job keys first)
--   2) Backfills any other locked month missing TOTM and/or OotM
--   3) Flips month-lock "awards" stage to include MotM/OotM going forward
-- Prize ledger uses dedupe keys — safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_catchup_month_awards(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_months text[] DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_month text;
  v_scope text;
  v_job_key text;
  v_res jsonb;
  v_totm jsonb;
  v_motm jsonb;
  v_processed jsonb := '[]'::jsonb;
  v_force boolean;
  v_need_totm boolean;
  v_need_ootm boolean;
  v_need_motm boolean;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_month IN
    SELECT lower(btrim(c.gpsl_month))
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.gpsl_month <> 'playoffs'
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
      AND (
        p_gpsl_months IS NULL
        OR lower(btrim(c.gpsl_month)) = ANY (
          SELECT lower(btrim(x)) FROM unnest(p_gpsl_months) x
        )
      )
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    -- August always force-refreshed (admin replay + OotM shipped after lock)
    v_force := coalesce(p_force, false) OR v_month = 'august';

    v_need_totm := v_force OR NOT EXISTS (
      SELECT 1
      FROM public.competition_period_team t
      WHERE t.season_id = v_season_id
        AND t.period_kind = 'month'
        AND lower(btrim(t.gpsl_month)) = v_month
    );

    v_need_ootm := v_force OR (
      SELECT count(*) < 2
      FROM public.competition_owner_month_award a
      WHERE a.season_id = v_season_id
        AND lower(btrim(a.gpsl_month)) = v_month
    );

    v_need_motm := v_force OR NOT EXISTS (
      SELECT 1
      FROM public.competition_manager_month_award m
      WHERE m.season_id = v_season_id
        AND lower(btrim(m.gpsl_month)) = v_month
    );

    v_totm := NULL;
    v_motm := NULL;

    IF v_need_totm
       AND to_regprocedure('public.competition_compute_team_of_month(bigint,text,text)') IS NOT NULL THEN
      DELETE FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season_id
        AND (
          j.job_key = 'team_of_month:' || v_month
          OR j.job_key LIKE 'team_of_month:%:' || v_month
          OR (
            lower(btrim(coalesce(j.gpsl_month, ''))) = v_month
            AND j.job_key LIKE 'team_of_month:%'
          )
        );

      v_totm := '[]'::jsonb;
      FOREACH v_scope IN ARRAY ARRAY['superleague', 'championship']::text[]
      LOOP
        v_job_key := 'team_of_month:' || v_scope || ':' || v_month;
        v_res := public.competition_compute_team_of_month(
          v_season_id, v_month, v_scope
        );
        INSERT INTO public.competition_season_calendar_jobs (
          season_id, job_key, gpsl_month, result
        )
        VALUES (v_season_id, v_job_key, v_month, coalesce(v_res, '{}'::jsonb))
        ON CONFLICT (season_id, job_key) DO UPDATE
          SET result = excluded.result,
              gpsl_month = excluded.gpsl_month,
              ran_at = now();
        v_totm := v_totm || jsonb_build_array(
          jsonb_build_object('scope', v_scope, 'result', v_res)
        );
      END LOOP;
    END IF;

    IF (v_need_ootm OR v_need_motm)
       AND to_regprocedure('public.competition_compute_manager_of_month(bigint,text)') IS NOT NULL THEN
      v_motm := public.competition_compute_manager_of_month(v_season_id, v_month);
    ELSIF v_need_ootm
       AND to_regprocedure('public.competition_award_owners_of_month(bigint,text)') IS NOT NULL THEN
      v_motm := public.competition_award_owners_of_month(v_season_id, v_month);
    END IF;

    IF v_totm IS NOT NULL OR v_motm IS NOT NULL THEN
      v_processed := v_processed || jsonb_build_array(
        jsonb_build_object(
          'gpsl_month', v_month,
          'forced', v_force,
          'team_of_month', v_totm,
          'manager_owner_of_month', v_motm
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'processed', v_processed
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_catchup_month_awards(bigint, text[], boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_catchup_month_awards(bigint, text[], boolean)
  TO service_role, authenticated;

-- Run catch-up now (August forced; other locked months only if missing)
SELECT public.competition_catchup_month_awards(NULL, NULL, false) AS catchup_result;

-- Include MotM/OotM in the "awards" month-lock stage going forward
-- (Postgres replace() is 3-arg only — no occurrence count)
DO $wire$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
  v_awards_pos int;
  v_flag_pos int;
  v_chunk text;
  v_old text := 'v_do_motm := false;';
  v_on text := 'v_do_motm := true;';
BEGIN
  v_oid := to_regprocedure(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'
  );
  IF v_oid IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs missing — awards stage wire skipped';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_awards_pos := position('ELSIF v_stage = ''awards'' THEN' IN v_def);
  IF v_awards_pos = 0 THEN
    RAISE NOTICE 'awards stage block not found — skip';
    RETURN;
  END IF;

  v_chunk := substring(v_def from v_awards_pos for 500);
  IF position(v_on IN v_chunk) > 0 THEN
    RAISE NOTICE 'awards stage already enables motm';
    RETURN;
  END IF;

  v_flag_pos := position(v_old IN v_chunk);
  IF v_flag_pos = 0 THEN
    RAISE NOTICE 'awards stage motm flag not found in expected chunk';
    RETURN;
  END IF;

  v_new := overlay(
    v_def
    placing v_on
    from v_awards_pos + v_flag_pos - 1
    for length(v_old)
  );

  IF v_new IS DISTINCT FROM v_def THEN
    EXECUTE v_new;
    RAISE NOTICE 'awards stage now includes MotM/OotM';
  ELSE
    RAISE NOTICE 'awards stage motm flag not rewritten';
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'awards stage wire skipped: %', SQLERRM;
END;
$wire$;

-- Verify August after catch-up
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'post_catchup_august' AS section,
  (SELECT count(*) FROM public.competition_period_team t
    JOIN cur ON cur.season_id = t.season_id
   WHERE t.period_kind = 'month' AND lower(btrim(t.gpsl_month)) = 'august') AS totm_teams,
  (SELECT count(*) FROM public.competition_owner_month_award a
    JOIN cur ON cur.season_id = a.season_id
   WHERE lower(btrim(a.gpsl_month)) = 'august') AS ootm_awards,
  (SELECT count(*) FROM public.competition_manager_month_award m
    JOIN cur ON cur.season_id = m.season_id
   WHERE lower(btrim(m.gpsl_month)) = 'august') AS motm_awards;

NOTIFY pgrst, 'reload schema';
