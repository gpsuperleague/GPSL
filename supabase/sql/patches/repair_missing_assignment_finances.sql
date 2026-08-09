-- =============================================================================
-- Repair missing club-assignment finances + restore charge on admin assign
-- =============================================================================
-- Symptom: direct assign links owner_id but leaves Club_Finances at 0 / no
-- infra_purchase ledger row. Finances UI shows synthetic stadium cost from
-- club_assignment_finance_display while current balance stays wrong.
--
-- Cause: owner_club_legacy_owner_text_fix.sql replaced admin_assign_club_owner
-- without calling owner_apply_club_assignment_finances.
--
-- This patch:
--   1) Restores stadium charge on admin_assign_club_owner
--   2) admin_repair_missing_assignment_finances() — backfill all owned clubs
--      that are not continuing and have no infra_purchase yet
-- =============================================================================

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

  -- Charge stadium whenever this club still needs assignment finances
  -- (covers re-link after a previous assign that only set owner_id).
  v_needs_finance :=
    NOT public.club_had_prior_finance_season(
      v_short,
      public.competition_finances_current_season_id()
    )
    AND NOT public.club_has_assignment_infra_purchase(v_short, v_user_id);

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

  IF to_regprocedure('public.owner_inbox_send_welcome(uuid, text)') IS NOT NULL THEN
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
    'finances', v_fin
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_repair_missing_assignment_finances()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_starting numeric;
  v_fin jsonb;
  v_results jsonb := '[]'::jsonb;
  v_fixed int := 0;
  v_skipped int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_row IN
    SELECT
      c."ShortName" AS short_name,
      c."Club" AS club_name,
      c.owner_id,
      coalesce(nullif(r.pending_starting_balance, 0), public.club_auction_default_starting_balance()) AS start_bal,
      coalesce(f.balance, 0) AS cash_before,
      public.club_stadium_infra_purchase_cost(c."ShortName") AS stadium_cost
    FROM public."Clubs" c
    LEFT JOIN public."Club_Finances" f ON f.club_name = c."ShortName"
    LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND NOT public.club_had_prior_finance_season(
        c."ShortName",
        public.competition_finances_current_season_id()
      )
      AND NOT public.club_has_assignment_infra_purchase(c."ShortName", c.owner_id)
    ORDER BY c."ShortName"
  LOOP
    v_starting := greatest(coalesce(v_row.start_bal, 0), 0);

    v_fin := public.owner_apply_club_assignment_finances(
      v_row.short_name,
      v_row.owner_id,
      v_starting,
      NULL,
      'admin_assign_repair',
      jsonb_build_object(
        'assignment_key', v_row.owner_id::text || ':' || v_row.short_name,
        'dup_key', v_row.owner_id::text || ':' || v_row.short_name,
        'repair', true
      ),
      format('Club assigned — %s (%s)', v_row.club_name, v_row.short_name)
    );

    IF coalesce((v_fin->>'skipped')::boolean, false) THEN
      v_skipped := v_skipped + 1;
    ELSE
      v_fixed := v_fixed + 1;
      UPDATE public.gpsl_owner_registry
      SET pending_starting_balance = 0
      WHERE owner_id = v_row.owner_id
        AND coalesce(pending_starting_balance, 0) > 0;
    END IF;

    v_results := v_results || jsonb_build_object(
      'club', v_row.short_name,
      'owner_id', v_row.owner_id,
      'cash_before', v_row.cash_before,
      'stadium_cost', v_row.stadium_cost,
      'starting_budget', v_starting,
      'result', v_fin
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixed', v_fixed,
    'skipped', v_skipped,
    'results', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_repair_missing_assignment_finances() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- One-time backfill for clubs assigned before this fix (Mobra/JUV + peers).
-- Re-run safely: already-posted infra is skipped.
SELECT public.admin_repair_missing_assignment_finances() AS repair_report;
