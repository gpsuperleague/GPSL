-- =============================================================================
-- Admin: sign selected free agents to a club at market value
-- UI: admin_sign_players.html
--
-- For mid-season club setup (e.g. Flamengo) after auctions are closed.
-- Path matches populate-squad / draft: assign → Transfer_History (fee = MV) →
-- post_transfer_ledger_for_history (purchase + income tax + CB legs).
-- Does NOT re-seed opening balance / stadium.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_sign_free_agents_at_mv(
  p_club_short_name text,
  p_player_ids text[],
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_ids text[] := coalesce(p_player_ids, ARRAY[]::text[]);
  v_pid text;
  v_p record;
  v_mv numeric;
  v_history_id bigint;
  v_tax_pct numeric := 0;
  v_signed jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_fees numeric := 0;
  v_est_tax numeric := 0;
  v_balance numeric;
  v_squad int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE upper(c."ShortName") = v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found', 'club', v_club);
  END IF;

  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_players');
  END IF;

  BEGIN
    SELECT coalesce(g.gov_income_tax_pct, 0) INTO v_tax_pct
    FROM public.global_settings g
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_tax_pct := 0;
  END;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE upper(club_name) = v_club
  LIMIT 1;

  SELECT count(*)::int INTO v_squad
  FROM public."Players" p
  WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club;

  FOREACH v_pid IN ARRAY v_ids
  LOOP
    v_pid := btrim(coalesce(v_pid, ''));
    IF v_pid = '' THEN
      CONTINUE;
    END IF;

    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      p."Position" AS player_position,
      p."Rating" AS rating,
      nullif(btrim(p."Contracted_Team"::text), '') AS team,
      coalesce(p.pesdb_unavailable, false) AS legacy,
      coalesce(
        nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
        0
      ) AS mv
    INTO v_p
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid;

    IF NOT FOUND THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'player_id', v_pid, 'reason', 'not_found'
      ));
      CONTINUE;
    END IF;

    IF v_p.team IS NOT NULL THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'player_id', v_pid, 'player_name', v_p.player_name,
        'reason', 'not_free_agent', 'team', v_p.team
      ));
      CONTINUE;
    END IF;

    IF v_p.legacy THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'player_id', v_pid, 'player_name', v_p.player_name, 'reason', 'legacy_card'
      ));
      CONTINUE;
    END IF;

    IF to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
       AND public.gpdb_player_is_season_excluded(v_pid) THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'player_id', v_pid, 'player_name', v_p.player_name, 'reason', 'season_excluded'
      ));
      CONTINUE;
    END IF;

    v_mv := coalesce(v_p.mv, 0);
    IF v_mv <= 0 THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'player_id', v_pid, 'player_name', v_p.player_name, 'reason', 'no_market_value'
      ));
      CONTINUE;
    END IF;

    IF NOT p_dry_run THEN
      BEGIN
        IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
          PERFORM public.assert_player_available_for_signing(v_pid);
        END IF;

        PERFORM public.player_assign_to_club(v_pid, v_club, NULL::numeric, false);

        INSERT INTO public."Transfer_History" (
          player_id, seller_club_id, buyer_club_id, fee, agent_fee,
          transfer_time, listing_id, transfer_sale_note
        )
        VALUES (
          v_pid, NULL, v_club, v_mv, 0,
          now(), NULL, 'admin_sign_at_mv'
        )
        RETURNING id INTO v_history_id;

        IF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
          PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
        ELSIF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
          PERFORM public.post_transfer_ledger_for_history(v_history_id);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'player_id', v_pid, 'player_name', v_p.player_name,
          'reason', 'sign_blocked', 'detail', SQLERRM
        ));
        CONTINUE;
      END;
    END IF;

    v_fees := v_fees + v_mv;
    v_est_tax := v_est_tax + round(v_mv * v_tax_pct / 100.0, 2);
    v_signed := v_signed || jsonb_build_array(jsonb_build_object(
      'player_id', v_pid,
      'player_name', v_p.player_name,
      'position', v_p.player_position,
      'rating', v_p.rating,
      'market_value', v_mv,
      'est_income_tax', round(v_mv * v_tax_pct / 100.0, 2),
      'history_id', CASE WHEN p_dry_run THEN NULL ELSE v_history_id END
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', coalesce(p_dry_run, true),
    'club', v_club,
    'income_tax_pct', v_tax_pct,
    'balance_before', v_balance,
    'squad_before', v_squad,
    'signed_count', jsonb_array_length(v_signed),
    'skipped_count', jsonb_array_length(v_skipped),
    'fees_total', v_fees,
    'est_income_tax_total', v_est_tax,
    'est_total_cost', v_fees + v_est_tax,
    'signed', v_signed,
    'skipped', v_skipped
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_sign_free_agents_at_mv(text, text[], boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_sign_free_agents_at_mv(text, text[], boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_search_free_agents_for_sign(
  p_query text,
  p_limit int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := lower(btrim(coalesce(p_query, '')));
  v_lim int := greatest(1, least(coalesce(p_limit, 30), 80));
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF length(v_q) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(r) ORDER BY r.rating DESC NULLS LAST, r.player_name)
    FROM (
      SELECT
        p."Konami_ID"::text AS player_id,
        p."Name" AS player_name,
        p."Position" AS position,
        p."Rating" AS rating,
        p."Nation" AS nation,
        coalesce(
          nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
          0
        ) AS market_value,
        coalesce(p.pesdb_unavailable, false) AS legacy
      FROM public."Players" p
      WHERE nullif(btrim(p."Contracted_Team"::text), '') IS NULL
        AND coalesce(p.pesdb_unavailable, false) = false
        AND (
          lower(p."Name") LIKE '%' || v_q || '%'
          OR p."Konami_ID"::text = btrim(p_query)
        )
        AND (
          to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NULL
          OR NOT public.gpdb_player_is_season_excluded(p."Konami_ID"::text)
        )
      ORDER BY p."Rating" DESC NULLS LAST, p."Name"
      LIMIT v_lim
    ) r
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_search_free_agents_for_sign(text, int)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_search_free_agents_for_sign(text, int)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.admin_sign_free_agents_at_mv(text,text[],boolean)') IS NOT NULL AS sign_rpc,
  to_regprocedure('public.admin_search_free_agents_for_sign(text,int)') IS NOT NULL AS search_rpc;
