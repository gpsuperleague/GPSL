-- Hotfix: government subsidies fail during playoffs / post-league pay
--
-- Error:
--   new row for relation "competition_finance_ledger" violates check constraint
--   "competition_finance_ledger_entry_type_check"
--
-- Cause:
--   Later patches (e.g. match_video_uploads_20260912) rebuilt the entry_type CHECK
--   as (live distinct types) ∪ (short new-type list). If gov_*_subsidy had never
--   been posted yet, those types were dropped from the allow-list.
--
-- Fix:
--   Re-add gov_hg_subsidy / gov_youth_subsidy / gov_bnb_subsidy (and keep
--   gate_match_video) via gpsl_ledger_ensure_entry_types.
--
-- Safe re-run. After apply, retry Admin → Government subsidies → Pay.

BEGIN;

DO $fix$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.gpsl_ledger_ensure_entry_types(text[])') IS NOT NULL THEN
    PERFORM public.gpsl_ledger_ensure_entry_types(
      ARRAY[
        'gov_hg_subsidy',
        'gov_youth_subsidy',
        'gov_bnb_subsidy',
        'gate_match_video'
      ]
    );
  ELSE
    -- Fallback if helper not deployed yet: live ∪ known subsidy / video types
    SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
    INTO v_def
    FROM (
      SELECT DISTINCT entry_type AS t
      FROM public.competition_finance_ledger
      WHERE entry_type IS NOT NULL
      UNION
      SELECT unnest(ARRAY[
        'gov_hg_subsidy',
        'gov_youth_subsidy',
        'gov_bnb_subsidy',
        'gate_match_video',
        'gate_league_home',
        'gate_cup_share',
        'gate_friendlies',
        'tv_revenue',
        'prize',
        'prize_league',
        'prize_cup',
        'prize_challenge'
      ])
    ) s;

    ALTER TABLE public.competition_finance_ledger
      DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

    EXECUTE format(
      'ALTER TABLE public.competition_finance_ledger
         ADD CONSTRAINT competition_finance_ledger_entry_type_check
         CHECK (entry_type IN (%s))',
      v_def
    );
  END IF;

  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conname = 'competition_finance_ledger_entry_type_check'
    AND c.conrelid = 'public.competition_finance_ledger'::regclass;

  IF v_def IS NULL
     OR position('gov_hg_subsidy' IN v_def) = 0
     OR position('gov_youth_subsidy' IN v_def) = 0
     OR position('gov_bnb_subsidy' IN v_def) = 0 THEN
    RAISE EXCEPTION
      'gov subsidy entry types still missing after rebuild. def=%',
      coalesce(v_def, '(null)');
  END IF;

  RAISE NOTICE 'OK — gov subsidy ledger types restored. %', left(v_def, 200);
END;
$fix$;

NOTIFY pgrst, 'reload schema';

COMMIT;
