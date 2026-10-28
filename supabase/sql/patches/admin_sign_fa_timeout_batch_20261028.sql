-- =============================================================================
-- Admin sign FA at MV: raise statement_timeout + hoist existence checks
-- Large baskets were hitting PostgREST/API statement timeout (default ~8s–60s)
-- while assign + Transfer_History + post_transfer_ledger ran per player.
-- Safe re-run. Pair with UI batching in admin_sign_players.js.
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
SET statement_timeout = '180s'
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
  v_has_assert boolean;
  v_has_ledger2 boolean;
  v_has_ledger1 boolean;
  v_has_excl boolean;
BEGIN
  -- Local timeout also covers role/API defaults that ignore function SET
  PERFORM set_config('statement_timeout', '180s', true);

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

  -- Cap per call so one RPC cannot run for minutes; UI batches larger baskets
  IF coalesce(array_length(v_ids, 1), 0) > 8 AND NOT coalesce(p_dry_run, true) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'batch_too_large',
      'max_per_call', 8,
      'received', array_length(v_ids, 1),
      'detail', 'Sign at most 8 players per call; UI should batch.'
    );
  END IF;

  v_has_assert := to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL;
  v_has_ledger2 := to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL;
  v_has_ledger1 := to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL;
  v_has_excl := to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL;

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

    IF v_has_excl AND public.gpdb_player_is_season_excluded(v_pid) THEN
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
        IF v_has_assert THEN
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

        IF v_has_ledger2 THEN
          PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
        ELSIF v_has_ledger1 THEN
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

NOTIFY pgrst, 'reload schema';

SELECT to_regprocedure('public.admin_sign_free_agents_at_mv(text,text[],boolean)') IS NOT NULL AS sign_rpc;
