-- =============================================================================
-- Migrate legacy Bookies club ledger lines → owner wallet (Building Society)
--
-- For each competition_finance_ledger bookies_expenditure / bookies_income:
--   1) Resolve owner (bet row, else club owner)
--   2) Post same amount/type/description to owner_finance_ledger (keep created_at)
--   3) Reverse Club_Finances.balance
--   4) Point bookies_bets.ledger_* at the new owner ledger id
--   5) Delete the club ledger row
--
-- Idempotent. Dry-run: p_apply = false.
-- Prerequisites: owner wallet schema + _post helpers / ensure_row.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_migrate_bookies_club_to_owner_wallet(
  p_apply boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
  v_owner uuid;
  v_new_id bigint;
  v_moved int := 0;
  v_skipped int := 0;
  v_no_owner int := 0;
  v_already int := 0;
  v_club_delta numeric := 0;
  v_samples jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR r IN
    SELECT
      l.id,
      l.season_id,
      l.club_short_name,
      l.entry_type,
      l.amount,
      l.description,
      l.metadata,
      l.created_at
    FROM public.competition_finance_ledger l
    WHERE l.entry_type IN ('bookies_expenditure', 'bookies_income')
    ORDER BY l.id
  LOOP
    -- Already migrated to an owner ledger?
    IF EXISTS (
      SELECT 1
      FROM public.owner_finance_ledger o
      WHERE o.metadata->>'migrated_from_club_ledger_id' = r.id::text
    ) THEN
      -- Club row may still exist if a prior run failed mid-way — clean up
      IF p_apply THEN
        IF EXISTS (SELECT 1 FROM public.competition_finance_ledger c WHERE c.id = r.id) THEN
          UPDATE public."Club_Finances" f
          SET balance = round(f.balance - r.amount, 2)
          WHERE f.club_name = r.club_short_name;
          DELETE FROM public.competition_finance_ledger WHERE id = r.id;
        END IF;
      END IF;
      v_already := v_already + 1;
      CONTINUE;
    END IF;

    -- Owner from bet stake / payout link
    SELECT b.owner_id INTO v_owner
    FROM public.bookies_bets b
    WHERE b.ledger_stake_id = r.id OR b.ledger_payout_id = r.id
    ORDER BY b.id
    LIMIT 1;

    IF v_owner IS NULL THEN
      SELECT c.owner_id INTO v_owner
      FROM public."Clubs" c
      WHERE c."ShortName" = r.club_short_name
      LIMIT 1;
    END IF;

    IF v_owner IS NULL THEN
      v_no_owner := v_no_owner + 1;
      IF jsonb_array_length(v_samples) < 12 THEN
        v_samples := v_samples || jsonb_build_array(jsonb_build_object(
          'club_ledger_id', r.id,
          'club', r.club_short_name,
          'entry_type', r.entry_type,
          'amount', r.amount,
          'reason', 'no_owner'
        ));
      END IF;
      CONTINUE;
    END IF;

    IF NOT p_apply THEN
      v_moved := v_moved + 1;
      v_club_delta := v_club_delta - r.amount; -- club balance change if applied (reverse)
      IF jsonb_array_length(v_samples) < 12 THEN
        v_samples := v_samples || jsonb_build_array(jsonb_build_object(
          'club_ledger_id', r.id,
          'club', r.club_short_name,
          'owner_id', v_owner,
          'entry_type', r.entry_type,
          'amount', r.amount,
          'description', r.description
        ));
      END IF;
      CONTINUE;
    END IF;

    PERFORM public.owner_wallet_ensure_row(v_owner);

    INSERT INTO public.owner_finance_ledger (
      owner_id, entry_type, amount, description, metadata, season_id, created_at
    )
    VALUES (
      v_owner,
      r.entry_type,
      r.amount,
      r.description,
      coalesce(r.metadata, '{}'::jsonb) || jsonb_build_object(
        'wallet', 'owner',
        'migrated_from_club_ledger_id', r.id,
        'migrated_from_club', r.club_short_name,
        'migrated_at', now()
      ),
      r.season_id,
      r.created_at
    )
    RETURNING id INTO v_new_id;

    UPDATE public.owner_wallets
    SET
      balance = round(balance + r.amount, 2),
      updated_at = now()
    WHERE owner_id = v_owner;

    -- Reverse club books (expenditure was negative → add back; income positive → remove)
    UPDATE public."Club_Finances" f
    SET balance = round(f.balance - r.amount, 2)
    WHERE f.club_name = r.club_short_name;

    UPDATE public.bookies_bets
    SET ledger_stake_id = v_new_id,
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('wallet', 'owner')
    WHERE ledger_stake_id = r.id;

    UPDATE public.bookies_bets
    SET ledger_payout_id = v_new_id,
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('wallet', 'owner')
    WHERE ledger_payout_id = r.id;

    DELETE FROM public.competition_finance_ledger WHERE id = r.id;

    v_moved := v_moved + 1;
    v_club_delta := v_club_delta - r.amount;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'apply', coalesce(p_apply, false),
    'moved', v_moved,
    'already_migrated', v_already,
    'skipped_no_owner', v_no_owner,
    'skipped_other', v_skipped,
    'net_club_balance_change_if_applied', v_club_delta,
    'note', CASE
      WHEN coalesce(p_apply, false)
        THEN 'Club Bookies lines moved to owner wallets; club balances reversed.'
      ELSE 'Dry-run only. Re-run with p_apply := true to apply.'
    END,
    'samples', v_samples
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_migrate_bookies_club_to_owner_wallet(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Convenience: dry-run notice when pasted in SQL editor
-- SELECT public.admin_migrate_bookies_club_to_owner_wallet(false);
-- SELECT public.admin_migrate_bookies_club_to_owner_wallet(true);
