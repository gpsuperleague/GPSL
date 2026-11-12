-- =============================================================================
-- Admin legacy mark / refund: survive the API timeout, quote market value
-- (2026-11-12)
-- =============================================================================
-- The admin page calls these as the authenticated role, which has
-- statement_timeout = 8s. Mark-and-refund locks the player and the club
-- balance. When the transfer-engine tick already holds those rows, the wait
-- is cancelled at 8s ("canceling statement due to statement timeout").
--
-- These functions now wait up to 3 minutes for that lock, then finish.
-- The preview quotes market value, which is what the refund actually credits.
-- A box with two IDs is rejected instead of looking up a player that does not
-- exist.
-- Safe re-run.
-- =============================================================================

ALTER FUNCTION public.legacy_card_refund_internal(text, text, boolean)
  SET statement_timeout = '180s';
ALTER FUNCTION public.legacy_card_refund_internal(text, text, boolean)
  SET lock_timeout = '180s';

ALTER FUNCTION public.player_legacy_card_refund(text)
  SET statement_timeout = '180s';
ALTER FUNCTION public.player_legacy_card_refund(text)
  SET lock_timeout = '180s';

ALTER FUNCTION public.admin_legacy_card_refund(text)
  SET statement_timeout = '180s';
ALTER FUNCTION public.admin_legacy_card_refund(text)
  SET lock_timeout = '180s';

CREATE OR REPLACE FUNCTION public.admin_mark_player_legacy(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
SET lock_timeout = '180s'
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
  IF v_pid ~ '\s' THEN
    RAISE EXCEPTION 'Enter one Konami ID at a time';
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
SET statement_timeout = '180s'
SET lock_timeout = '180s'
AS $function$
DECLARE
  v_mark jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF btrim(p_player_id) ~ '\s' THEN
    RAISE EXCEPTION 'Enter one Konami ID at a time';
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

CREATE OR REPLACE FUNCTION public.admin_player_legacy_preview(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
SET lock_timeout = '180s'
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  p record;
  pu record;
  v_mv numeric := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_pid ~ '\s' THEN
    RAISE EXCEPTION 'Enter one Konami ID at a time';
  END IF;

  SELECT pl."Name" AS name, pl."Position" AS position, pl."Rating" AS rating,
         public.player_contracted_club_key(pl."Contracted_Team") AS club,
         coalesce(pl.pesdb_unavailable, false) AS legacy,
         greatest(coalesce(nullif(btrim(pl.market_value::text), '')::numeric, 0), 0) AS market_value
  INTO p
  FROM public."Players" pl
  WHERE pl."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player % not found', v_pid;
  END IF;

  v_mv := p.market_value;

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
    'market_value', v_mv,
    'payout_kind', 'market_value',
    'refund', CASE
      WHEN p.club IS NULL OR pu.already_refunded THEN 0
      ELSE v_mv
    END,
    'already_refunded', pu.already_refunded
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_player_legacy_preview(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'refund_timeout', (
    SELECT proconfig
    FROM pg_proc
    WHERE oid = 'public.admin_mark_legacy_and_refund(text)'::regprocedure
  ),
  'verratti_refund', public.admin_player_legacy_preview('16823219') -> 'refund',
  'acerbi_refund', public.admin_player_legacy_preview('44676') -> 'refund',
  'acerbi_market', public.admin_player_legacy_preview('44676') -> 'market_value'
);
