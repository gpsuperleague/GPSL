-- =============================================================================
-- Club assign: never re-grant ₿650m starting budget on takeover
--
-- Bug (ACM, 20 Oct): AnoneMouse was admin-linked to AC Milan. Season is still
-- season 1, so club_had_prior_finance_season was false, and the club had no
-- infra_purchase row (prior owner operated without a stadium ledger post).
-- admin_assign therefore called owner_apply_club_assignment_finances, which
-- RESET Club_Finances.balance to ₿650m − stadium and posted a fresh stadium
-- charge — wiping the inherited balance after 73 prior ledger rows.
--
-- Fix:
--   1) club_already_funded_for_assignment — true if the club already has any
--      finance footprint (prior season, any infra_purchase, any ledger row,
--      or an existing Club_Finances row). Takeovers inherit as-is.
--   2) Harden owner_apply_club_assignment_finances + admin_assign_club_owner
--      to skip the starting-budget path when that helper is true.
--   3) Keep club_has_assignment_infra_purchase as any-owner (takeover-safe).
--   4) Repair ACM: remove the duplicate admin_assign stadium row and restore
--      balance to ₿650m + sum(ledger except that row).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_already_funded_for_assignment(
  p_club_short_name text,
  p_current_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_sid bigint := p_current_season_id;
  v_ledger_n int := 0;
BEGIN
  IF v_club = '' THEN
    RETURN false;
  END IF;

  IF v_sid IS NULL THEN
    v_sid := public.competition_finances_current_season_id();
  END IF;

  -- Prior season / continuing club
  IF public.club_had_prior_finance_season(v_club, v_sid) THEN
    RETURN true;
  END IF;

  -- Stadium / assignment starting-budget already posted (any owner, any season)
  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND l.entry_type = 'infra_purchase'
  ) THEN
    RETURN true;
  END IF;

  -- Substantial operating history = prior owner / vacant ops already ran the
  -- club (ACM-style). Tiny pre-link noise (a few rows) must NOT block a true
  -- first-time ₿650m + stadium assign.
  SELECT count(*) INTO v_ledger_n
  FROM public.competition_finance_ledger l
  WHERE l.club_short_name = v_club;

  IF v_ledger_n >= 20 THEN
    RETURN true;
  END IF;

  -- Transfers / releases mean a prior owner already operated the club.
  -- Ignore commercial_advertising-only noise (vacant pitchside ads before first link).
  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND (
        l.entry_type LIKE 'transfer%'
        OR l.entry_type IN ('new_owner_release', 'contract_signing_offer')
      )
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_already_funded_for_assignment(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_already_funded_for_assignment(text, bigint) TO anon;

COMMENT ON FUNCTION public.club_already_funded_for_assignment(text, bigint) IS
  'True when a club already has finances / starting budget history — admin/auction assign must not grant a fresh ₿650m.';

-- Stadium paid once per club (any owner); also true when already funded
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
BEGIN
  IF v_club = '' THEN
    RETURN false;
  END IF;

  IF public.club_already_funded_for_assignment(
    v_club,
    public.competition_finances_current_season_id()
  ) THEN
    RETURN true;
  END IF;

  -- p_owner_id kept for callers; a takeover inherits the previous owner's purchase
  RETURN EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND l.entry_type = 'infra_purchase'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_has_assignment_infra_purchase(text, uuid) TO authenticated;

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
  v_season_id := public.competition_finances_current_season_id();

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

  -- Takeover / continuing / already seeded: never reset balance or re-post stadium
  IF public.club_already_funded_for_assignment(v_club, v_season_id) THEN
    SELECT balance INTO v_existing_balance
    FROM public."Club_Finances"
    WHERE club_name = v_club;

    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'club_already_funded',
      'club_short_name', v_club,
      'stadium_cost', v_stadium,
      'total_debit', v_debit,
      'starting_budget', v_starting,
      'balance', v_existing_balance,
      'season_id', v_season_id
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

  IF v_debit > 0 AND v_season_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
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
    'skipped', false,
    'club_short_name', v_club,
    'stadium_cost', v_stadium,
    'total_debit', v_debit,
    'starting_budget', v_starting,
    'balance', v_balance,
    'ledger_id', v_ledger_id,
    'season_id', v_season_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_apply_club_assignment_finances(
  text, uuid, numeric, numeric, text, jsonb, text
) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_assign_club_owner(
  p_owner_email text,
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_short text := upper(trim(p_club_short_name));
  v_user_id uuid;
  v_club_name text;
  v_replaced_previous boolean := false;
  v_registry_status text;
  v_displaced uuid;
  v_old_club text;
  v_tag text;
  v_display_owner text;
  v_pending numeric;
  v_starting numeric;
  v_fin jsonb;
  v_needs_finance boolean := false;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  IF v_short IS NULL OR v_short = '' THEN
    RAISE EXCEPTION 'Club ShortName is required';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT r.status, r.pending_starting_balance
  INTO v_registry_status, v_pending
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF v_registry_status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived — unarchive before linking to a club';
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short;

  IF v_club_name IS NULL THEN
    RAISE EXCEPTION 'Club ShortName % not found', v_short;
  END IF;

  SELECT c.owner_id INTO v_displaced
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
    AND c.owner_id IS NOT NULL
    AND c.owner_id <> v_user_id
  LIMIT 1;

  IF v_displaced IS NOT NULL THEN
    v_replaced_previous := true;
    PERFORM public.admin_owner_detach_core(v_displaced, 'on_break', 'Displaced by admin club link');
  END IF;

  SELECT c."ShortName"
  INTO v_old_club
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
    AND c."ShortName" <> v_short
  LIMIT 1;

  IF v_old_club IS NOT NULL THEN
    PERFORM public.admin_club_vacate(v_old_club);
  END IF;

  SELECT nullif(btrim(r.owner_tag), '')
  INTO v_tag
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  v_display_owner := coalesce(v_tag, split_part(v_email, '@', 1));

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = v_display_owner
  WHERE "ShortName" = v_short;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Failed to update club %', v_short;
  END IF;

  IF to_regprocedure('public.club_mark_new_owner_tenure(text, bigint)') IS NOT NULL THEN
    PERFORM public.club_mark_new_owner_tenure(v_short);
  END IF;

  -- Fresh ₿650m only when the club has no prior funding / operating history.
  -- Displacing an existing owner is always a takeover — inherit balance.
  v_needs_finance :=
    NOT v_replaced_previous
    AND NOT public.club_already_funded_for_assignment(
      v_short,
      public.competition_finances_current_season_id()
    );

  IF v_needs_finance THEN
    v_starting := greatest(
      coalesce(nullif(v_pending, 0), public.club_auction_default_starting_balance()),
      0
    );

    v_fin := public.owner_apply_club_assignment_finances(
      v_short,
      v_user_id,
      v_starting,
      NULL,
      'admin_assign',
      jsonb_build_object(
        'assignment_key', v_user_id::text || ':' || v_short,
        'dup_key', v_user_id::text || ':' || v_short
      ),
      format('Club assigned — %s (%s)', v_club_name, v_short)
    );
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name, status_changed_at)
  VALUES (v_user_id, 'active', v_tag, v_short, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_short,
      pending_starting_balance = CASE
        WHEN v_needs_finance THEN 0
        ELSE gpsl_owner_registry.pending_starting_balance
      END,
      status_note = NULL,
      status_changed_at = now();

  IF to_regprocedure('public.owner_inbox_send_welcome(uuid, text, timestamptz)') IS NOT NULL THEN
    PERFORM public.owner_inbox_send_welcome(v_user_id, v_short, NULL::timestamptz);
  ELSIF to_regprocedure('public.owner_inbox_send_welcome(uuid, text)') IS NOT NULL THEN
    PERFORM public.owner_inbox_send_welcome(v_user_id, v_short);
  END IF;

  RETURN jsonb_build_object(
    'user_id', v_user_id,
    'email', p_owner_email,
    'club_short_name', v_short,
    'club_name', v_club_name,
    'replaced_previous_owner', v_replaced_previous,
    'from_club_short_name', v_old_club,
    'finances_applied', v_needs_finance,
    'finances', v_fin,
    'new_owner_releases_remaining', 3
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;

-- One-shot ACM repair (20 Oct takeover). Preventative helpers above stop
-- recurrence; do not auto-repair other clubs (small pre-link ledger noise is
-- normal on first assign). Safe re-run via repair log.
CREATE TABLE IF NOT EXISTS public.club_takeover_finance_repair_log (
  id bigserial PRIMARY KEY,
  club_short_name text NOT NULL,
  removed_ledger_id bigint NOT NULL UNIQUE,
  removed_amount numeric NOT NULL,
  balance_before numeric,
  balance_after numeric,
  note text,
  repaired_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.club_takeover_finance_repair_log ENABLE ROW LEVEL SECURITY;

DO $repair$
DECLARE
  v_season bigint := public.competition_finances_current_season_id();
  d record;
  v_start numeric := greatest(coalesce(public.club_auction_default_starting_balance(), 650000000), 0);
  v_sum_other numeric;
  v_bal numeric;
  v_new numeric;
  v_note text;
BEGIN
  IF v_season IS NULL THEN
    RAISE NOTICE 'No current season — skip ACM takeover repair';
    RETURN;
  END IF;

  -- Already repaired (and not reverted)
  IF EXISTS (
    SELECT 1
    FROM public.club_takeover_finance_repair_log g
    WHERE g.club_short_name = 'ACM'
      AND g.note LIKE 'Removed takeover admin_assign stadium%'
      AND g.note NOT LIKE '%REVERTED%'
  ) THEN
    RAISE NOTICE 'ACM takeover repair already applied — skip';
    RETURN;
  END IF;

  FOR d IN
    SELECT
      dup.id AS dup_id,
      dup.club_short_name AS club,
      dup.amount AS dup_amount
    FROM public.competition_finance_ledger dup
    WHERE dup.club_short_name = 'ACM'
      AND dup.entry_type = 'infra_purchase'
      AND dup.season_id = v_season
      AND coalesce(dup.metadata->>'source', '') = 'admin_assign'
      AND NOT EXISTS (
        SELECT 1
        FROM public.club_takeover_finance_repair_log g
        WHERE g.removed_ledger_id = dup.id
      )
    ORDER BY dup.id
  LOOP
    SELECT balance INTO v_bal
    FROM public."Club_Finances"
    WHERE club_name = d.club;

    SELECT coalesce(sum(l.amount), 0) INTO v_sum_other
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = d.club
      AND l.id <> d.dup_id;

    v_new := v_start + v_sum_other;
    v_note := format(
      'Removed takeover admin_assign stadium; balance %s → %s (₿%s opening + other ledger)',
      v_bal, v_new, to_char(v_start, 'FM999,999,999,999')
    );

    DELETE FROM public.competition_finance_ledger WHERE id = d.dup_id;

    UPDATE public."Club_Finances"
    SET balance = v_new
    WHERE club_name = d.club;

    INSERT INTO public.club_takeover_finance_repair_log
      (club_short_name, removed_ledger_id, removed_amount, balance_before, balance_after, note)
    VALUES (d.club, d.dup_id, d.dup_amount, v_bal, v_new, v_note);

    RAISE NOTICE 'Repaired %: %', d.club, v_note;
  END LOOP;
END
$repair$;

NOTIFY pgrst, 'reload schema';

-- Verify helpers + ACM outcome
SELECT jsonb_build_object(
  'already_funded_acm', public.club_already_funded_for_assignment('ACM'),
  'has_infra_acm', public.club_has_assignment_infra_purchase('ACM', NULL),
  'acm_balance', (SELECT balance FROM public."Club_Finances" WHERE club_name = 'ACM'),
  'acm_infra_count', (
    SELECT count(*) FROM public.competition_finance_ledger
    WHERE club_short_name = 'ACM' AND entry_type = 'infra_purchase'
  ),
  'repair_rows', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'club', club_short_name,
      'removed_ledger_id', removed_ledger_id,
      'balance_before', balance_before,
      'balance_after', balance_after,
      'note', note
    ) ORDER BY repaired_at DESC), '[]'::jsonb)
    FROM public.club_takeover_finance_repair_log
    WHERE repaired_at > now() - interval '5 minutes'
  )
) AS verify;
