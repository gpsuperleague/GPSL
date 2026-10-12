-- =============================================================================
-- Central Bank: financial-risk clubs refused loans (2026-10-12)
-- =============================================================================
-- A club is a financial risk (uncreditworthy) and new loans are refused while
-- EITHER is true:
--   1) Overdrawn (balance < 0) at each of its last 6 month-end check-ins in a
--      row (half a season). Clears once a month-end check-in shows the club
--      in credit.
--   2) An FFP penalty (eos_ffp_charge) in any of the last 5 seasons (current
--      season included). Clears once that season is more than 5 seasons back.
-- The existing rule (overdrawn at the end of 2 seasons) still applies.
--
-- Month-end balances:
--   * club_month_end_balances — one row per club per GPSL month.
--   * Taken automatically at each month lock (wired into
--     competition_run_month_lock_jobs, first write wins).
--   * Past months rebuilt once from the finance ledger (balance now minus
--     every ledger row after that month's lock), source = 'ledger_rebuild'.
--
-- club_take_loan already calls club_loan_credit_check, so no change there.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_credit_overdrawn_months_limit()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 6 $$;

CREATE OR REPLACE FUNCTION public.club_credit_ffp_lookback_seasons()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 5 $$;

CREATE TABLE IF NOT EXISTS public.club_month_end_balances (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  gpsl_month text NOT NULL,
  club_short_name text NOT NULL,
  balance numeric(14, 2) NOT NULL,
  source text NOT NULL DEFAULT 'month_lock'
    CHECK (source IN ('month_lock', 'ledger_rebuild', 'admin')),
  checkpoint_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, gpsl_month, club_short_name)
);

CREATE INDEX IF NOT EXISTS club_month_end_balances_club_idx
  ON public.club_month_end_balances (club_short_name, checkpoint_at DESC);

COMMENT ON TABLE public.club_month_end_balances IS
  'Club balance at each GPSL month-end check-in (month lock). Used for the loan credit check.';

ALTER TABLE public.club_month_end_balances ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_month_end_balances_admin_select ON public.club_month_end_balances;
CREATE POLICY club_month_end_balances_admin_select
  ON public.club_month_end_balances
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

GRANT SELECT ON public.club_month_end_balances TO authenticated;
GRANT ALL ON public.club_month_end_balances TO service_role;

