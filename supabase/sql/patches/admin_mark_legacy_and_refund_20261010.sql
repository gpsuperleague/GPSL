-- =============================================================================
-- Admin: mark a card as legacy by hand, optionally refunding the club
-- (2026-10-10)
-- =============================================================================
-- For a player who is no longer in the game but the PESDB sync hasn't flagged.
--
--   admin_mark_player_legacy(player_id)
--     → card becomes legacy now: open draft auctions on it close, max bids go,
--       it can't be bid on or signed, and if a club owns it the owner sees it
--       in "Legacy cards in your squad" with Return & refund.
--
--   admin_mark_legacy_and_refund(player_id)
--     → the above, then hands the player back from his club and refunds the
--       club's latest purchase (fee + agent fee + income tax), like the
--       owner's Return & refund.
--
--   gpdb_pesdb_restore_player(player_id) (existing) undoes the legacy mark.
--
-- Run after legacy_cards_block_and_refund_20261010.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_mark_player_legacy(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_name text;
  v_club text;
  v_was boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT p."Name", public.player_contracted_club_key(p."Contracted_Team"), coalesce(p.pesdb_unavailable, false)
  INTO v_name, v_club, v_was
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player % not found', v_pid;
  END IF;

  IF NOT v_was THEN
    UPDATE public."Players"
    SET pesdb_unavailable = true,
        pesdb_unavailable_since = coalesce(pesdb_unavailable_since, now())
    WHERE "Konami_ID"::text = v_pid;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_name,
    'club', v_club,
    'already_legacy', v_was
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_mark_player_legacy(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_mark_legacy_and_refund(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mark jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_mark := public.admin_mark_player_legacy(p_player_id);
  IF v_mark->>'club' IS NULL THEN
    RETURN v_mark || jsonb_build_object('refund', 0, 'note', 'Marked legacy — not at a club, nothing to refund');
  END IF;

  RETURN public.legacy_card_refund_internal(p_player_id, v_mark->>'club', true)
    || jsonb_build_object('marked_legacy', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_mark_legacy_and_refund(text) TO authenticated;

-- Lookup for the admin form: name, club and what a refund would pay
CREATE OR REPLACE FUNCTION public.admin_player_legacy_preview(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  p record;
  pu record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT pl."Name" AS name, pl."Position" AS position, pl."Rating" AS rating,
         public.player_contracted_club_key(pl."Contracted_Team") AS club,
         coalesce(pl.pesdb_unavailable, false) AS legacy
  INTO p
  FROM public."Players" pl
  WHERE pl."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player % not found', v_pid;
  END IF;

  -- No club → no purchase row is found, so every amount comes back 0
  SELECT * INTO pu FROM public.legacy_card_purchase(coalesce(p.club, ''), v_pid);

  RETURN jsonb_build_object(
    'player_id', v_pid,
    'name', p.name,
    'position', p.position,
    'rating', p.rating,
    'club', p.club,
    'legacy', p.legacy,
    'how', pu.how,
    'bought_at', pu.bought_at,
    'fee_paid', pu.fee_paid,
    'agent_fee', pu.agent_fee,
    'income_tax', pu.income_tax,
    'refund', CASE WHEN pu.already_refunded THEN 0 ELSE pu.total_paid END,
    'already_refunded', pu.already_refunded
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_player_legacy_preview(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.admin_mark_player_legacy(text)') IS NOT NULL AS mark_ready,
  to_regprocedure('public.admin_mark_legacy_and_refund(text)') IS NOT NULL AS mark_and_refund_ready,
  to_regprocedure('public.legacy_card_refund_internal(text,text,boolean)') IS NOT NULL AS refund_patch_present;
