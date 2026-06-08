-- =============================================================================
-- Backfill: £10m fines for all historical MV squad-overflow releases
-- Posts to Club_Finances + competition_finance_ledger (+ competition_fine_applied)
-- Also backfills missing MV sale ledger lines (ledger only, no balance change)
-- and paid-up season locks on released free agents.
--
-- Run after: squad_overflow_paid_up_fine.sql (tariff squad_overflow_mv_release)
--
-- Preview:  SELECT * FROM squad_overflow_mv_releases_pending_backfill;
-- Dry run:  SELECT backfill_squad_overflow_mv_fines(false);
-- Apply:    SELECT backfill_squad_overflow_mv_fines(true);
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
    (
      SELECT s.id
      FROM public.competition_seasons s
      WHERE s.is_current = true
      ORDER BY s.id DESC
      LIMIT 1
    )
  );
$$;

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
    coalesce(btrim(p_foreign_buyer_name), '') ILIKE '%market value (squad over 28)%'
    OR (
      coalesce(p_transfer_sale_note, '') = 'squad_overflow'
      AND coalesce(btrim(p_buyer_club_id::text), '') = 'FOREIGN'
      AND coalesce(btrim(p_foreign_buyer_name), '') ILIKE '%market value%'
    );
$$;

CREATE OR REPLACE VIEW public.squad_overflow_mv_releases_pending_backfill
WITH (security_invoker = false)
AS
SELECT
  h.id AS transfer_history_id,
  h.transfer_time,
  public.transfer_history_season_id(h.transfer_time) AS season_id,
  h.seller_club_id AS club_short_name,
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
  v_desc text;
  v_ledger_amount numeric;
  v_ledger_id bigint;
  v_applied_id bigint;
  v_player_name text;
  v_unlock_label text;
  v_fines_posted int := 0;
  v_fines_skipped int := 0;
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

  FOR v_row IN
    SELECT *
    FROM public.squad_overflow_mv_releases_pending_backfill
    ORDER BY transfer_time ASC
  LOOP
    v_season_id := coalesce(v_row.season_id, public.current_gpsl_season_id());
    v_player_name := coalesce(v_row.player_name, 'Player ' || v_row.player_id::text);

    -- MV sale ledger line (no balance change — MV was credited at release)
    IF NOT v_row.sale_ledger_posted AND p_apply AND v_row.transfer_history_id IS NOT NULL THEN
      PERFORM public.post_transfer_ledger_for_history(v_row.transfer_history_id, false);

      UPDATE public.competition_finance_ledger l
      SET created_at = v_row.transfer_time
      WHERE l.metadata->>'transfer_history_id' = v_row.transfer_history_id::text
        AND l.entry_type IN (
          'transfer_sale',
          'transfer_foreign_sale',
          'transfer_overflow_release'
        )
        AND l.created_at IS DISTINCT FROM v_row.transfer_time;

      v_sales_ledger_posted := v_sales_ledger_posted + 1;
    END IF;

    -- Paid-up lock on still-free agents (historical season id)
    IF p_apply
       AND v_row.player_is_free_agent
       AND v_row.current_lock_kind IS DISTINCT FROM 'paid_up'
       AND v_season_id IS NOT NULL
    THEN
      v_unlock_label := public.next_gpsl_season_label(v_season_id);

      UPDATE public."Players" p
      SET
        foreign_contract_club = v_row.club_short_name,
        foreign_contract_sold_season_id = v_season_id,
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
      PERFORM public.competition_credit_club_balance(
        v_row.club_short_name,
        v_ledger_amount
      );

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
        v_row.club_short_name,
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
        v_row.club_short_name,
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

      IF NOT v_row.club_short_name = ANY (v_clubs) THEN
        v_clubs := array_append(v_clubs, v_row.club_short_name);
      END IF;
    ELSIF NOT v_row.fine_already_posted AND NOT p_apply THEN
      v_preview := v_preview || jsonb_build_array(
        jsonb_build_object(
          'transfer_history_id', v_row.transfer_history_id,
          'transfer_time', v_row.transfer_time,
          'club_short_name', v_row.club_short_name,
          'player_id', v_row.player_id,
          'player_name', v_player_name,
          'season_id', v_season_id,
          'fine_amount', abs(v_fine_amount),
          'mv_credit', v_row.mv_credit,
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
    'fines_to_post_or_posted', v_fines_posted,
    'fines_skipped_already_posted', v_fines_skipped,
    'sale_ledger_lines_backfilled', v_sales_ledger_posted,
    'paid_up_locks_backfilled', v_locks_backfilled,
    'total_fine_amount', v_total_fined,
    'clubs_affected', to_jsonb(v_clubs),
    'preview', CASE WHEN p_apply THEN NULL ELSE v_preview END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transfer_history_season_id(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_history_is_mv_squad_overflow(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.backfill_squad_overflow_mv_fines(boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
