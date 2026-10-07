-- =============================================================================
-- Manager year-1 board sack (2026-10-07)
-- =============================================================================
-- End of season 1 of a 2-season deal: if the club's expectation band is
-- 'bad' or 'abysmal' (3+ places below expected, or relegated when not
-- expected to be), the board sacks the manager. Same terms as the end-of-deal
-- sack: full market value credited to the club, 2-season re-hire block.
-- (Cup targets only rescue a 'slight' miss, so they never prevent this.)
--
-- Injected into the live manager_process_season_end so earlier in-place
-- patches (cup rescue) are kept. Also adds inbox wording for both sacks.
-- Safe to re-run.
-- =============================================================================

DO $inject_year1$
DECLARE
  v_def text;
  v_marker text := 'sacked_year1_club_expectation';
  v_old text := '    IF coalesce(v_mgr.contract_seasons_remaining, 0) > 1 THEN';
  v_new text := $new$    IF coalesce(v_mgr.contract_seasons_remaining, 0) > 1
       AND public.club_expectation_band_for_season(v_mgr.contracted_club, v_season.id)
           IN ('bad', 'abysmal') THEN
      -- Year 1 of the deal, club badly missed expectation → board sack
      v_fail_club := v_mgr.contracted_club;
      PERFORM public.manager_release_from_club(
        v_mgr.id,
        v_fail_club::text,
        v_mgr.market_value::numeric,
        'transfer_sale'::text,
        format(
          'Manager sacked after season 1 — club badly missed expectation (%s)',
          coalesce(v_mgr.name, v_mgr.id::text)
        )::text,
        jsonb_build_object(
          'season_end', true,
          'club_expectation_failed', true,
          'year1_sack', true,
          'exit_kind', 'club_sack',
          'position', v_pos
        )::jsonb
      );

      v_block_err := NULL;
      BEGIN
        PERFORM public.manager_rehire_block_record(
          v_fail_club, v_mgr.id, v_season.id, 2, 'club_expectation_failed'
        );
      EXCEPTION WHEN OTHERS THEN
        v_block_err := SQLERRM;
      END;

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_fail_club,
        'action', 'sacked_year1_club_expectation',
        'exit_kind', 'club_sack',
        'position', v_pos,
        'target_met', v_met,
        'payout', v_mgr.market_value,
        'rehire_block_error', v_block_err
      );
    ELSIF coalesce(v_mgr.contract_seasons_remaining, 0) > 1 THEN$new$;
