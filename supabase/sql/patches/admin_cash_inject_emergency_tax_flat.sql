-- =============================================================================
-- Admin: flat cash injection + flat emergency tax (all clubs or selected)
-- Ledger: admin_one_off_injection (credit) / gov_emergency_tax (debit)
-- Via GPSL Central Bank. Inbox notifies each affected club.
-- Safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Inbox message types
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'admin_cash_injection',
      'admin_emergency_tax'
    ])
  ) s;

  IF v_list IS NULL OR btrim(v_list) = '' THEN
    RAISE EXCEPTION 'No inbox message types to install';
  END IF;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Resolve target clubs: selected list, or all season league clubs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_finance_resolve_target_clubs(
  p_season_id bigint,
  p_club_short_names text[] DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_clubs text[];
BEGIN
  IF p_club_short_names IS NOT NULL AND cardinality(p_club_short_names) > 0 THEN
    SELECT array_agg(x ORDER BY x)
    INTO v_clubs
    FROM (
      SELECT DISTINCT btrim(c) AS x
      FROM unnest(p_club_short_names) AS c
      WHERE nullif(btrim(c), '') IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public."Clubs" cl WHERE cl."ShortName" = btrim(c)
        )
    ) s;

    IF v_clubs IS NULL OR cardinality(v_clubs) = 0 THEN
      RAISE EXCEPTION 'No valid clubs in selection';
    END IF;
    RETURN v_clubs;
  END IF;

  SELECT array_agg(ccs.club_short_name ORDER BY ccs.club_short_name)
  INTO v_clubs
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = p_season_id
    AND ccs.division IN ('superleague', 'championship_a', 'championship_b');

  IF v_clubs IS NULL OR cardinality(v_clubs) = 0 THEN
    RAISE EXCEPTION 'No clubs registered for season %', p_season_id;
  END IF;

  RETURN v_clubs;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_finance_format_amount_label(p_amount numeric)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF to_regprocedure('public.transfer_format_money(numeric)') IS NOT NULL THEN
    RETURN public.transfer_format_money(abs(p_amount));
  END IF;
  RETURN '₿' || to_char(abs(p_amount), 'FM999,999,999,999');
END;
$function$;

-- ---------------------------------------------------------------------------
-- Inject cash (credit) — admin_one_off_injection
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_inject_cash(
  p_amount numeric,
  p_club_short_names text[] DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_clubs text[];
  v_club text;
  v_amount numeric := round(abs(coalesce(p_amount, 0)), 0);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_desc text;
  v_body text;
  v_ledger_id bigint;
  v_posted int := 0;
  v_notified int := 0;
  v_amount_label text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero';
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

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  v_clubs := public.admin_finance_resolve_target_clubs(v_season_id, p_club_short_names);
  v_amount_label := public.admin_finance_format_amount_label(v_amount);
  v_desc := CASE
    WHEN v_note IS NOT NULL THEN 'Admin cash injection — ' || v_note
    ELSE 'Admin cash injection'
  END;

  FOREACH v_club IN ARRAY v_clubs
  LOOP
    v_ledger_id := public.post_club_ledger(
      v_club,
      'admin_one_off_injection',
      v_amount,
      v_desc,
      jsonb_build_object(
        'source', 'admin_inject_cash',
        'note', v_note,
        'amount', v_amount
      ),
      v_season_id,
      NULL,
      public.finance_entry_via_central_bank('admin_one_off_injection'),
      true
    );

    IF v_ledger_id IS NULL THEN
      CONTINUE;
    END IF;

    v_posted := v_posted + 1;

    v_body := concat_ws(
      E'\n',
      'The league has credited your club account.',
      'Amount: ' || v_amount_label,
      CASE WHEN v_note IS NOT NULL THEN 'Note: ' || v_note ELSE NULL END,
      'See Finances → End of season / bank injection.'
    );

    IF public.owner_inbox_send(
      'admin_cash_injection',
      'Cash injection',
      v_body,
      v_club,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      'finances.html',
      'cash_inject:' || v_ledger_id::text,
      NULL,
      v_season_id
    ) IS NOT NULL THEN
      v_notified := v_notified + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'amount', v_amount,
    'clubs_posted', v_posted,
    'inbox_notified', v_notified,
    'entry_type', 'admin_one_off_injection'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Flat emergency tax (debit) — gov_emergency_tax
-- Distinct from threshold-% EOS apply (competition_admin_apply_emergency_tac).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_charge_emergency_tax_flat(
  p_amount numeric,
  p_club_short_names text[] DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_clubs text[];
  v_club text;
  v_amount numeric := round(abs(coalesce(p_amount, 0)), 0);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_desc text;
  v_body text;
  v_ledger_id bigint;
  v_posted int := 0;
  v_notified int := 0;
  v_amount_label text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero';
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

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  v_clubs := public.admin_finance_resolve_target_clubs(v_season_id, p_club_short_names);
  v_amount_label := public.admin_finance_format_amount_label(v_amount);
  v_desc := CASE
    WHEN v_note IS NOT NULL THEN 'Emergency tax — ' || v_note
    ELSE 'Emergency tax (admin levy)'
  END;

  FOREACH v_club IN ARRAY v_clubs
  LOOP
    v_ledger_id := public.post_club_ledger(
      v_club,
      'gov_emergency_tax',
      -v_amount,
      v_desc,
      jsonb_build_object(
        'source', 'admin_emergency_tax_flat',
        'note', v_note,
        'amount', v_amount
      ),
      v_season_id,
      NULL,
      public.finance_entry_via_central_bank('gov_emergency_tax'),
      true
    );

    IF v_ledger_id IS NULL THEN
      CONTINUE;
    END IF;

    v_posted := v_posted + 1;

    v_body := concat_ws(
      E'\n',
      'An emergency tax has been charged to your club account.',
      'Amount: ' || v_amount_label,
      CASE WHEN v_note IS NOT NULL THEN 'Note: ' || v_note ELSE NULL END,
      'See Finances → Government / Emergency tax.'
    );

    IF public.owner_inbox_send(
      'admin_emergency_tax',
      'Emergency tax charged',
      v_body,
      v_club,
      NULL,
      NULL,
      NULL,
      NULL,
      NULL,
      'finances.html',
      'emergency_tax:' || v_ledger_id::text,
      NULL,
      v_season_id
    ) IS NOT NULL THEN
      v_notified := v_notified + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'amount', v_amount,
    'clubs_posted', v_posted,
    'inbox_notified', v_notified,
    'entry_type', 'gov_emergency_tax'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_finance_resolve_target_clubs(bigint, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_finance_format_amount_label(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_inject_cash(numeric, text[], text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_charge_emergency_tax_flat(numeric, text[], text, bigint) TO authenticated;
