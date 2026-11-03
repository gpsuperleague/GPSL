-- =============================================================================
-- Handpick: max ₿50m overdraft on tagged wishlist (players + manager + tax).
-- Blocks basket tag, manager tag, and submit when projected balance < -50m.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handpick_overdraft_floor()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (-50000000)::numeric;
$$;

COMMENT ON FUNCTION public.handpick_overdraft_floor() IS
  'Lowest allowed projected cash after handpick wishlist fees+tax (₿50m overdraft).';

CREATE OR REPLACE FUNCTION public.handpick_player_market_value(p_player_id text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mv numeric := 0;
BEGIN
  SELECT coalesce(
    nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
    0
  )
  INTO v_mv
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(coalesce(p_player_id, ''));
  RETURN coalesce(v_mv, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.handpick_manager_market_value(p_manager_id bigint)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mv numeric := 0;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN 0;
  END IF;
  SELECT coalesce(
    nullif(regexp_replace(coalesce(m.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
    0
  )
  INTO v_mv
  FROM public."Managers" m
  WHERE m.id = p_manager_id;
  RETURN coalesce(v_mv, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.handpick_income_tax_pct()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((SELECT g.gov_income_tax_pct FROM public.global_settings g LIMIT 1), 0)::numeric;
$$;

-- Estimate fees + tax + projected balance for a wishlist shape.
-- p_player_ids: full player id list to price (NULL = current basket).
-- p_extra_player_id: add this player on top of basket (for tag preview).
-- p_exclude_player_id: remove this id from basket set (rarely used).
-- p_manager_id: manager to price; NULL = none; omit via sentinel not needed —
--   pass current tagged manager explicitly from callers.
CREATE OR REPLACE FUNCTION public.handpick_wishlist_finance_preview(
  p_club text,
  p_player_ids text[] DEFAULT NULL,
  p_extra_player_id text DEFAULT NULL,
  p_manager_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_balance numeric := 0;
  v_tax_pct numeric := public.handpick_income_tax_pct();
  v_floor numeric := public.handpick_overdraft_floor();
  v_fees numeric := 0;
  v_tax numeric := 0;
  v_total numeric := 0;
  v_after numeric := 0;
  v_ids text[] := ARRAY[]::text[];
  v_pid text;
  v_extra text := nullif(btrim(coalesce(p_extra_player_id, '')), '');
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_balance
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club
  LIMIT 1;

  IF p_player_ids IS NOT NULL THEN
    FOREACH v_pid IN ARRAY p_player_ids
    LOOP
      v_pid := btrim(coalesce(v_pid, ''));
      IF v_pid = '' THEN CONTINUE; END IF;
      IF NOT (v_pid = ANY (v_ids)) THEN
        v_ids := array_append(v_ids, v_pid);
      END IF;
    END LOOP;
  ELSE
    SELECT coalesce(array_agg(b.player_id ORDER BY b.player_id), ARRAY[]::text[])
    INTO v_ids
    FROM public.club_handpick_basket b
    WHERE b.club_short_name = v_club;
  END IF;

  IF v_extra IS NOT NULL AND NOT (v_extra = ANY (v_ids)) THEN
    v_ids := array_append(v_ids, v_extra);
  END IF;

  IF coalesce(array_length(v_ids, 1), 0) > 0 THEN
    SELECT coalesce(sum(public.handpick_player_market_value(x)), 0)
    INTO v_fees
    FROM unnest(v_ids) AS x;
  END IF;

  v_fees := coalesce(v_fees, 0) + public.handpick_manager_market_value(p_manager_id);
  v_tax := round((v_fees * v_tax_pct) / 100.0, 2);
  v_total := v_fees + v_tax;
  v_after := coalesce(v_balance, 0) - v_total;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'balance', coalesce(v_balance, 0),
    'fees', v_fees,
    'tax_pct', v_tax_pct,
    'tax', v_tax,
    'total_cost', v_total,
    'balance_after', v_after,
    'overdraft_floor', v_floor,
    'within_overdraft', v_after >= v_floor,
    'player_count', coalesce(array_length(v_ids, 1), 0),
    'manager_id', p_manager_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.handpick_current_manager_id(p_club text)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT hm.manager_id
  FROM public.club_handpick_manager hm
  WHERE hm.club_short_name = upper(nullif(btrim(coalesce(p_club, '')), ''))
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- Basket toggle — star cap + overdraft floor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handpick_basket_toggle(
  p_player_id text,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_handpick boolean := false;
  v_exists boolean := false;
  v_team text;
  v_rating numeric := 0;
  v_min numeric := 79;
  v_cap int := public.handpick_star_tag_cap();
  v_stars int;
  v_fin jsonb;
  v_mgr bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_pid = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_player');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF NOT v_handpick THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_in_handpick',
      'detail', 'Handpick intake is not open for this club.'
    );
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE b.club_short_name = v_club AND b.player_id = v_pid
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_club AND player_id = v_pid;
    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'player_id', v_pid,
      'star_tagged', public.handpick_basket_star_count(v_club),
      'star_tag_cap', v_cap
    );
  END IF;

  SELECT nullif(btrim(p."Contracted_Team"::text), ''),
         coalesce(
           nullif(regexp_replace(coalesce(p."Rating"::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
           0
         )
  INTO v_team, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'player_not_found');
  END IF;

  IF v_team IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_free_agent',
      'detail', 'Only free agents can be handpick-tagged.'
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
      AND coalesce(p.pesdb_unavailable, false)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'legacy_card');
  END IF;

  IF to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
     AND public.gpdb_player_is_season_excluded(v_pid) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'season_excluded');
  END IF;

  IF to_regprocedure('public.player_foreign_contract_locked(text)') IS NOT NULL
     AND public.player_foreign_contract_locked(v_pid) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'foreign_or_paid_up_lock',
      'detail', 'Unavailable until next season (foreign / paid-up lock).'
    );
  END IF;

  BEGIN
    IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
      PERFORM public.assert_player_available_for_signing(v_pid);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_signable',
      'detail', SQLERRM
    );
  END;

  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := coalesce(public.club_squad_star_min_rating()::numeric, 79);
  END IF;

  IF v_rating >= v_min THEN
    v_stars := public.handpick_basket_star_count(v_club);
    IF v_stars >= v_cap THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'star_tag_cap',
        'detail', format(
          'Handpick allows at most %s star players (≥%s) tagged at once. Untag a star first.',
          v_cap, v_min
        ),
        'star_tagged', v_stars,
        'star_tag_cap', v_cap,
        'star_min_rating', v_min
      );
    END IF;
  END IF;

  v_mgr := public.handpick_current_manager_id(v_club);
  v_fin := public.handpick_wishlist_finance_preview(v_club, NULL, v_pid, v_mgr);
  IF coalesce((v_fin->>'within_overdraft')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'overdraft_cap',
      'detail', format(
        'Wishlist would leave you more than ₿50m overdrawn (projected %s). Untag someone cheaper or pick a lower MV.',
        to_char(coalesce((v_fin->>'balance_after')::numeric, 0), 'FM999,999,999,999')
      ),
      'finance', v_fin
    );
  END IF;

  INSERT INTO public.club_handpick_basket (club_short_name, player_id, added_by)
  VALUES (v_club, v_pid, auth.uid())
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object(
    'ok', true,
    'tagged', true,
    'club', v_club,
    'player_id', v_pid,
    'star_tagged', public.handpick_basket_star_count(v_club),
    'star_tag_cap', v_cap,
    'finance', v_fin
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Manager tag — overdraft floor (replacing manager re-prices)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handpick_manager_set(
  p_manager_id bigint,
  p_tagged boolean,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_mid bigint := p_manager_id;
  v_name text;
  v_mv numeric := 0;
  v_rating numeric;
  v_nation text;
  v_fin jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' OR NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_club
      AND coalesce(c.handpick_intake, false)
  ) AND NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_in_handpick');
  END IF;

  IF v_mid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_manager');
  END IF;

  IF NOT p_tagged THEN
    DELETE FROM public.club_handpick_manager
    WHERE club_short_name = v_club
      AND manager_id = v_mid;
    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'manager_id', v_mid
    );
  END IF;

  SELECT
    m.name,
    m.rating,
    nullif(btrim(m.nation::text), ''),
    coalesce(
      nullif(regexp_replace(coalesce(m.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
      0
    )
  INTO v_name, v_rating, v_nation, v_mv
  FROM public."Managers" m
  WHERE m.id = v_mid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manager_not_found');
  END IF;

  IF nullif(btrim(coalesce((
    SELECT m.contracted_club::text FROM public."Managers" m WHERE m.id = v_mid
  ), '')), '') IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_free_agent',
      'detail', 'Only free-agent managers can be handpicked'
    );
  END IF;

  v_fin := public.handpick_wishlist_finance_preview(v_club, NULL, NULL, v_mid);
  IF coalesce((v_fin->>'within_overdraft')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'overdraft_cap',
      'detail', format(
        'Tagging this manager would leave you more than ₿50m overdrawn (projected %s). Untag players or pick a cheaper manager.',
        to_char(coalesce((v_fin->>'balance_after')::numeric, 0), 'FM999,999,999,999')
      ),
      'finance', v_fin
    );
  END IF;

  INSERT INTO public.club_handpick_manager (club_short_name, manager_id, added_by)
  VALUES (v_club, v_mid, auth.uid())
  ON CONFLICT (club_short_name) DO UPDATE
    SET manager_id = excluded.manager_id,
        added_by = excluded.added_by,
        added_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'tagged', true,
    'club', v_club,
    'manager_id', v_mid,
    'manager', jsonb_build_object(
      'manager_id', v_mid,
      'manager_name', v_name,
      'rating', v_rating,
      'nation', v_nation,
      'market_value', v_mv
    ),
    'finance', v_fin
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Submit — refuse wishlists past overdraft floor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handpick_submit_wishlist(
  p_club_short_name text,
  p_player_ids text[],
  p_manager_id bigint DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_ids text[] := coalesce(p_player_ids, ARRAY[]::text[]);
  v_owner uuid;
  v_handpick boolean;
  v_id bigint;
  v_clean text[] := ARRAY[]::text[];
  v_pid text;
  v_club_name text;
  v_owner_tag text;
  v_mgr_name text;
  v_player_n int := 0;
  v_body text;
  v_alert_id bigint;
  v_fin jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed for this club';
  END IF;

  SELECT c.owner_id, coalesce(c.handpick_intake, false), c."Club"
  INTO v_owner, v_handpick, v_club_name
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF NOT v_handpick THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_in_handpick');
  END IF;

  IF coalesce(array_length(v_ids, 1), 0) = 0 AND p_manager_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'empty_wishlist');
  END IF;

  FOREACH v_pid IN ARRAY v_ids
  LOOP
    v_pid := btrim(coalesce(v_pid, ''));
    IF v_pid = '' THEN CONTINUE; END IF;
    IF NOT (v_pid = ANY (v_clean)) THEN
      v_clean := array_append(v_clean, v_pid);
    END IF;
  END LOOP;

  IF p_manager_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public."Managers" m
    WHERE m.id = p_manager_id
      AND nullif(btrim(coalesce(m.contracted_club, '')), '') IS NULL
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manager_not_fa');
  END IF;

  v_fin := public.handpick_wishlist_finance_preview(v_club, v_clean, NULL, p_manager_id);
  IF coalesce((v_fin->>'within_overdraft')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'overdraft_cap',
      'detail', format(
        'Cannot submit: wishlist would leave more than ₿50m overdrawn (projected %s).',
        to_char(coalesce((v_fin->>'balance_after')::numeric, 0), 'FM999,999,999,999')
      ),
      'finance', v_fin
    );
  END IF;

  UPDATE public.club_handpick_submissions
  SET status = 'withdrawn',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = 'Replaced by newer wishlist'
  WHERE club_short_name = v_club
    AND status = 'pending';

  INSERT INTO public.club_handpick_submissions (
    club_short_name, owner_id, player_ids, manager_id, note, status
  ) VALUES (
    v_club,
    coalesce(v_owner, auth.uid()),
    v_clean,
    p_manager_id,
    nullif(btrim(p_note), ''),
    'pending'
  )
  RETURNING id INTO v_id;

  v_player_n := coalesce(array_length(v_clean, 1), 0);

  IF p_manager_id IS NOT NULL THEN
    SELECT m.name INTO v_mgr_name
    FROM public."Managers" m
    WHERE m.id = p_manager_id;
  END IF;

  BEGIN
    SELECT nullif(btrim(r.owner_tag), '') INTO v_owner_tag
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = coalesce(v_owner, auth.uid());
  EXCEPTION WHEN OTHERS THEN
    v_owner_tag := NULL;
  END;
  IF v_owner_tag IS NULL THEN
    BEGIN
      SELECT nullif(btrim(o.owner_tag), '') INTO v_owner_tag
      FROM public."Owners" o
      WHERE o.id = coalesce(v_owner, auth.uid())
         OR o.owner_id = coalesce(v_owner, auth.uid());
    EXCEPTION WHEN OTHERS THEN
      v_owner_tag := NULL;
    END;
  END IF;

  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    BEGIN
      v_body := format(
        E'%s (%s) submitted a mid-season handpick wishlist.\nPlayers: %s\nManager: %s\nOwner: %s\n\nReview and approve on Handpick Squad (or Season owner board).',
        coalesce(nullif(btrim(v_club_name), ''), v_club),
        v_club,
        v_player_n::text,
        coalesce(nullif(btrim(v_mgr_name), ''), CASE WHEN p_manager_id IS NULL THEN '— none —' ELSE ('#' || p_manager_id::text) END),
        coalesce(v_owner_tag, '—')
      );
      IF nullif(btrim(p_note), '') IS NOT NULL THEN
        v_body := v_body || E'\n\nOwner note: ' || btrim(p_note);
      END IF;

      v_alert_id := public.gpsl_staff_alert_create(
        'handpick_wishlist',
        format('Handpick wishlist: %s', v_club),
        v_body,
        format('handpick_squad.html?club=%s', v_club),
        jsonb_build_object(
          'club_short_name', v_club,
          'submission_id', v_id,
          'player_count', v_player_n,
          'manager_id', p_manager_id,
          'owner_id', coalesce(v_owner, auth.uid())
        ),
        format('handpick_wishlist:%s', v_id)
      );
    EXCEPTION WHEN OTHERS THEN
      v_alert_id := NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'submission_id', v_id,
    'club', v_club,
    'player_count', v_player_n,
    'manager_id', p_manager_id,
    'staff_alert_id', v_alert_id,
    'finance', v_fin
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_overdraft_floor() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_player_market_value(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_manager_market_value(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_income_tax_pct() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_wishlist_finance_preview(text, text[], text, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_current_manager_id(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_basket_toggle(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_manager_set(bigint, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handpick_submit_wishlist(text, text[], bigint, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.handpick_overdraft_floor() TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_player_market_value(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_manager_market_value(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_income_tax_pct() TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_wishlist_finance_preview(text, text[], text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_current_manager_id(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_basket_toggle(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_manager_set(bigint, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_submit_wishlist(text, text[], bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