-- ---------------------------------------------------------------------------
-- Snapshot every league club's balance for one GPSL month (first write wins)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_balance_snapshot_gpsl_month(
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
  v_rows int := 0;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id and gpsl_month required');
  END IF;

  INSERT INTO public.club_month_end_balances (
    season_id, gpsl_month, club_short_name, balance, source, checkpoint_at
  )
  SELECT p_season_id, v_month, f.club_name, coalesce(f.balance, 0), 'month_lock', now()
  FROM public."Club_Finances" f
  JOIN public.competition_club_seasons ccs
    ON ccs.club_short_name = f.club_name
   AND ccs.season_id = p_season_id
  WHERE f.club_name <> 'FOREIGN'
  ON CONFLICT (season_id, gpsl_month, club_short_name) DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'gpsl_month', v_month, 'inserted', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.club_balance_snapshot_gpsl_month(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.club_balance_snapshot_gpsl_month(bigint, text) TO service_role;

-- Wire into month-lock jobs
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'club_balance_snapshot_gpsl_month';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE WARNING 'competition_run_month_lock_jobs(4-arg) missing — month-end balance snapshots not wired';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Month-end balance snapshots already wired';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'Could not find RETURN v_out in month-lock jobs — balance snapshots not wired';
    RETURN;
  END IF;

  v_new :=
    E'  -- Month-end club balances (loan credit check)\n'
    || E'  BEGIN\n'
    || E'    IF v_month IS NOT NULL\n'
    || E'       AND to_regprocedure(''public.club_balance_snapshot_gpsl_month(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''month_end_balances'',\n'
    || E'        public.club_balance_snapshot_gpsl_month(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''month_end_balances'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'END;';

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired month-end balance snapshots into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Month-end balance wire failed: %', SQLERRM;
END;
$wire$;

-- ---------------------------------------------------------------------------
-- One-off rebuild of past month ends from the ledger
-- (month lock time = first Team of the Month / GPSL Sport job for that month)
-- ---------------------------------------------------------------------------
WITH locks AS (
  SELECT j.season_id, lower(j.gpsl_month) AS gpsl_month, min(j.ran_at) AS locked_at
  FROM public.competition_season_calendar_jobs j
  WHERE j.gpsl_month IS NOT NULL
    AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
  GROUP BY j.season_id, lower(j.gpsl_month)
)
INSERT INTO public.club_month_end_balances (
  season_id, gpsl_month, club_short_name, balance, source, checkpoint_at
)
SELECT
  lk.season_id,
  lk.gpsl_month,
  f.club_name,
  coalesce(f.balance, 0) - coalesce((
    SELECT sum(l.amount)
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = f.club_name
      AND l.created_at > lk.locked_at
  ), 0),
  'ledger_rebuild',
  lk.locked_at
FROM locks lk
JOIN public.competition_club_seasons ccs ON ccs.season_id = lk.season_id
JOIN public."Club_Finances" f ON f.club_name = ccs.club_short_name
WHERE f.club_name <> 'FOREIGN'
ON CONFLICT (season_id, gpsl_month, club_short_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Credit risk status for one club
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_credit_risk_status(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club, ''));
  v_limit int := public.club_credit_overdrawn_months_limit();
  v_lookback int := public.club_credit_ffp_lookback_seasons();
  v_streak int := 0;
  v_checked int := 0;
  v_ffp_seasons jsonb;
  v_negative_seasons int := 0;
  r record;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  -- Consecutive overdrawn month ends, most recent first
  FOR r IN
    SELECT b.balance
    FROM public.club_month_end_balances b
    WHERE b.club_short_name = v_club
    ORDER BY b.checkpoint_at DESC
    LIMIT v_limit
  LOOP
    v_checked := v_checked + 1;
    EXIT WHEN r.balance >= 0;
    v_streak := v_streak + 1;
  END LOOP;

  SELECT coalesce(jsonb_agg(
           jsonb_build_object('season_id', s.id, 'season_label', s.label)
           ORDER BY s.id DESC
         ), '[]'::jsonb)
  INTO v_ffp_seasons
  FROM (
    SELECT id, label FROM public.competition_seasons ORDER BY id DESC LIMIT v_lookback
  ) s
  WHERE EXISTS (
    SELECT 1 FROM public.competition_season_charge_paid cp
    WHERE cp.season_id = s.id
      AND cp.club_short_name = v_club
      AND cp.charge_type = 'eos_ffp_charge'
  );

  IF to_regprocedure('public.club_loan_negative_season_count(text)') IS NOT NULL THEN
    v_negative_seasons := public.club_loan_negative_season_count(v_club);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'overdrawn_month_ends', v_streak,
    'overdrawn_month_ends_limit', v_limit,
    'overdrawn_risk', v_streak >= v_limit,
    'ffp_seasons', v_ffp_seasons,
    'ffp_lookback_seasons', v_lookback,
    'ffp_risk', jsonb_array_length(v_ffp_seasons) > 0,
    'negative_seasons', v_negative_seasons,
    'negative_seasons_risk', v_negative_seasons >= 2
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_credit_risk_status(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.club_credit_risk_status(text) TO service_role;

-- ---------------------------------------------------------------------------
-- Loan credit check (same shape the bank page already reads)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_loan_credit_check(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_risk jsonb;
  v_reasons text[] := ARRAY[]::text[];
  v_ffp_labels text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'negative_seasons', 0,
      'message', 'No club linked to your account.'
    );
  END IF;

  IF p_club IS NOT NULL
     AND btrim(p_club) <> ''
     AND btrim(p_club) IS DISTINCT FROM public.my_club_shortname()
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not your club';
  END IF;

  v_risk := public.club_credit_risk_status(v_club);

  IF (v_risk->>'overdrawn_risk')::boolean THEN
    v_reasons := v_reasons || format(
      'overdrawn at each of the last %s month-end check-ins — loans return once a month-end check-in shows the club in credit',
      v_risk->>'overdrawn_month_ends_limit'
    );
  END IF;

  IF (v_risk->>'ffp_risk')::boolean THEN
    SELECT string_agg(coalesce(x->>'season_label', 'season ' || (x->>'season_id')), ', ')
    INTO v_ffp_labels
    FROM jsonb_array_elements(v_risk->'ffp_seasons') x;
    v_reasons := v_reasons || format(
      'FFP penalty in %s — FFP penalties count against the club for %s seasons',
      v_ffp_labels,
      v_risk->>'ffp_lookback_seasons'
    );
  END IF;

  IF (v_risk->>'negative_seasons_risk')::boolean THEN
    v_reasons := v_reasons || 'overdrawn at the end of two seasons'::text;
  END IF;

  IF cardinality(v_reasons) = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'negative_seasons', (v_risk->>'negative_seasons')::int,
      'overdrawn_month_ends', (v_risk->>'overdrawn_month_ends')::int,
      'ffp_seasons', v_risk->'ffp_seasons',
      'message', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', false,
    'financial_risk', true,
    'negative_seasons', (v_risk->>'negative_seasons')::int,
    'overdrawn_month_ends', (v_risk->>'overdrawn_month_ends')::int,
    'ffp_seasons', v_risk->'ffp_seasons',
    'reasons', to_jsonb(v_reasons),
    'message',
      'Application declined. The bank manager checked the club''s creditworthiness: the club is rated a financial risk and is not creditworthy ('
      || array_to_string(v_reasons, '; ')
      || '). No loans until the club is clean on all counts.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_credit_check(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: every league club this season that is currently refused, plus wiring
WITH cur AS (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
),
clubs AS (
  SELECT ccs.club_short_name AS club
  FROM public.competition_club_seasons ccs, cur
  WHERE ccs.season_id = cur.id AND ccs.club_short_name <> 'FOREIGN'
),
st AS (
  SELECT c.club, public.club_credit_risk_status(c.club) AS s FROM clubs c
)
SELECT
  st.club,
  (st.s->>'overdrawn_month_ends')::int AS overdrawn_month_ends_in_a_row,
  (SELECT string_agg(x->>'season_label', ', ') FROM jsonb_array_elements(st.s->'ffp_seasons') x)
    AS ffp_seasons,
  (st.s->>'negative_seasons')::int AS seasons_ended_overdrawn,
  CASE
    WHEN (st.s->>'overdrawn_risk')::boolean
      OR (st.s->>'ffp_risk')::boolean
      OR (st.s->>'negative_seasons_risk')::boolean
    THEN 'REFUSED' ELSE 'ok'
  END AS loans,
  (SELECT count(*) FROM public.club_month_end_balances b WHERE b.club_short_name = st.club)
    AS month_ends_recorded,
  position('club_balance_snapshot_gpsl_month' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0 AS month_lock_wired
FROM st
ORDER BY (CASE
    WHEN (st.s->>'overdrawn_risk')::boolean
      OR (st.s->>'ffp_risk')::boolean
      OR (st.s->>'negative_seasons_risk')::boolean
    THEN 0 ELSE 1 END),
  (st.s->>'overdrawn_month_ends')::int DESC,
  st.club;