BEGIN
  SELECT pg_get_functiondef('public.manager_process_season_end()'::regprocedure) INTO v_def;
  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'manager_process_season_end already has the year-1 sack';
  ELSIF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'manager_process_season_end: year-1 branch not found — sack not applied';
  ELSE
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$inject_year1$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_manager_season_end(p_results jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_club text;
  v_action text;
  v_body text;
  v_title text;
BEGIN
  IF p_results IS NULL OR jsonb_typeof(p_results) <> 'array' THEN
    RETURN;
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_results)
  LOOP
    v_club := v_row ->> 'club';
    v_action := v_row ->> 'action';
    IF v_club IS NULL OR v_club = '' THEN
      CONTINUE;
    END IF;

    v_title := CASE v_action
      WHEN 'renewal_available' THEN 'Manager renewal available'
      WHEN 'released_failed_deal' THEN 'Manager released'
      WHEN 'released_renewal_lapsed' THEN 'Manager released'
      WHEN 'released' THEN 'Manager released'
      WHEN 'sacked_club_expectation' THEN 'Manager sacked by the board'
      WHEN 'sacked_year1_club_expectation' THEN 'Manager sacked by the board'
      WHEN 'season_tick' THEN 'Manager season reviewed'
      WHEN 'awaiting_renewal' THEN 'Manager renewal pending'
      ELSE 'Manager update'
    END;

    v_body := CASE v_action
      WHEN 'season_tick' THEN format(
        'Your manager finished %s (%s). Contract continues — %s season(s) remaining on this deal.',
        coalesce(v_row ->> 'position', '?'),
        CASE WHEN (v_row ->> 'target_met') = 'true' THEN 'target met' WHEN (v_row ->> 'target_met') = 'false' THEN 'target missed' ELSE 'no evaluation' END,
        coalesce(v_row ->> 'seasons_remaining', '?')
      )
      WHEN 'renewal_available' THEN format(
        'Your manager completed their 2-season deal (finished %s this season). They hit their target in at least one season — renew them from Club Details or Squad in June or July. If not renewed before August starts, they are released for market value.',
        coalesce(v_row ->> 'position', '?')
      )
      WHEN 'released_failed_deal' THEN format(
        'Your manager missed their target in both seasons of the deal (finished %s this season). They have been released for market value; your club cannot re-sign them for two seasons.',
        coalesce(v_row ->> 'position', '?')
      )
      WHEN 'sacked_club_expectation' THEN
        'The club missed its season expectation in both seasons of your manager''s deal, so the board has sacked them. Your club received their market value and cannot re-sign them for two seasons.'
      WHEN 'sacked_year1_club_expectation' THEN format(
        'The club finished %s — 3 or more places below the board''s expectation — in the first season of your manager''s deal, so the board has sacked them. Your club received their market value and cannot re-sign them for two seasons.',
        coalesce(v_row ->> 'position', '?')
      )
      WHEN 'released_renewal_lapsed' THEN
        'Your manager was eligible for renewal but was not renewed before August. They have been released for market value.'
      WHEN 'released' THEN format(
        'Your manager missed the league target (finished %s). They have been released; your club received market-value compensation.',
        coalesce(v_row ->> 'position', '?')
      )
      WHEN 'awaiting_renewal' THEN
        'Your manager is still awaiting renewal on Club Details / Squad. Renew in June or July — if not renewed before August starts, they will be released for market value.'
      ELSE format('Manager review: %s', v_action)
    END;

    PERFORM public.owner_inbox_send(
      'season_overview',
      v_title,
      v_body,
      v_club,
      NULL, NULL, NULL, NULL, NULL,
      'club_details.html',
      format('mgr_end:%s:%s:%s', v_club, v_action, coalesce(v_row ->> 'manager_id', '')),
      NULL, NULL
    );
  END LOOP;
END;
$function$;

-- Season Review projection: show the year-1 sack
DO $inject_review$
DECLARE
  v_def text;
  v_marker text := 'Sacked after season 1';
  v_old text := $old$      ELSIF coalesce(v_mgr.contract_seasons_remaining, 0) > 1 THEN
        v_code := 'continues';$old$;
  v_new text := $new$      ELSIF coalesce(v_mgr.contract_seasons_remaining, 0) > 1
            AND v_band IN ('bad', 'abysmal') THEN
        v_code := 'sacked';
        v_text := format(
          'Sacked after season 1 — club is %s places below expectation (bad miss or worse). Club receives his market value (₿%s); 2-season re-hire ban.',
          greatest(coalesce(v_c.table_position, 0) - coalesce(v_expected, 0), 0),
          to_char(coalesce(v_mgr.market_value, 0), 'FM999,999,999')
        );
      ELSIF coalesce(v_mgr.contract_seasons_remaining, 0) > 1 THEN
        v_code := 'continues';$new$;
BEGIN
  IF to_regprocedure('public.season_review_board()') IS NULL THEN
    RAISE NOTICE 'season_review_board not installed — run season_review_projection_20261007.sql first';
    RETURN;
  END IF;
  SELECT pg_get_functiondef('public.season_review_board()'::regprocedure) INTO v_def;
  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'season_review_board already shows the year-1 sack';
  ELSIF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'season_review_board: year-1 branch not found';
  ELSE
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$inject_review$;

NOTIFY pgrst, 'reload schema';
