-- =============================================================================
-- Revert premature owner season salaries (2026-10-22)
--
-- Cause: accidental RPC call to competition_admin_archive_season_followup(1)
-- during a patch-presence check. That runs club_underperformance_process_season,
-- which pays owner_season_salary for clubs currently "on target".
--
-- This script:
--   1) Diagnoses salary ledger rows + related inbox
--   2) Claws back salary amounts (negative ledger) and clears pay dedupe so
--      a real season-end can pay again later
--   3) Soft-hides the "Owner salary paid/withheld" inbox notes
--   4) Locks archive followup so anon JWT cannot call it again
--
-- Review the SELECT diagnostics first, then run the DO block.
-- Safe-ish re-run: clawback only posts once per original ledger id.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0) Diagnose
-- ---------------------------------------------------------------------------
SELECT
  l.id AS ledger_id,
  l.owner_id,
  l.amount,
  l.description,
  l.season_id,
  l.metadata->>'club' AS club,
  l.created_at
FROM public.owner_finance_ledger l
WHERE l.entry_type = 'owner_season_salary'
  AND l.created_at >= timestamptz '2026-10-22 08:00:00+00'
ORDER BY l.created_at DESC;

SELECT
  i.id,
  i.recipient_club_short_name,
  i.title,
  i.dedupe_key,
  i.created_at
FROM public.competition_inbox i
WHERE i.dedupe_key LIKE 'owner_salary:%'
  AND i.created_at >= timestamptz '2026-10-22 08:00:00+00'
ORDER BY i.created_at DESC;

-- Forced listings created in the same accidental run (if any)
-- Optional: forced underperformance listings from the same window (manual review)
SELECT
  l.id AS listing_id,
  l.player_id,
  l.seller_club_id,
  l.status,
  l.created_at
FROM public."Player_Transfer_Listings" l
WHERE l.created_at >= timestamptz '2026-10-22 08:00:00+00'
ORDER BY l.created_at DESC
LIMIT 50;

-- ---------------------------------------------------------------------------
-- 1) Claw back salaries + clear inbox notes
-- ---------------------------------------------------------------------------
DO $revert$
DECLARE
  r record;
  v_club text;
  v_clawed int := 0;
  v_inbox int := 0;
BEGIN
  FOR r IN
    SELECT l.*
    FROM public.owner_finance_ledger l
    WHERE l.entry_type = 'owner_season_salary'
      AND l.amount > 0
      AND l.created_at >= timestamptz '2026-10-22 08:00:00+00'
      AND NOT EXISTS (
        SELECT 1
        FROM public.owner_finance_ledger x
        WHERE x.entry_type = 'owner_season_salary_clawback'
          AND x.metadata->>'reverses_ledger_id' = l.id::text
      )
  LOOP
    v_club := nullif(btrim(coalesce(r.metadata->>'club', '')), '');

    PERFORM public._post_owner_ledger_internal(
      r.owner_id,
      'owner_season_salary_clawback',
      -r.amount,
      format('Clawback — premature owner salary (%s)', coalesce(v_club, 'club')),
      jsonb_build_object(
        'club', v_club,
        'reverses_ledger_id', r.id,
        'source', 'revert_premature_owner_salary_20261022',
        'original_season_id', r.season_id
      ),
      r.season_id,
      true
    );

    -- Soft-delete original pay row's "already_paid" fingerprint by rewriting
    -- metadata club key so season-end can pay again later.
    UPDATE public.owner_finance_ledger
    SET metadata = coalesce(metadata, '{}'::jsonb)
      || jsonb_build_object(
        'club', coalesce(v_club, '') || ':reverted',
        'reverted_at', now(),
        'reverted_by', 'revert_premature_owner_salary_20261022'
      ),
      description = coalesce(description, '') || ' [REVERTED — premature]'
    WHERE id = r.id;

    v_clawed := v_clawed + 1;
  END LOOP;

  UPDATE public.competition_inbox i
  SET
    archived_at = coalesce(i.archived_at, now()),
    read_at = coalesce(i.read_at, now()),
    title = CASE
      WHEN i.title ILIKE '%withheld%' THEN 'Owner salary withheld (void — premature)'
      ELSE 'Owner salary paid (void — premature)'
    END,
    body = coalesce(i.body, '')
      || E'\n\n[Voided: this was posted by accident before season end and has been reversed.]'
  WHERE i.dedupe_key LIKE 'owner_salary:%'
    AND i.created_at >= timestamptz '2026-10-22 08:00:00+00'
    AND coalesce(i.title, '') NOT ILIKE '%void%';

  GET DIAGNOSTICS v_inbox = ROW_COUNT;

  RAISE NOTICE 'Clawed back % salary payment(s); voided % inbox row(s).', v_clawed, v_inbox;
END;
$revert$;

-- ---------------------------------------------------------------------------
-- 2) Harden archive followup — block anon JWT (SQL Editor still works)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_archive_season_followup(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_label text;
  v_under jsonb := NULL;
  v_oots jsonb := NULL;
  v_inbox_ok boolean := false;
  v_inbox_error text := NULL;
  v_under_error text := NULL;
  v_oots_error text := NULL;
  v_jwt_role text := coalesce(
    auth.jwt() ->> 'role',
    current_setting('request.jwt.claim.role', true),
    ''
  );
BEGIN
  PERFORM set_config('statement_timeout', '300s', true);

  -- PostgREST anon key must never run season-end side effects
  IF v_jwt_role = 'anon' THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT s.id, s.label
    INTO v_season_id, v_label
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  ELSE
    SELECT s.label INTO v_label
    FROM public.competition_seasons s
    WHERE s.id = v_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.owner_inbox_notify_club_season_archive(bigint,text)') IS NOT NULL THEN
    BEGIN
      PERFORM public.owner_inbox_notify_club_season_archive(
        v_season_id,
        coalesce(v_label, 'Season')
      );
      v_inbox_ok := true;
    EXCEPTION WHEN OTHERS THEN
      v_inbox_error := SQLERRM;
    END;
  END IF;

  IF to_regprocedure('public.club_underperformance_process_season(bigint)') IS NOT NULL THEN
    BEGIN
      v_under := public.club_underperformance_process_season(v_season_id);
    EXCEPTION WHEN OTHERS THEN
      v_under_error := SQLERRM;
    END;
  END IF;

  IF to_regprocedure('public.competition_award_owners_of_season(bigint)') IS NOT NULL THEN
    BEGIN
      v_oots := public.competition_award_owners_of_season(v_season_id);
    EXCEPTION WHEN OTHERS THEN
      v_oots_error := SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', v_inbox_error IS NULL AND v_under_error IS NULL AND v_oots_error IS NULL,
    'season_id', v_season_id,
    'season_label', v_label,
    'inbox_notified', v_inbox_ok,
    'inbox_error', v_inbox_error,
    'underperformance', v_under,
    'underperformance_error', v_under_error,
    'owner_of_season', v_oots,
    'owner_of_season_error', v_oots_error,
    'hint', CASE
      WHEN v_inbox_error ILIKE '%message_type_check%'
      THEN 'Widen inbox types: re-run this patch or archive_season_inbox_message_types_fix.sql'
      ELSE NULL
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_admin_archive_season_followup(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.competition_admin_archive_season_followup(bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.competition_admin_archive_season_followup(bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
