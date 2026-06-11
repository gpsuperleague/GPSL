-- =============================================================================
-- Fine → inbox notification fix
-- Run after competition_fines.sql (+ transfer_inbox_notifications.sql).
-- Safe to re-run. Backfills fines that never got an inbox row.
-- =============================================================================

ALTER TABLE public.competition_inbox
  ADD COLUMN IF NOT EXISTS action_href text,
  ADD COLUMN IF NOT EXISTS dedupe_key text,
  ADD COLUMN IF NOT EXISTS owner_id uuid REFERENCES auth.users (id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS gpsl_month smallint,
  ADD COLUMN IF NOT EXISTS season_id bigint REFERENCES public.competition_seasons (id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS competition_inbox_dedupe_idx
  ON public.competition_inbox (dedupe_key)
  WHERE dedupe_key IS NOT NULL;

ALTER TABLE public.competition_inbox
  DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

ALTER TABLE public.competition_inbox
  ADD CONSTRAINT competition_inbox_message_type_check
  CHECK (
    message_type IN (
      'welcome_gpsl',
      'result_submitted',
      'result_to_confirm',
      'result_rejected',
      'result_confirmed',
      'transfer_signed',
      'transfer_sold',
      'transfer_upcoming',
      'draft_scheduled',
      'fine_applied',
      'points_deduction',
      'nation_pick_turn',
      'nation_selection_open',
      'season_expectations',
      'season_overview',
      'player_awards',
      'monthly_fixtures'
    )
  );

-- Minimal send helper (no-op if owner_inbox_send already exists from full patch)
CREATE OR REPLACE FUNCTION public.owner_inbox_send(
  p_message_type text,
  p_title text,
  p_body text,
  p_recipient_club text DEFAULT NULL,
  p_owner_id uuid DEFAULT NULL,
  p_fixture_id bigint DEFAULT NULL,
  p_submission_id bigint DEFAULT NULL,
  p_transfer_history_id bigint DEFAULT NULL,
  p_transfer_listing_id bigint DEFAULT NULL,
  p_action_href text DEFAULT NULL,
  p_dedupe_key text DEFAULT NULL,
  p_gpsl_month smallint DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_club text := nullif(btrim(p_recipient_club), '');
BEGIN
  IF v_club IS NULL AND p_owner_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF v_club = 'FOREIGN' THEN
    RETURN NULL;
  END IF;

  IF p_dedupe_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = p_dedupe_key
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.competition_inbox (
    recipient_club_short_name, owner_id, message_type,
    fixture_id, submission_id, transfer_history_id, transfer_listing_id,
    title, body, action_href, dedupe_key, gpsl_month, season_id
  )
  VALUES (
    v_club, p_owner_id, p_message_type,
    p_fixture_id, p_submission_id, p_transfer_history_id, p_transfer_listing_id,
    p_title, p_body, p_action_href, p_dedupe_key, p_gpsl_month, p_season_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_fine_applied(p_applied_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.competition_fine_applied%rowtype;
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_row
  FROM public.competition_fine_applied
  WHERE id = p_applied_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_title := CASE
    WHEN v_row.direction = 'fine' THEN 'Fine applied'
    ELSE 'Compensation credited'
  END;

  v_body := concat_ws(
    E'\n',
    v_row.description,
    CASE
      WHEN v_row.direction = 'fine' THEN 'Amount: ' || public.transfer_format_money(v_row.amount)
      ELSE 'Credit: ' || public.transfer_format_money(v_row.amount)
    END,
    CASE WHEN v_row.note IS NOT NULL AND btrim(v_row.note) <> '' THEN 'Note: ' || v_row.note ELSE NULL END
  );

  RETURN public.owner_inbox_send(
    'fine_applied',
    v_title,
    v_body,
    v_row.club_short_name,
    NULL,
    v_row.fixture_id,
    NULL, NULL, NULL,
    'finances.html',
    'fine:' || v_row.id::text,
    NULL,
    v_row.season_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_backfill_fine_notifications()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_count int := 0;
BEGIN
  FOR v_row IN
    SELECT fa.id
    FROM public.competition_fine_applied fa
    WHERE NOT EXISTS (
      SELECT 1 FROM public.competition_inbox i
      WHERE i.dedupe_key = 'fine:' || fa.id::text
         OR (i.message_type = 'fine_applied'
             AND i.recipient_club_short_name = fa.club_short_name
             AND i.created_at >= fa.applied_at - interval '2 minutes'
             AND i.created_at <= fa.applied_at + interval '2 minutes')
    )
    ORDER BY fa.applied_at
  LOOP
    IF public.owner_inbox_notify_fine_applied(v_row.id) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END;
$function$;

-- Apply fine RPC — notify in same transaction (not trigger-only)
CREATE OR REPLACE FUNCTION public.competition_apply_club_fine_tariff(
  p_club_short_name text,
  p_tariff_code text,
  p_amount_override numeric DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_fixture_id bigint DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tariff public.competition_fine_tariff;
  v_club text := btrim(p_club_short_name);
  v_amount numeric;
  v_ledger_amount numeric;
  v_season_id bigint;
  v_desc text;
  v_ledger_id bigint;
  v_applied_id bigint;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  SELECT * INTO v_tariff
  FROM public.competition_fine_tariff
  WHERE code = p_tariff_code AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown or inactive tariff: %', p_tariff_code;
  END IF;

  IF v_tariff.amount_mode = 'manual' THEN
    v_amount := p_amount_override;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Manual amount required for %', v_tariff.label;
    END IF;
  ELSE
    v_amount := coalesce(p_amount_override, v_tariff.amount);
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Tariff % has no amount configured', v_tariff.label;
    END IF;
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_tariff.direction = 'fine' THEN
    v_ledger_amount := -abs(v_amount);
    PERFORM public.competition_credit_club_balance(v_club, v_ledger_amount);
    v_desc := format('Fine — %s', v_tariff.label);
  ELSE
    v_ledger_amount := abs(v_amount);
    PERFORM public.competition_credit_club_balance(v_club, v_ledger_amount);
    v_desc := format('Compensation — %s', v_tariff.label);
  END IF;

  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    v_desc := v_desc || ' — ' || btrim(p_note);
  END IF;

  INSERT INTO public.competition_finance_ledger (
    season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
  )
  VALUES (
    v_season_id,
    p_fixture_id,
    v_club,
    'gov_fine_compensation',
    v_ledger_amount,
    v_desc,
    jsonb_build_object(
      'tariff_code', v_tariff.code,
      'direction', v_tariff.direction,
      'category', v_tariff.category
    )
  )
  RETURNING id INTO v_ledger_id;

  INSERT INTO public.competition_fine_applied (
    season_id, tariff_code, club_short_name, amount, direction,
    description, note, fixture_id, ledger_id, applied_by
  )
  VALUES (
    v_season_id, v_tariff.code, v_club, abs(v_amount), v_tariff.direction,
    v_desc, p_note, p_fixture_id, v_ledger_id,
    CASE WHEN public.is_gpsl_admin() THEN 'ADMIN' ELSE 'SYSTEM' END
  )
  RETURNING id INTO v_applied_id;

  PERFORM public.owner_inbox_notify_fine_applied(v_applied_id);

  RETURN jsonb_build_object(
    'applied_id', v_applied_id,
    'ledger_id', v_ledger_id,
    'club_short_name', v_club,
    'tariff_code', v_tariff.code,
    'amount', abs(v_amount),
    'direction', v_tariff.direction,
    'ledger_amount', v_ledger_amount,
    'inbox_notified', true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_fine_applied_inbox_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.owner_inbox_notify_fine_applied(NEW.id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS fine_applied_inbox_notify ON public.competition_fine_applied;
CREATE TRIGGER fine_applied_inbox_notify
  AFTER INSERT ON public.competition_fine_applied
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_fine_applied_inbox_notify();

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_fine_applied(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_backfill_fine_notifications() TO authenticated;

NOTIFY pgrst, 'reload schema';
