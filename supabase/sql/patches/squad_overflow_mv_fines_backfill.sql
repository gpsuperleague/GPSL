-- =============================================================================
-- Backfill: £10m fines for all historical MV squad-overflow releases
-- Posts to Club_Finances + competition_finance_ledger (+ competition_fine_applied)
--
-- IMPORTANT: Finances UI reads competition_finance_ledger_public, which only
-- shows rows whose season_id matches the current active competition season.
-- This backfill always posts fines to current_gpsl_season_id() (created_at still
-- backdated to the release transfer_time).
--
-- Run after: squad_overflow_paid_up_fine.sql
--
-- URD audit:     SELECT * FROM squad_overflow_club_release_audit WHERE club_short_name = 'URD';
-- Pending fines: SELECT * FROM squad_overflow_mv_releases_pending_backfill WHERE club_short_name = 'URD';
-- Dry run:       SELECT backfill_squad_overflow_mv_fines(false);
-- Apply:         SELECT backfill_squad_overflow_mv_fines(true);
-- Fix hidden:    SELECT repair_squad_overflow_mv_fines_visibility();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transfer_history_season_id(p_transfer_time timestamptz)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT s.id
      FROM public.competition_seasons s
      WHERE p_transfer_time IS NOT NULL
        AND s.started_at IS NOT NULL
        AND p_transfer_time >= s.started_at
        AND (s.ended_at IS NULL OR p_transfer_time < s.ended_at)
      ORDER BY s.started_at DESC
      LIMIT 1
    ),
    public.current_gpsl_season_id()
  );
$$;

-- Named foreign overflow (real tracking club) — no £10m fine
CREATE OR REPLACE FUNCTION public.transfer_history_is_foreign_squad_overflow(
  p_transfer_sale_note text,
  p_foreign_buyer_name text,
  p_buyer_club_id text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    coalesce(p_transfer_sale_note, '') = 'squad_overflow'
    AND coalesce(btrim(p_buyer_club_id::text), '') = 'FOREIGN'
    AND coalesce(btrim(p_foreign_buyer_name), '') <> ''
    AND NOT (
      coalesce(btrim(p_foreign_buyer_name), '') ILIKE '%market value%'
      OR coalesce(btrim(p_foreign_buyer_name), '') ILIKE '%foreign club (squad over 28)%'
    );
$$;

-- MV / paid-up overflow — £10m fine applies
CREATE OR REPLACE FUNCTION public.transfer_history_is_mv_squad_overflow(
  p_transfer_sale_note text,
  p_foreign_buyer_name text,
  p_buyer_club_id text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    NOT public.transfer_history_is_foreign_squad_overflow(
      p_transfer_sale_note,
      p_foreign_buyer_name,
      p_buyer_club_id
    )
    AND (
      coalesce(btrim(p_foreign_buyer_name), '') ILIKE '%market value%'
      OR coalesce(btrim(p_foreign_buyer_name), '') ILIKE '%foreign club (squad over 28)%'
      OR (
        coalesce(p_transfer_sale_note, '') = 'squad_overflow'
        AND coalesce(btrim(p_buyer_club_id::text), '') = 'FOREIGN'
      )
    );
$$;

-- Classify every seller release (debug URD / any club)
-- DROP required: CREATE OR REPLACE cannot reorder/rename view columns (42P16).
DROP VIEW IF EXISTS public.squad_overflow_club_release_audit;

CREATE VIEW public.squad_overflow_club_release_audit
WITH (security_invoker = false)
AS
SELECT
  coalesce(public.resolve_club_shortname(h.seller_club_id::text), h.seller_club_id::text)
    AS club_short_name,
  h.id AS transfer_history_id,
  h.transfer_time,
  h.player_id,
  p."Name" AS player_name,
  h.buyer_club_id,
  h.foreign_buyer_name,
  h.transfer_sale_note,
  h.fee,
  public.transfer_history_is_foreign_squad_overflow(
    h.transfer_sale_note,
    h.foreign_buyer_name,
    h.buyer_club_id::text
  ) AS is_foreign_overflow,
  public.transfer_history_is_mv_squad_overflow(
    h.transfer_sale_note,
    h.foreign_buyer_name,
    h.buyer_club_id::text
  ) AS is_mv_overflow_fineable,
  EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = h.id::text
      AND l.entry_type = 'gov_fine_compensation'
      AND l.metadata->>'tariff_code' = 'squad_overflow_mv_release'
  ) AS fine_ledger_exists,
  EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    JOIN public.competition_seasons s ON s.id = l.season_id
    WHERE l.metadata->>'transfer_history_id' = h.id::text
      AND l.entry_type = 'gov_fine_compensation'
      AND l.metadata->>'tariff_code' = 'squad_overflow_mv_release'
      AND s.is_current = true
      AND s.status = 'active'
  ) AS fine_visible_in_finances
