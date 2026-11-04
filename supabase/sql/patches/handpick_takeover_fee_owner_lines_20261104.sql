-- =============================================================================
-- Club takeover Fee: stamp owner on each charge; unique season-accounts lines
-- =============================================================================
-- Finances was collapsing every club_takeover_fee into one "Club takeover Fee"
-- breakdown. Store owner_tag / owner_id on each post and label each takeover
-- separately (owner + date). Backfill existing rows where possible.
-- =============================================================================

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
  v_owner_id uuid;
  v_owner_tag text;
  v_bal numeric := 0;
  v_target numeric := public.handpick_target_balance();
  v_stadium numeric := 0;
  v_delta numeric := 0;
  v_start_ledger bigint;
  v_fee_ledger bigint;
  v_claim boolean := coalesce(p_via_claim, false);
  v_dup text;
  v_fee_desc text;
  v_uk_date text;
BEGIN
  IF v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  SELECT
    c."Club",
    c.owner_id,
    nullif(btrim(c.owner), '')
  INTO v_name, v_owner_id, v_owner_tag
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  -- Prefer registry Discord tag when owner is linked
  IF v_owner_id IS NOT NULL THEN
    v_owner_tag := coalesce(
      (
        SELECT nullif(btrim(r.owner_tag), '')
        FROM public.gpsl_owner_registry r
        WHERE r.owner_id = v_owner_id
        LIMIT 1
      ),
      v_owner_tag,
      (
        SELECT nullif(split_part(u.email::text, '@', 1), '')
        FROM auth.users u
        WHERE u.id = v_owner_id
        LIMIT 1
      )
    );
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_dup := 'handpick_takeover_' || v_club || '_' || to_char(now() AT TIME ZONE 'utc', 'YYYYMMDD');
  v_uk_date := to_char(timezone('Europe/London', now()), 'DD Mon YYYY');

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
    -- If fee already posted this cycle but owner was vacant at the time, stamp now
    IF v_owner_tag IS NOT NULL OR v_owner_id IS NOT NULL THEN
      PERFORM public.handpick_stamp_takeover_fee_owner(v_club, v_owner_id, v_owner_tag);
    END IF;
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'takeover_fee_already_posted',
      'club', v_club,
      'balance', v_bal,
      'stadium_cost', v_stadium,
      'starting_balance', v_target,
      'owner_tag', v_owner_tag,
      'owner_id', v_owner_id
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
        'via_claim', v_claim,
        'owner_id', v_owner_id,
        'owner_tag', v_owner_tag
      ),
      NULL,
      NULL,
      true,
      true
    );
  END IF;

  IF v_stadium > 0 THEN
    v_fee_desc := CASE
      WHEN v_owner_tag IS NOT NULL AND btrim(v_owner_tag) <> '' THEN
        format(
          'Club takeover Fee — %s · %s — Stadium %s (%s) — ₿%s (capacity × stadium rate)',
          v_owner_tag,
          v_uk_date,
          coalesce(v_name, v_club),
          v_club,
          to_char(v_stadium, 'FM999,999,999,999')
        )
      ELSE
        format(
          'Club takeover Fee — vacant open · %s — Stadium %s (%s) — ₿%s (capacity × stadium rate)',
          v_uk_date,
          coalesce(v_name, v_club),
          v_club,
          to_char(v_stadium, 'FM999,999,999,999')
        )
    END;

    v_fee_ledger := public.post_club_ledger(
      v_club,
      'club_takeover_fee',
      -v_stadium,
      v_fee_desc,
      jsonb_build_object(
        'source', 'handpick_mid_season_takeover',
        'kind', 'club_takeover_fee',
        'club', v_club,
        'stadium_cost', v_stadium,
        'starting_budget', v_target,
        'dup_key', v_dup,
        'via_claim', v_claim,
        'owner_id', v_owner_id,
        'owner_tag', v_owner_tag,
        'takeover_uk_date', v_uk_date,
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
    'via_claim', v_claim,
    'owner_tag', v_owner_tag,
    'owner_id', v_owner_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_apply_takeover_finances(text, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_apply_takeover_finances(text, boolean)
  TO authenticated, service_role;

-- Stamp owner onto the latest unowned takeover fee for a club (claim after vacant open)
CREATE OR REPLACE FUNCTION public.handpick_stamp_takeover_fee_owner(
  p_club_short_name text,
  p_owner_id uuid DEFAULT NULL,
  p_owner_tag text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_owner_id uuid := p_owner_id;
  v_owner_tag text := nullif(btrim(coalesce(p_owner_tag, '')), '');
  v_row public.competition_finance_ledger%ROWTYPE;
  v_uk_date text;
  v_name text;
  v_stadium numeric;
  v_meta jsonb;
  v_n int := 0;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  IF v_owner_id IS NULL OR v_owner_tag IS NULL THEN
    SELECT c.owner_id, nullif(btrim(c.owner), ''), c."Club"
    INTO v_owner_id, v_owner_tag, v_name
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;
  ELSE
    SELECT c."Club" INTO v_name FROM public."Clubs" c WHERE c."ShortName" = v_club;
  END IF;

  IF v_owner_id IS NOT NULL AND (v_owner_tag IS NULL OR v_owner_tag = '') THEN
    SELECT coalesce(
      nullif(btrim(r.owner_tag), ''),
      nullif(split_part(u.email::text, '@', 1), '')
    )
    INTO v_owner_tag
    FROM auth.users u
    LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = u.id
    WHERE u.id = v_owner_id
    LIMIT 1;
  END IF;

  IF v_owner_tag IS NULL OR v_owner_tag = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_owner_tag');
  END IF;

  FOR v_row IN
    SELECT l.*
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
      AND (
        coalesce(l.metadata->>'owner_tag', '') = ''
        OR l.metadata->>'owner_tag' IS NULL
      )
    ORDER BY l.created_at DESC
    LIMIT 3
  LOOP
    v_uk_date := coalesce(
      nullif(btrim(v_row.metadata->>'takeover_uk_date'), ''),
      to_char(timezone('Europe/London', v_row.created_at), 'DD Mon YYYY')
    );
    v_stadium := coalesce(
      nullif(v_row.metadata->>'stadium_cost', '')::numeric,
      abs(v_row.amount)
    );
    v_meta := coalesce(v_row.metadata, '{}'::jsonb)
      || jsonb_build_object(
        'owner_id', v_owner_id,
        'owner_tag', v_owner_tag,
        'takeover_uk_date', v_uk_date,
        'owner_stamped_at', now()
      );

    UPDATE public.competition_finance_ledger
    SET
      metadata = v_meta,
      description = format(
        'Club takeover Fee — %s · %s — Stadium %s (%s) — ₿%s (capacity × stadium rate)',
        v_owner_tag,
        v_uk_date,
        coalesce(v_name, v_club),
        v_club,
        to_char(v_stadium, 'FM999,999,999,999')
      )
    WHERE id = v_row.id;

    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'owner_tag', v_owner_tag,
    'stamped', v_n
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_stamp_takeover_fee_owner(text, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_stamp_takeover_fee_owner(text, uuid, text)
  TO authenticated, service_role;

-- Wire stamp into claim after handpick set (owner already on Clubs)
DO $wire$
DECLARE
  v_oid oid;
  v_def text;
  v_marker text := 'handpick_stamp_takeover_fee_owner';
  v_snip text;
BEGIN
  v_oid := to_regprocedure('public.waiting_list_claim_vacant_club(text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'waiting_list_claim_vacant_club missing — stamp wire skipped';
    RETURN;
  END IF;
  v_def := pg_get_functiondef(v_oid);
  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Claim already stamps takeover fee owner';
    RETURN;
  END IF;

  -- Insert after successful handpick_set block, before final RETURN
  v_snip :=
    E'\n  IF to_regprocedure(''public.handpick_stamp_takeover_fee_owner(text,uuid,text)'') IS NOT NULL THEN\n'
    || E'    PERFORM public.handpick_stamp_takeover_fee_owner(v_club, v_uid, v_tag);\n'
    || E'  END IF;\n';

  IF position('handpick_intake'', true' IN v_def) > 0
     AND position(v_snip IN v_def) = 0 THEN
    -- Prefer insert just before the final RETURN jsonb_build_object( ok true mode mid_season
    IF position(E'  RETURN jsonb_build_object(\n    ''ok'', true,\n    ''mode'', ''mid_season''' IN v_def) > 0 THEN
      v_def := replace(
        v_def,
        E'  RETURN jsonb_build_object(\n    ''ok'', true,\n    ''mode'', ''mid_season''',
        v_snip || E'  RETURN jsonb_build_object(\n    ''ok'', true,\n    ''mode'', ''mid_season'''
      );
      EXECUTE v_def;
      RAISE NOTICE 'Wired handpick_stamp_takeover_fee_owner into waiting_list_claim_vacant_club';
    ELSE
      RAISE NOTICE 'Claim function shape changed — stamp not auto-wired; apply_takeover still reads Clubs.owner on post';
    END IF;
  END IF;
END;
$wire$;

-- Backfill owner_tag on historical takeover fees from Clubs.owner when single-owner club
-- or nearest owner_assigned_at (best-effort)
UPDATE public.competition_finance_ledger l
SET
  metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
    'owner_tag', c.owner,
    'owner_id', c.owner_id,
    'takeover_uk_date', to_char(timezone('Europe/London', l.created_at), 'DD Mon YYYY'),
    'owner_backfill', 'current_club_owner'
  ),
  description = format(
    'Club takeover Fee — %s · %s — Stadium %s (%s) — ₿%s (capacity × stadium rate)',
    c.owner,
    to_char(timezone('Europe/London', l.created_at), 'DD Mon YYYY'),
    coalesce(c."Club", l.club_short_name),
    l.club_short_name,
    to_char(abs(l.amount), 'FM999,999,999,999')
  )
FROM public."Clubs" c
WHERE upper(c."ShortName") = upper(l.club_short_name)
  AND c.owner IS NOT NULL
  AND btrim(c.owner) <> ''
  AND l.entry_type = 'club_takeover_fee'
  AND coalesce(l.metadata->>'source', '') = 'handpick_mid_season_takeover'
  AND (
    coalesce(l.metadata->>'owner_tag', '') = ''
    OR l.metadata->>'owner_tag' IS NULL
  )
  -- Only stamp when this is the latest fee for the club (avoid wrong owner on older cycles)
  AND l.id = (
    SELECT l2.id
    FROM public.competition_finance_ledger l2
    WHERE upper(l2.club_short_name) = upper(l.club_short_name)
      AND l2.entry_type = 'club_takeover_fee'
      AND coalesce(l2.metadata->>'source', '') = 'handpick_mid_season_takeover'
    ORDER BY l2.created_at DESC
    LIMIT 1
  );

-- Vacant / no-owner fees: at least stamp the UK date into metadata for UI labels
UPDATE public.competition_finance_ledger l
SET metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
  'takeover_uk_date', to_char(timezone('Europe/London', l.created_at), 'DD Mon YYYY')
)
WHERE l.entry_type = 'club_takeover_fee'
  AND coalesce(l.metadata->>'source', '') = 'handpick_mid_season_takeover'
  AND (
    coalesce(l.metadata->>'takeover_uk_date', '') = ''
    OR l.metadata->>'takeover_uk_date' IS NULL
  );

NOTIFY pgrst, 'reload schema';

SELECT
  l.id,
  l.club_short_name,
  l.metadata->>'owner_tag' AS owner_tag,
  l.metadata->>'takeover_uk_date' AS uk_date,
  left(l.description, 90) AS desc_head
FROM public.competition_finance_ledger l
WHERE l.entry_type = 'club_takeover_fee'
ORDER BY l.created_at DESC
LIMIT 15;