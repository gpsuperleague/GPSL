-- Signing sell-lock: one GPSL half-season (not a full season).
--   First-half signing  → sellable from GPSL January (same season)
--   Second-half signing → sellable from next summer (1st half of next season)
-- Drops signed_last_season_half (that extended Jan signings through next season's 1st half).
-- New Owner / underperformance listing bypasses unchanged (listing triggers + accept_sale).

CREATE OR REPLACE FUNCTION public.player_contract_sell_lock_reason(p_player_id text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_p record;
  v_second boolean;
BEGIN
  SELECT
    nullif(btrim(p."Contracted_Team"::text), '') AS club,
    nullif(btrim(p."Season_Signed"), '') AS signed,
    p.contract_seasons_remaining AS rem,
    coalesce(p.contract_end_window, 'summer') AS end_window,
    coalesce(p.contract_join_second_half, false) AS joined_second_half,
    coalesce(p.pesdb_unavailable, false) AS legacy
  INTO v_p
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;
  IF v_p.legacy THEN
    RETURN 'legacy';
  END IF;
  IF v_p.club IS NULL THEN
    RETURN NULL;
  END IF;
  IF public.player_is_active_stopgap_loan(v_pid) THEN
    RETURN 'loan';
  END IF;

  v_second := public.gpsl_season_second_half();

  -- Half-season signing lock (same season only).
  IF public.player_signed_this_season(v_p.signed) THEN
    IF v_p.joined_second_half THEN
      -- Jan-window signing: locked for the rest of this second half.
      RETURN 'signed_this_season';
    ELSIF NOT v_second THEN
      -- Summer / first-half signing: locked until GPSL January.
      RETURN 'signed_this_season';
    END IF;
    -- First-half signing, now in second half → sellable.
  END IF;

  IF v_p.rem IS NOT NULL AND v_p.rem <= 0 THEN
    RETURN 'contract_ended';
  END IF;

  IF v_p.rem = 1 AND (v_p.end_window = 'january' OR v_second) THEN
    RETURN 'final_half';
  END IF;

  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.player_contract_sell_lock_reason(text) IS
  'NULL when listable/sellable; else legacy / loan / signed_this_season (half-season) / contract_ended / final_half.';

CREATE OR REPLACE FUNCTION public.assert_player_transferable(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_reason text := public.player_contract_sell_lock_reason(p_player_id);
BEGIN
  IF v_reason IS NULL THEN
    RETURN;
  END IF;

  CASE v_reason
    WHEN 'not_found' THEN
      RAISE EXCEPTION 'Player not found';
    WHEN 'legacy' THEN
      RAISE EXCEPTION
        'This player card is no longer on pesdb.net (legacy card). It cannot be sold, listed, or signed until it returns on a PESDB sync.';
    WHEN 'loan' THEN
      RAISE EXCEPTION 'Emergency / season loan players cannot be sold or listed.';
    WHEN 'signed_this_season' THEN
      RAISE EXCEPTION
        'This player is under a half-season signing lock and cannot be sold or listed yet (1st-half signing → GPSL January; 2nd-half signing → next summer).';
    WHEN 'signed_last_season_half' THEN
      -- Legacy reason no longer emitted; keep message for any stale client.
      RAISE EXCEPTION
        'This player is under a half-season signing lock and cannot be sold or listed yet.';
    WHEN 'contract_ended' THEN
      RAISE EXCEPTION 'This player''s contract has ended and cannot be sold or listed.';
    WHEN 'final_half' THEN
      RAISE EXCEPTION
        'Player is in the final half of their contract and cannot be sold or listed. Renew (if eligible) or use the expiry wage market.';
    ELSE
      RAISE EXCEPTION 'This player cannot be sold or listed right now (%).', v_reason;
  END CASE;
END;
$function$;

-- transferengine_accept_sale: use full sell-lock (not raw signed_this_season).
DO $patch$
DECLARE
  v_def text;
  v_new text;
  v_old text := $old$
  IF NOT v_allow_same_season
     AND public.player_signed_this_season(v_player."Season_Signed") THEN
    RAISE NOTICE 'Player signed this season — sale blocked for listing %', p_listing_id;
    RETURN;
  END IF;
$old$;
  v_repl text := $new$
  IF NOT v_allow_same_season
     AND public.player_contract_sell_lock_reason(v_listing.player_id::text) IS NOT NULL THEN
    RAISE NOTICE 'Player sell-locked — sale blocked for listing %', p_listing_id;
    RETURN;
  END IF;
$new$;
BEGIN
  IF to_regprocedure('public.transferengine_accept_sale(bigint)') IS NULL THEN
    RAISE NOTICE 'transferengine_accept_sale missing — skip accept_sale patch';
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.transferengine_accept_sale(bigint)'::regprocedure)
    INTO v_def;

  IF v_def IS NULL THEN
    RAISE NOTICE 'Could not read transferengine_accept_sale def';
    RETURN;
  END IF;

  IF position('player_contract_sell_lock_reason(v_listing.player_id::text)' IN v_def) > 0 THEN
    RAISE NOTICE 'transferengine_accept_sale already uses sell_lock_reason';
    RETURN;
  END IF;

  IF position('player_signed_this_season(v_player."Season_Signed")' IN v_def) = 0 THEN
    RAISE NOTICE 'transferengine_accept_sale: expected signed_this_season block not found — skip';
    RETURN;
  END IF;

  v_new := replace(v_def, v_old, v_repl);
  IF v_new = v_def THEN
    -- Whitespace variance: try a looser replace of the condition only
    v_new := replace(
      v_def,
      'public.player_signed_this_season(v_player."Season_Signed")',
      'public.player_contract_sell_lock_reason(v_listing.player_id::text) IS NOT NULL'
    );
    v_new := replace(
      v_new,
      'Player signed this season — sale blocked for listing %',
      'Player sell-locked — sale blocked for listing %'
    );
  END IF;

  IF v_new = v_def THEN
    RAISE WARNING 'transferengine_accept_sale: could not patch signed_this_season gate';
    RETURN;
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'transferengine_accept_sale patched to sell_lock_reason';
END;
$patch$;