FROM public."Transfer_History" h
LEFT JOIN public."Players" p ON p."Konami_ID" = h.player_id
WHERE h.buyer_club_id = 'FOREIGN'
   OR coalesce(h.transfer_sale_note, '') = 'squad_overflow'
ORDER BY h.transfer_time DESC;

GRANT SELECT ON public.squad_overflow_club_release_audit TO authenticated;

DROP VIEW IF EXISTS public.squad_overflow_mv_releases_pending_backfill;

CREATE VIEW public.squad_overflow_mv_releases_pending_backfill
WITH (security_invoker = false)
AS
SELECT
  coalesce(public.resolve_club_shortname(h.seller_club_id::text), h.seller_club_id::text)
    AS club_short_name,
  h.id AS transfer_history_id,
  h.transfer_time,
  public.current_gpsl_season_id() AS post_season_id,
  h.player_id,
  p."Name" AS player_name,
  h.fee AS mv_credit,
  h.foreign_buyer_name,
  h.transfer_sale_note,
  EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = h.id::text
      AND l.entry_type = 'gov_fine_compensation'
      AND l.metadata->>'tariff_code' = 'squad_overflow_mv_release'
  ) AS fine_already_posted,
  EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    JOIN public.competition_seasons s ON s.id = l.season_id
    WHERE l.metadata->>'transfer_history_id' = h.id::text
      AND l.entry_type = 'gov_fine_compensation'
      AND l.metadata->>'tariff_code' = 'squad_overflow_mv_release'
      AND s.is_current = true
      AND s.status = 'active'
  ) AS fine_visible_in_finances,
  EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = h.id::text
      AND l.entry_type IN (
        'transfer_sale',
        'transfer_foreign_sale',
        'transfer_overflow_release'
      )
  ) AS sale_ledger_posted,
  p."Contracted_Team" IS NULL AS player_is_free_agent,
  p.foreign_contract_lock_kind AS current_lock_kind
FROM public."Transfer_History" h
LEFT JOIN public."Players" p ON p."Konami_ID" = h.player_id
WHERE public.transfer_history_is_mv_squad_overflow(
  h.transfer_sale_note,
  h.foreign_buyer_name,
  h.buyer_club_id::text
)
ORDER BY h.transfer_time ASC;

GRANT SELECT ON public.squad_overflow_mv_releases_pending_backfill TO authenticated;

