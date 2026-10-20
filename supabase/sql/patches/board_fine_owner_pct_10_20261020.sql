-- =============================================================================
-- Board fine on club expectation miss: 25% → 10% of owner Building Society balance
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.board_fine_owner_personal_pct(
  p_club_short_name text,
  p_pct numeric DEFAULT 10,
  p_reason text DEFAULT 'Board fine',
  p_season_id bigint DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_owner uuid;
  v_bal numeric(14, 2) := 0;
  v_fine numeric(14, 2) := 0;
  v_pct numeric := greatest(0, least(100, coalesce(p_pct, 10)));
BEGIN
  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = btrim(p_club_short_name);

  IF v_owner IS NULL THEN
    RETURN 0;
  END IF;

  IF to_regprocedure('public.owner_wallet_ensure(uuid)') IS NOT NULL THEN
    PERFORM public.owner_wallet_ensure(v_owner);
  END IF;

  SELECT coalesce(w.balance, 0) INTO v_bal
  FROM public.owner_wallets w
  WHERE w.owner_id = v_owner;

  v_bal := coalesce(v_bal, 0);
  v_fine := round(v_bal * (v_pct / 100.0), 2);
  IF v_fine <= 0 THEN
    RETURN 0;
  END IF;
  IF v_fine > v_bal THEN
    v_fine := v_bal;
  END IF;
  IF v_fine <= 0 THEN
    RETURN 0;
  END IF;

  IF to_regprocedure('public.gpsl_auto_fine_code_active(text)') IS NOT NULL
     AND NOT public.gpsl_auto_fine_code_active('board_fine') THEN
    BEGIN
      PERFORM public.owner_inbox_send(
        'fine_applied',
        'Board fine waived — ease-in period',
        concat_ws(
          E'\n',
          'No money has been taken from your Building Society account.',
          format(
            'You would have been fined %s (%s%% of your balance): %s',
            public.transfer_format_money(v_fine),
            v_pct,
            coalesce(nullif(btrim(p_reason), ''), 'Board fine')
          ),
          CASE
            WHEN to_regprocedure('public.gpsl_auto_fines_live_label()') IS NOT NULL
              THEN public.gpsl_auto_fines_live_label()
            ELSE NULL
          END
        ),
        btrim(p_club_short_name),
        NULL, NULL, NULL, NULL, NULL,
        'owners_bank.html',
        'board_fine_waived:' || btrim(p_club_short_name) || ':' || coalesce(p_season_id, 0)::text,
        NULL,
        p_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    RETURN 0;
  END IF;

  PERFORM public._post_owner_ledger_internal(
    v_owner,
    'board_fine',
    -v_fine,
    coalesce(nullif(btrim(p_reason), ''), 'Board fine'),
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'club', btrim(p_club_short_name),
      'pct', v_pct,
      'balance_before', v_bal
    ),
    p_season_id,
    true
  );

  RETURN v_fine;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.board_fine_owner_personal_pct(text, numeric, text, bigint, jsonb) TO authenticated;

-- Call site in underperformance processor (was hard-coded 25)
DO $fix_call$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.club_underperformance_process_club(text,bigint)') IS NULL THEN
    RAISE NOTICE 'club_underperformance_process_club missing — skip';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef('public.club_underperformance_process_club(text,bigint)'::regprocedure),
    E'\r\n', E'\n'
  ) INTO v_def;

  v_old := replace($n$    v_fine := public.board_fine_owner_personal_pct(
      p_club_short_name,
      25,
$n$, E'\r\n', E'\n');

  v_new := replace($n$    v_fine := public.board_fine_owner_personal_pct(
      p_club_short_name,
      10,
$n$, E'\r\n', E'\n');

  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'club_underperformance_process_club already uses 10%% board fine';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'board fine call needle not found — default arg may still apply (10%%)';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'club_underperformance_process_club board fine set to 10%%';
END;
$fix_call$;

NOTIFY pgrst, 'reload schema';
