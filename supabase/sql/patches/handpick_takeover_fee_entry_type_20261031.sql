-- Club takeover Fee as its own ledger entry_type (separate season-accounts line).
-- Safe re-run.

SELECT public.gpsl_ledger_ensure_entry_types(ARRAY['club_takeover_fee']);

CREATE OR REPLACE FUNCTION public.handpick_apply_takeover_finances(
  p_club_short_name text,
  p_via_claim boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_name text;
  v_bal numeric := 0;
  v_target numeric := public.handpick_target_balance();
  v_stadium numeric := 0;
  v_delta numeric := 0;
  v_start_ledger bigint;
  v_fee_ledger bigint;
  v_claim boolean := coalesce(p_via_claim, false);
  v_dup text;
BEGIN
  IF v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  SELECT c."Club" INTO v_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_dup := 'handpick_takeover_' || v_club || '_' || to_char(now() AT TIME ZONE 'utc', 'YYYYMMDD');

  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE upper(l.club_short_name) = v_club
      AND (
        l.entry_type = 'club_takeover_fee'
        OR (
          l.entry_type = 'infra_purchase'
          AND coalesce(l.metadata->>'kind', '') = 'club_takeover_fee'
        )
      )
      AND coalesce(l.metadata->>'source', '') = 'handpick_mid_season_takeover'
      AND l.created_at >= (now() - interval '2 days')
  ) THEN
    SELECT coalesce(f.balance, 0) INTO v_bal
    FROM public."Club_Finances" f
    WHERE upper(f.club_name) = v_club;
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'takeover_fee_already_posted',
      'club', v_club,
      'balance', v_bal,
      'stadium_cost', v_stadium,
      'starting_balance', v_target
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE upper(f.club_name) = v_club
  ) THEN
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_club, 0);
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_bal
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club
  FOR UPDATE;

  v_delta := v_target - coalesce(v_bal, 0);
  IF v_delta <> 0 THEN
    v_start_ledger := public.post_club_ledger(
      v_club,
      'adjustment',
      v_delta,
      format(
        'Mid-season club takeover — starting balance → %s (was %s)',
        to_char(v_target, 'FM999,999,999,990'),
        to_char(coalesce(v_bal, 0), 'FM999,999,999,990')
      ),
      jsonb_build_object(
        'source', 'handpick_mid_season_takeover',
        'kind', 'takeover_starting_balance',
        'club', v_club,
        'balance_before', v_bal,
        'target_balance', v_target,
        'delta', v_delta,
        'via_claim', v_claim
      ),
      NULL,
      NULL,
      true,
      true
    );
  END IF;

  IF v_stadium > 0 THEN
    v_fee_ledger := public.post_club_ledger(
      v_club,
      'club_takeover_fee',
      -v_stadium,
      format(
        'Club takeover Fee — Stadium %s (%s) — ₿%s (capacity × stadium rate)',
        coalesce(v_name, v_club),
        v_club,
        to_char(v_stadium, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'source', 'handpick_mid_season_takeover',
        'kind', 'club_takeover_fee',
        'club', v_club,
        'stadium_cost', v_stadium,
        'starting_budget', v_target,
        'dup_key', v_dup,
        'via_claim', v_claim,
        'note', 'Same fee as starting-owner stadium purchase; labelled as buying the club'
      ),
      NULL,
      NULL,
      false,
      true
    );
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_bal
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'skipped', false,
    'club', v_club,
    'club_name', v_name,
    'starting_balance', v_target,
    'stadium_cost', v_stadium,
    'balance_after', v_bal,
    'starting_ledger_id', v_start_ledger,
    'takeover_fee_ledger_id', v_fee_ledger,
    'via_claim', v_claim
  );
END;
$function$;

UPDATE public.competition_finance_ledger
SET entry_type = 'club_takeover_fee'
WHERE id = 52488
  AND upper(club_short_name) = 'MAR'
  AND entry_type = 'infra_purchase'
  AND coalesce(metadata->>'kind', '') = 'club_takeover_fee';

NOTIFY pgrst, 'reload schema';

SELECT id, entry_type, amount, left(description, 80) AS description
FROM public.competition_finance_ledger
WHERE upper(club_short_name) = 'MAR'
  AND entry_type IN ('infra_purchase', 'club_takeover_fee')
ORDER BY created_at;
