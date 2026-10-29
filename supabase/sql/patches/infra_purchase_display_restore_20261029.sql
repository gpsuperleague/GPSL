-- =============================================================================
-- Preview (+ optional ledger-only restore) for missing infra_purchase rows
--
-- UI should synthesize these; this patch is for clubs where the row is absent
-- from competition_finance_ledger on the current season.
--
-- Step 1: run the PREVIEW select.
-- Step 2: only if you want ledger rows back (NO cash movement), uncomment the
--         DO $restore$ block and re-run.
-- =============================================================================

WITH cur AS (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
SELECT
  c."ShortName" AS club,
  c."Club" AS club_name,
  public.club_had_prior_finance_season(c."ShortName", cur.id) AS continuing,
  public.club_stadium_infra_purchase_cost(c."ShortName") AS stadium_cost,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger l
    WHERE l.club_short_name = c."ShortName"
      AND l.entry_type = 'infra_purchase'
      AND l.season_id = cur.id
  ) AS has_current_infra,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger_public p
    WHERE p.club_short_name = c."ShortName"
      AND p.entry_type = 'infra_purchase'
  ) AS infra_in_public_view,
  (SELECT balance FROM public."Club_Finances" f WHERE f.club_name = c."ShortName") AS live_balance,
  public.club_assignment_finance_display(c."ShortName")->>'ledger_posted' AS display_ledger_posted,
  public.club_assignment_finance_display(c."ShortName")->>'show_in_accounts' AS display_show,
  public.club_assignment_finance_display(c."ShortName")->>'continuing_club' AS display_continuing,
  public.club_assignment_finance_display(c."ShortName")->>'total_debit' AS display_total_debit
FROM public."Clubs" c
CROSS JOIN cur
WHERE c.owner_id IS NOT NULL
ORDER BY
  (EXISTS (
    SELECT 1 FROM public.competition_finance_ledger l
    WHERE l.club_short_name = c."ShortName"
      AND l.entry_type = 'infra_purchase'
      AND l.season_id = cur.id
  )) ASC,
  c."ShortName";

-- JUB detail
SELECT * FROM public.competition_finance_ledger
WHERE club_short_name = 'JUB' AND entry_type = 'infra_purchase';

SELECT public.club_assignment_finance_display('JUB') AS jub_display;

/*
-- OPTIONAL: ledger-only restore (p_apply_balance := false). Uncomment to run.
DO $restore$
DECLARE
  v_sid bigint;
  v_row record;
  v_cost numeric;
  v_posted int := 0;
BEGIN
  SELECT id INTO v_sid FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1;
  IF v_sid IS NULL THEN RETURN; END IF;

  FOR v_row IN
    SELECT c."ShortName" AS club, c."Club" AS club_name, c.owner_id,
           coalesce(nullif(btrim(c."Stadium"), ''), c."Club", c."ShortName") AS stadium_name
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
  LOOP
    IF public.club_had_prior_finance_season(v_row.club, v_sid) THEN CONTINUE; END IF;
    IF EXISTS (
      SELECT 1 FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_row.club AND l.entry_type = 'infra_purchase' AND l.season_id = v_sid
    ) THEN CONTINUE; END IF;

    v_cost := coalesce(public.club_stadium_infra_purchase_cost(v_row.club), 0);
    IF v_cost <= 0 THEN CONTINUE; END IF;

    PERFORM public.post_club_ledger(
      v_row.club,
      'infra_purchase',
      -v_cost,
      format('Stadium purchase — %s (%s) — ₿%s (capacity × ₿1,000) [display restore]',
        coalesce(v_row.club_name, v_row.club), v_row.club, to_char(v_cost, 'FM999,999,999,999')),
      jsonb_build_object(
        'source', 'display_restore',
        'owner_id', v_row.owner_id,
        'stadium_cost', v_cost,
        'total_debit', v_cost,
        'starting_budget', public.club_auction_default_starting_balance(),
        'restored_at', now()
      ),
      v_sid,
      NULL,
      false,  -- bank leg
      false   -- apply_balance: ledger only, do not re-debit cash
    );
    v_posted := v_posted + 1;
  END LOOP;

  RAISE NOTICE 'ledger-only infra_purchase rows posted: %', v_posted;
END;
$restore$;
*/