-- Move already-posted fines onto the current season so Finances can see them
CREATE OR REPLACE FUNCTION public.repair_squad_overflow_mv_fines_visibility()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_ledger int := 0;
  v_applied int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only (or run in SQL Editor without JWT)';
  END IF;

  v_season_id := public.current_gpsl_season_id();
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  UPDATE public.competition_finance_ledger l
  SET season_id = v_season_id
  WHERE l.entry_type = 'gov_fine_compensation'
    AND l.metadata->>'tariff_code' = 'squad_overflow_mv_release'
    AND l.season_id IS DISTINCT FROM v_season_id;

  GET DIAGNOSTICS v_ledger = ROW_COUNT;

  UPDATE public.competition_fine_applied a
  SET season_id = v_season_id
  WHERE a.tariff_code = 'squad_overflow_mv_release'
    AND a.season_id IS DISTINCT FROM v_season_id;

  GET DIAGNOSTICS v_applied = ROW_COUNT;

  RETURN jsonb_build_object(
    'current_season_id', v_season_id,
    'ledger_rows_relinked', v_ledger,
    'fine_applied_rows_relinked', v_applied
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.backfill_squad_overflow_mv_fines(p_apply boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fine_amount numeric := 10000000;
  v_row record;
  v_season_id bigint;
  v_club text;
  v_desc text;
  v_ledger_amount numeric;
  v_ledger_id bigint;
  v_applied_id bigint;
  v_player_name text;
  v_unlock_label text;
  v_release_season_id bigint;
  v_fines_posted int := 0;
  v_fines_skipped int := 0;
  v_fines_relinked int := 0;
  v_sales_ledger_posted int := 0;
  v_locks_backfilled int := 0;
  v_total_fined numeric := 0;
  v_clubs text[] := '{}';
  v_preview jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only (or run in SQL Editor without JWT)';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_fine_tariff t
    WHERE t.code = 'squad_overflow_mv_release'
      AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Tariff squad_overflow_mv_release missing — run squad_overflow_paid_up_fine.sql first';
  END IF;

  v_season_id := public.current_gpsl_season_id();
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season for ledger post';
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.squad_overflow_mv_releases_pending_backfill
    ORDER BY transfer_time ASC
  LOOP
    v_club := coalesce(v_row.club_short_name, '');
    IF v_club = '' THEN
      CONTINUE;
    END IF;

    v_release_season_id := public.transfer_history_season_id(v_row.transfer_time);
    v_player_name := coalesce(v_row.player_name, 'Player ' || v_row.player_id::text);

    -- Hidden fine from an earlier backfill run — relink to current season
    IF v_row.fine_already_posted AND NOT v_row.fine_visible_in_finances AND p_apply THEN
      UPDATE public.competition_finance_ledger l
      SET season_id = v_season_id
      WHERE l.metadata->>'transfer_history_id' = v_row.transfer_history_id::text
        AND l.entry_type = 'gov_fine_compensation'
        AND l.metadata->>'tariff_code' = 'squad_overflow_mv_release'
        AND l.season_id IS DISTINCT FROM v_season_id;

      UPDATE public.competition_fine_applied a
      SET season_id = v_season_id
      WHERE a.note LIKE format('%%transfer_history_id=%s%%', v_row.transfer_history_id)
         OR a.ledger_id IN (
           SELECT l.id
           FROM public.competition_finance_ledger l
           WHERE l.metadata->>'transfer_history_id' = v_row.transfer_history_id::text
             AND l.metadata->>'tariff_code' = 'squad_overflow_mv_release'
         );

      v_fines_relinked := v_fines_relinked + 1;
    END IF;

    IF NOT v_row.sale_ledger_posted AND p_apply AND v_row.transfer_history_id IS NOT NULL THEN
      PERFORM public.post_transfer_ledger_for_history(v_row.transfer_history_id, false);

      UPDATE public.competition_finance_ledger l
      SET
        season_id = v_season_id,
        created_at = v_row.transfer_time
      WHERE l.metadata->>'transfer_history_id' = v_row.transfer_history_id::text
        AND l.entry_type IN (
          'transfer_sale',
          'transfer_foreign_sale',
          'transfer_overflow_release'
        );

      v_sales_ledger_posted := v_sales_ledger_posted + 1;
    END IF;

    IF p_apply
       AND v_row.player_is_free_agent
       AND v_row.current_lock_kind IS DISTINCT FROM 'paid_up'
       AND v_release_season_id IS NOT NULL
    THEN
      v_unlock_label := public.next_gpsl_season_label(v_release_season_id);

      UPDATE public."Players" p
      SET
        foreign_contract_club = v_club,
        foreign_contract_sold_season_id = v_release_season_id,
        foreign_contract_unlock_season_label = v_unlock_label,
        foreign_contract_lock_kind = 'paid_up'
      WHERE p."Konami_ID" = v_row.player_id;

      v_locks_backfilled := v_locks_backfilled + 1;
    END IF;

    IF v_row.fine_already_posted THEN
      v_fines_skipped := v_fines_skipped + 1;
    ELSE
      v_desc := format(
        'Fine — Squad overflow — forced MV release — Forced release: %s (%s)',
        v_player_name,
        v_row.player_id::text
      );
      v_ledger_amount := -abs(v_fine_amount);
    END IF;

    IF NOT v_row.fine_already_posted AND p_apply THEN
      PERFORM public.competition_credit_club_balance(v_club, v_ledger_amount);

      INSERT INTO public.competition_finance_ledger (
        season_id,
        fixture_id,
        club_short_name,
        entry_type,
        amount,
        description,
        metadata
      )
      VALUES (
        v_season_id,
        NULL,
        v_club,
        'gov_fine_compensation',
        v_ledger_amount,
        v_desc,
        jsonb_build_object(
          'tariff_code', 'squad_overflow_mv_release',
          'direction', 'fine',
          'category', 'squad',
          'transfer_history_id', v_row.transfer_history_id,
          'player_id', v_row.player_id,
          'backfill', true
        )
      )
      RETURNING id INTO v_ledger_id;

      UPDATE public.competition_finance_ledger
      SET created_at = v_row.transfer_time
      WHERE id = v_ledger_id;

      INSERT INTO public.competition_fine_applied (
        season_id,
        tariff_code,
        club_short_name,
        amount,
        direction,
        description,
        note,
        fixture_id,
        ledger_id,
        applied_by,
        applied_at
      )
      VALUES (
        v_season_id,
        'squad_overflow_mv_release',
        v_club,
        abs(v_fine_amount),
        'fine',
        v_desc,
        format('Backfill transfer_history_id=%s', v_row.transfer_history_id),
        NULL,
        v_ledger_id,
        'SYSTEM_BACKFILL',
        v_row.transfer_time
      )
      RETURNING id INTO v_applied_id;

      v_fines_posted := v_fines_posted + 1;
      v_total_fined := v_total_fined + abs(v_fine_amount);

      IF NOT v_club = ANY (v_clubs) THEN
        v_clubs := array_append(v_clubs, v_club);
      END IF;
    ELSIF NOT v_row.fine_already_posted AND NOT p_apply THEN
      v_preview := v_preview || jsonb_build_array(
        jsonb_build_object(
          'transfer_history_id', v_row.transfer_history_id,
          'transfer_time', v_row.transfer_time,
          'club_short_name', v_club,
          'player_id', v_row.player_id,
          'player_name', v_player_name,
          'post_season_id', v_season_id,
          'fine_amount', abs(v_fine_amount),
          'mv_credit', v_row.mv_credit,
          'foreign_buyer_name', v_row.foreign_buyer_name,
          'transfer_sale_note', v_row.transfer_sale_note,
          'would_post_sale_ledger', NOT v_row.sale_ledger_posted,
          'would_backfill_lock', v_row.player_is_free_agent
            AND v_row.current_lock_kind IS DISTINCT FROM 'paid_up'
        )
      );
      v_fines_posted := v_fines_posted + 1;
      v_total_fined := v_total_fined + abs(v_fine_amount);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'apply', p_apply,
    'post_season_id', v_season_id,
    'fines_to_post_or_posted', v_fines_posted,
    'fines_skipped_already_posted', v_fines_skipped,
    'fines_relinked_to_current_season', v_fines_relinked,
    'sale_ledger_lines_backfilled', v_sales_ledger_posted,
    'paid_up_locks_backfilled', v_locks_backfilled,
    'total_fine_amount', v_total_fined,
    'clubs_affected', to_jsonb(v_clubs),
    'preview', CASE WHEN p_apply THEN NULL ELSE v_preview END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transfer_history_season_id(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_history_is_foreign_squad_overflow(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_history_is_mv_squad_overflow(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.repair_squad_overflow_mv_fines_visibility() TO authenticated;
GRANT EXECUTE ON FUNCTION public.backfill_squad_overflow_mv_fines(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
