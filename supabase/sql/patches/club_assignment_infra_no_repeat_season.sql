-- =============================================================================
-- Fix: stadium infra_purchase must not reappear every new season
--
-- Bug: club_assignment_finance_display / appendAssignmentInfraPurchaseLedger
-- treated "no infra_purchase on the *current* season ledger" as missing, so
-- Season 2 accounts synthesised Yamaha Stadium (etc.) again for clubs that
-- already paid in Season 1. owner_apply also only de-duped within the current
-- season, so a repair could re-post + reset balance.
--
-- Fix:
--  1) Consider infra already paid if this club+owner has any prior
--     infra_purchase (any season).
--  2) Harden owner_apply_club_assignment_finances to skip re-charge.
--  3) Optional cleanup: remove current-season duplicate assignment posts and
--     credit the club balance (amount was negative on ledger).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_has_assignment_infra_purchase(
  p_club_short_name text,
  p_owner_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_owner text := nullif(p_owner_id::text, '');
BEGIN
  IF v_club = '' THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND l.entry_type = 'infra_purchase'
      AND coalesce(l.metadata->>'source', 'club_assignment') IN (
        'club_assignment', 'club_auction', 'assignment'
      )
      AND (
        v_owner IS NULL
        OR coalesce(l.metadata->>'owner_id', '') = ''
        OR coalesce(l.metadata->>'owner_id', '') = v_owner
      )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_has_assignment_infra_purchase(text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.club_assignment_finance_display(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_row record;
  v_stadium_cost numeric;
  v_total_debit numeric;
  v_season_id bigint;
  v_ledger_posted boolean := false;
  v_display_name text;
  v_starting_budget numeric;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'club_required');
  END IF;

  SELECT
    c."Club" AS club_name,
    coalesce(nullif(btrim(c."Stadium"), ''), c."Club", c."ShortName") AS stadium_name,
    c.owner_id,
    l.winning_bid,
    l.updated_at AS settled_at
  INTO v_row
  FROM public."Clubs" c
  LEFT JOIN public."Club_Auction_Listings" l
    ON l.club_short_name = c."ShortName"
   AND l.transfer_completed = true
   AND l.winning_owner_id = c.owner_id
  WHERE c."ShortName" = v_club;

  IF NOT FOUND OR v_row.owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'show_in_accounts', false);
  END IF;

  v_stadium_cost := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_total_debit := greatest(coalesce(nullif(v_row.winning_bid, 0), v_stadium_cost), v_stadium_cost);
  v_display_name := v_row.stadium_name;
  v_season_id := public.competition_finances_current_season_id();

  -- Already paid in any season (do not synthesise again for Season 2+)
  v_ledger_posted := public.club_has_assignment_infra_purchase(v_club, v_row.owner_id);

  SELECT coalesce(
    nullif((l.metadata->>'starting_budget')::numeric, 0),
    public.club_auction_default_starting_balance()
  )
  INTO v_starting_budget
  FROM public.competition_finance_ledger l
  WHERE l.club_short_name = v_club
    AND l.entry_type = 'infra_purchase'
  ORDER BY l.created_at ASC
  LIMIT 1;

  IF coalesce(v_starting_budget, 0) <= 0 THEN
    v_starting_budget := public.club_auction_default_starting_balance();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'show_in_accounts', (v_total_debit > 0 AND NOT v_ledger_posted),
    'club_short_name', v_club,
    'club_name', v_row.club_name,
    'stadium_name', v_display_name,
    'stadium_cost', v_stadium_cost,
    'total_debit', v_total_debit,
    'starting_budget', v_starting_budget,
    'ledger_posted', v_ledger_posted,
    'season_id', v_season_id,
    'settled_at', v_row.settled_at,
    'ledger_description', format('Stadium purchase — %s', v_display_name)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_assignment_finance_display(text) TO authenticated;

-- Harden apply: never re-set balance / re-post if this owner already has infra for club
CREATE OR REPLACE FUNCTION public.owner_apply_club_assignment_finances(
  p_club_short_name text,
  p_owner_id uuid,
  p_starting_budget numeric,
  p_total_debit numeric DEFAULT NULL,
  p_source text DEFAULT 'club_assignment',
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_stadium numeric;
  v_debit numeric;
  v_starting numeric;
  v_balance numeric;
  v_season_id bigint;
  v_club_name text;
  v_desc text;
  v_meta jsonb;
  v_ledger_id bigint;
  v_dup_key text;
  v_existing_balance numeric;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_debit := coalesce(nullif(p_total_debit, 0), v_stadium);
  v_debit := greatest(v_debit, v_stadium);
  v_starting := greatest(coalesce(p_starting_budget, 0), 0);
  v_balance := greatest(v_starting - v_debit, 0);

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_meta := coalesce(p_metadata, '{}'::jsonb)
    || jsonb_build_object(
      'source', coalesce(nullif(btrim(p_source), ''), 'club_assignment'),
      'owner_id', p_owner_id,
      'stadium_cost', v_stadium,
      'total_debit', v_debit,
      'starting_budget', v_starting
    );

  v_dup_key := coalesce(v_meta->>'listing_id', v_meta->>'assignment_key', p_owner_id::text);

  -- Already charged this owner for this club (any season) — do not wipe balance
  IF public.club_has_assignment_infra_purchase(v_club, p_owner_id) THEN
    SELECT balance INTO v_existing_balance
    FROM public."Club_Finances"
    WHERE club_name = v_club;

    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'infra_purchase_already_posted',
      'club_short_name', v_club,
      'stadium_cost', v_stadium,
      'total_debit', v_debit,
      'starting_budget', v_starting,
      'balance', v_existing_balance,
      'season_id', public.competition_finances_current_season_id()
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_club
  ) THEN
    UPDATE public."Club_Finances"
    SET balance = v_balance
    WHERE club_name = v_club;
  ELSE
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_club, v_balance);
  END IF;

  v_season_id := public.competition_finances_current_season_id();

  IF v_debit > 0 AND v_season_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
        AND l.season_id = v_season_id
        AND l.entry_type = 'infra_purchase'
        AND coalesce(l.metadata->>'source', '') = coalesce(nullif(btrim(p_source), ''), 'club_assignment')
        AND coalesce(l.metadata->>'dup_key', l.metadata->>'listing_id', '') = v_dup_key
    ) THEN
      v_desc := coalesce(
        nullif(btrim(p_description), ''),
        format(
          'Stadium purchase — %s (%s) — ₿%s (capacity × ₿1,000)',
          coalesce(v_club_name, v_club),
          v_club,
          to_char(v_stadium, 'FM999,999,999,999')
        )
      );

      IF v_debit > v_stadium THEN
        v_desc := v_desc || format(
          ' + auction premium ₿%s',
          to_char(v_debit - v_stadium, 'FM999,999,999,999')
        );
      END IF;

      v_meta := v_meta || jsonb_build_object('dup_key', v_dup_key);

      v_ledger_id := public.post_club_ledger(
        v_club,
        'infra_purchase',
        -v_debit,
        v_desc,
        v_meta,
        v_season_id,
        NULL,
        false,
        false
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'stadium_cost', v_stadium,
    'total_debit', v_debit,
    'starting_budget', v_starting,
    'balance', v_balance,
    'season_id', v_season_id,
    'ledger_id', v_ledger_id,
    'ledger_skipped_no_season', v_season_id IS NULL AND v_debit > 0
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_apply_club_assignment_finances(
  text, uuid, numeric, numeric, text, jsonb, text
) TO authenticated;

-- ---------------------------------------------------------------------------
-- Cleanup: current-season duplicate assignment stadium posts (credit balance)
-- ---------------------------------------------------------------------------
DO $cleanup$
DECLARE
  v_row record;
  v_credit numeric;
  v_removed int := 0;
BEGIN
  FOR v_row IN
    SELECT
      cur.id,
      cur.club_short_name,
      abs(cur.amount)::numeric AS credit_amt
    FROM public.competition_finance_ledger cur
    JOIN public.competition_seasons s_cur
      ON s_cur.id = cur.season_id
     AND s_cur.is_current = true
    WHERE cur.entry_type = 'infra_purchase'
      AND coalesce(cur.metadata->>'source', 'club_assignment') IN (
        'club_assignment', 'club_auction', 'assignment'
      )
      AND EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger prior
        JOIN public.competition_seasons s_prior
          ON s_prior.id = prior.season_id
         AND coalesce(s_prior.is_current, false) = false
        WHERE prior.club_short_name = cur.club_short_name
          AND prior.entry_type = 'infra_purchase'
          AND coalesce(prior.metadata->>'source', 'club_assignment') IN (
            'club_assignment', 'club_auction', 'assignment'
          )
          AND (
            coalesce(cur.metadata->>'owner_id', '') = ''
            OR coalesce(prior.metadata->>'owner_id', '') = ''
            OR coalesce(prior.metadata->>'owner_id', '') = coalesce(cur.metadata->>'owner_id', '')
          )
      )
  LOOP
    v_credit := coalesce(v_row.credit_amt, 0);
    DELETE FROM public.competition_finance_ledger WHERE id = v_row.id;
    IF v_credit > 0 THEN
      UPDATE public."Club_Finances"
      SET balance = balance + v_credit
      WHERE club_name = v_row.club_short_name;
    END IF;
    v_removed := v_removed + 1;
  END LOOP;

  RAISE NOTICE 'Removed % duplicate current-season stadium infra_purchase row(s)', v_removed;
END;
$cleanup$;

NOTIFY pgrst, 'reload schema';
