-- =============================================================================
-- Club assignment — ledger display (stadium name in breakdown)
-- Run after club_assignment_stadium_charge.sql
-- =============================================================================

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
  v_stadium_name text;
  v_display_name text;
  v_desc text;
  v_meta jsonb;
  v_ledger_id bigint;
  v_dup_key text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_debit := coalesce(nullif(p_total_debit, 0), v_stadium);
  v_debit := greatest(v_debit, v_stadium);
  v_starting := greatest(coalesce(p_starting_budget, 0), 0);
  v_balance := greatest(v_starting - v_debit, 0);

  SELECT c."Club", nullif(btrim(c."Stadium"), '')
  INTO v_club_name, v_stadium_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_display_name := coalesce(v_stadium_name, v_club_name, v_club);

  v_meta := coalesce(p_metadata, '{}'::jsonb)
    || jsonb_build_object(
      'source', coalesce(nullif(btrim(p_source), ''), 'club_assignment'),
      'owner_id', p_owner_id,
      'stadium_name', v_display_name,
      'stadium_cost', v_stadium,
      'total_debit', v_debit,
      'starting_budget', v_starting
    );

  v_dup_key := coalesce(v_meta->>'listing_id', v_meta->>'assignment_key', p_owner_id::text);

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

  v_season_id := public.competition_finances_current_season_id();

  IF v_debit > 0 AND v_season_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
        AND l.season_id = v_season_id
        AND l.entry_type = 'infra_purchase'
        AND coalesce(l.metadata->>'source', l.metadata->>'assignment_source', '')
          IN (
            coalesce(nullif(btrim(p_source), ''), 'club_assignment'),
            'club_auction',
            'admin_assign',
            'club_assignment'
          )
    ) THEN
      v_desc := coalesce(
        nullif(btrim(p_description), ''),
        format('Stadium purchase — %s', v_display_name)
      );

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
    'club_short_name', v_club,
    'stadium_name', v_display_name,
    'stadium_cost', v_stadium,
    'total_debit', v_debit,
    'starting_budget', v_starting,
    'balance', v_balance,
    'season_id', v_season_id,
    'ledger_id', v_ledger_id,
    'ledger_skipped_no_season', v_season_id IS NULL AND v_debit > 0
  );
END;
$function$;

-- Read-only summary for season accounts UI (and repair helper)
CREATE OR REPLACE FUNCTION public.club_assignment_finance_display(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_row record;
  v_stadium_cost numeric;
  v_total_debit numeric;
  v_season_id bigint;
  v_ledger_posted boolean := false;
  v_display_name text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'club_required');
  END IF;

  SELECT
    c."Club" AS club_name,
    coalesce(nullif(btrim(c."Stadium"), ''), c."Club", c."ShortName") AS stadium_name,
    c.owner_id,
    l.winning_bid,
    l.updated_at AS settled_at
  INTO v_row
  FROM public."Clubs" c
  LEFT JOIN public."Club_Auction_Listings" l
    ON l.club_short_name = c."ShortName"
   AND l.transfer_completed = true
   AND l.winning_owner_id = c.owner_id
  WHERE c."ShortName" = v_club;

  IF NOT FOUND OR v_row.owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'show_in_accounts', false);
  END IF;

  v_stadium_cost := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_total_debit := greatest(coalesce(nullif(v_row.winning_bid, 0), v_stadium_cost), v_stadium_cost);
  v_display_name := v_row.stadium_name;
  v_season_id := public.competition_finances_current_season_id();

  IF v_season_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
        AND l.season_id = v_season_id
        AND l.entry_type = 'infra_purchase'
    ) INTO v_ledger_posted;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'show_in_accounts', v_total_debit > 0,
    'club_short_name', v_club,
    'club_name', v_row.club_name,
    'stadium_name', v_display_name,
    'stadium_cost', v_stadium_cost,
    'total_debit', v_total_debit,
    'ledger_posted', v_ledger_posted,
    'season_id', v_season_id,
    'settled_at', v_row.settled_at,
    'ledger_description', format('Stadium purchase — %s', v_display_name)
  );
END;
$function$;

-- Post missing infra_purchase ledger only (balance already set — do not double-debit)
CREATE OR REPLACE FUNCTION public.repair_club_assignment_ledger_only(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_starting numeric;
  v_default numeric;
  v_fin jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_default := public.club_auction_default_starting_balance();

  FOR v_row IN
    SELECT
      c."ShortName" AS club_short_name,
      c.owner_id,
      l.id AS listing_id,
      l.winning_bid,
      reg.pending_starting_balance
    FROM public."Clubs" c
    JOIN public.gpsl_owner_registry reg ON reg.owner_id = c.owner_id
    LEFT JOIN public."Club_Auction_Listings" l
      ON l.club_short_name = c."ShortName"
     AND l.transfer_completed = true
     AND l.winning_owner_id = c.owner_id
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND (
        p_club_short_name IS NULL
        OR c."ShortName" = upper(btrim(p_club_short_name))
      )
  LOOP
    v_starting := greatest(coalesce(nullif(v_row.pending_starting_balance, 0), v_default), 0);

    v_fin := public.owner_apply_club_assignment_finances(
      v_row.club_short_name,
      v_row.owner_id,
      v_starting,
      coalesce(nullif(v_row.winning_bid, 0), public.club_stadium_infra_purchase_cost(v_row.club_short_name)),
      CASE WHEN v_row.listing_id IS NOT NULL THEN 'club_auction' ELSE 'admin_assign' END,
      jsonb_build_object(
        'listing_id', v_row.listing_id::text,
        'assignment_key', v_row.owner_id::text || ':' || v_row.club_short_name,
        'dup_key', coalesce(v_row.listing_id::text, v_row.owner_id::text || ':' || v_row.club_short_name),
        'repair_ledger_only', true
      ),
      NULL
    );

    v_results := v_results || jsonb_build_array(v_fin);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'repaired', jsonb_array_length(v_results),
    'clubs', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_assignment_finance_display(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.repair_club_assignment_ledger_only(text) TO authenticated;

-- Urawa Reds — post ledger line if balance was already debited
SELECT public.repair_club_assignment_ledger_only('URD');

NOTIFY pgrst, 'reload schema';
