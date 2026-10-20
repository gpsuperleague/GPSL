-- =============================================================================
-- Owners Shop: underhanded "Side door" aisle + agent bribe brown envelope (₿50,000)
--
-- • Own aisle (theme_key = shady)
-- • Buy posts Building Society as anonymous personal cheque to a made-up payee
-- • Grants club inventory prize_type agent_bribe
-- • Playoff bribe on expiring contracts consumes envelope first; else wallet cheque
--
-- Bribe already existed on expiring contracts — this adds the shop SKU + disguise.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Fictitious cheque payees
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_wallet_fictitious_payee()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_names text[] := ARRAY[
    'Harcourt & Wynn Introductions',
    'Victoire Langford Associates',
    'J. P. Mellish (personal)',
    'Cedarlane Private Clients',
    'Osborne Grey Facilitation',
    'M. R. Quill Consultancy',
    'Ashcombe Quiet Services',
    'L. Fenwick Discretionary',
    'Northbridge Envelope Co.',
    'S. Crowe Intermediaries',
    'Pell & Dacre Private Office',
    'A. Voss Representation',
    'Kestrel Side Agreements Ltd',
    'R. Havelock Personal Account',
    'Whitcombe Soft Introductions'
  ];
BEGIN
  RETURN v_names[1 + floor(random() * array_length(v_names, 1))::int];
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_wallet_fictitious_payee() TO authenticated;

-- ---------------------------------------------------------------------------
-- Allow agent_bribe on shop items + club inventory
-- ---------------------------------------------------------------------------
ALTER TABLE public.owners_shop_items
  DROP CONSTRAINT IF EXISTS owners_shop_items_prize_type_check;
ALTER TABLE public.owners_shop_items
  ADD CONSTRAINT owners_shop_items_prize_type_check
  CHECK (prize_type = ANY (ARRAY[
    'medical_token', 'fee_discount', 'appeal_card', 'draft_token', 'agent_bribe'
  ]));

ALTER TABLE public.owners_shop_items
  DROP CONSTRAINT IF EXISTS owners_shop_items_param_check;
ALTER TABLE public.owners_shop_items
  ADD CONSTRAINT owners_shop_items_param_check
  CHECK (
    (prize_type = 'medical_token' AND param_int IN (2, 4, 6, 8, 10))
    OR (prize_type = 'fee_discount' AND param_int > 0 AND param_int <= 50)
    OR (prize_type = 'appeal_card' AND param_int IS NULL)
    OR (prize_type = 'draft_token' AND (param_int IS NULL OR param_int > 0))
    OR (prize_type = 'agent_bribe' AND param_int IS NULL)
  );

DO $$
DECLARE
  v_types text;
BEGIN
  -- Preserve any existing inventory types (e.g. ban_reduction) + agent_bribe
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_types
  FROM (
    SELECT unnest(ARRAY[
      'medical_token', 'fee_discount', 'appeal_card', 'draft_token',
      'ban_reduction', 'agent_bribe'
    ]) AS t
    UNION
    SELECT DISTINCT prize_type FROM public.club_prize_inventory WHERE prize_type IS NOT NULL
  ) s;

  ALTER TABLE public.club_prize_inventory
    DROP CONSTRAINT IF EXISTS club_prize_inventory_prize_type_check;
  EXECUTE format(
    'ALTER TABLE public.club_prize_inventory
       ADD CONSTRAINT club_prize_inventory_prize_type_check
       CHECK (prize_type = ANY (ARRAY[%s]))',
    v_types
  );

  ALTER TABLE public.club_prize_inventory
    DROP CONSTRAINT IF EXISTS club_prize_inventory_param_check;
  ALTER TABLE public.club_prize_inventory
    ADD CONSTRAINT club_prize_inventory_param_check
    CHECK (
      (prize_type = 'medical_token' AND param_int IN (2, 4, 6, 8, 10))
      OR (prize_type = 'fee_discount' AND param_int > 0 AND param_int <= 50)
      OR (prize_type = 'appeal_card' AND param_int IS NULL)
      OR (prize_type = 'draft_token' AND param_int IS NULL)
      OR (prize_type = 'ban_reduction' AND param_int IS NULL)
      OR (prize_type = 'agent_bribe' AND param_int IS NULL)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.prize_grant_inventory_item(
  p_club text,
  p_prize_type text,
  p_param_int int,
  p_source text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_window_phase text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_club text := btrim(p_club);
  v_meta jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_ident jsonb;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF p_prize_type NOT IN (
    'medical_token', 'fee_discount', 'appeal_card', 'draft_token',
    'ban_reduction', 'agent_bribe'
  ) THEN
    RAISE EXCEPTION 'Invalid prize type %', p_prize_type;
  END IF;

  IF p_prize_type = 'medical_token'
     AND to_regprocedure('public.medical_random_consultancy_identity()') IS NOT NULL THEN
    v_ident := public.medical_random_consultancy_identity();
    v_meta := v_meta || jsonb_build_object(
      'matches_removed', p_param_int,
      'group_name', v_ident->>'group_name',
      'consultant_name', v_ident->>'consultant_name',
      'label', v_ident->>'label',
      'consultancy_label', v_ident->>'label'
    );
  END IF;

  IF p_prize_type = 'agent_bribe' THEN
    v_meta := v_meta || jsonb_build_object(
      'label', 'Brown envelope — agent introduction',
      'underhanded', true
    );
  END IF;

  INSERT INTO public.club_prize_inventory (
    club_short_name, prize_type, param_int, source, season_id, window_phase, metadata
  )
  VALUES (
    v_club,
    p_prize_type,
    CASE
      WHEN p_prize_type IN ('appeal_card', 'draft_token', 'ban_reduction', 'agent_bribe')
        THEN NULL
      ELSE p_param_int
    END,
    p_source,
    p_season_id,
    p_window_phase,
    v_meta
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.prize_grant_inventory_item(text, text, int, text, bigint, text, jsonb)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Side door aisle + brown envelope SKU
-- ---------------------------------------------------------------------------
ALTER TABLE public.owners_shop_sections
  DROP CONSTRAINT IF EXISTS owners_shop_sections_theme_key_check;
ALTER TABLE public.owners_shop_sections
  ADD CONSTRAINT owners_shop_sections_theme_key_check
  CHECK (theme_key = ANY (ARRAY[
    'medical', 'discipline', 'default', 'coming', 'shady'
  ]));

INSERT INTO public.owners_shop_sections (code, label, kicker, intro, theme_key, sort_order, is_active)
VALUES (
  'side_door',
  'Side door',
  'Not on the map',
  'Cash only. No receipts for the club books. If anyone asks, you were buying soft drinks.',
  'shady',
  35,
  true
)
ON CONFLICT (code) DO UPDATE SET
  label = EXCLUDED.label,
  kicker = EXCLUDED.kicker,
  intro = EXCLUDED.intro,
  theme_key = EXCLUDED.theme_key,
  sort_order = EXCLUDED.sort_order,
  is_active = true,
  updated_at = now();

INSERT INTO public.owners_shop_items (
  section_id, sku_code, title, description, price, prize_type, param_int,
  quantity_granted, badge_label, sort_order, is_active, is_featured
)
SELECT
  s.id,
  'agent_bribe_envelope',
  'Brown envelope',
  'One discreet agent introduction. Use in Playoffs on Expiring contracts to reveal rival wage offers. Building Society shows a personal cheque to someone who does not exist.',
  50000::numeric,
  'agent_bribe',
  NULL::int,
  1,
  '‽',
  10,
  true,
  true
FROM public.owners_shop_sections s
WHERE s.code = 'side_door'
ON CONFLICT (sku_code) DO UPDATE SET
  section_id = EXCLUDED.section_id,
  title = EXCLUDED.title,
  description = EXCLUDED.description,
  price = EXCLUDED.price,
  prize_type = EXCLUDED.prize_type,
  param_int = EXCLUDED.param_int,
  quantity_granted = EXCLUDED.quantity_granted,
  badge_label = EXCLUDED.badge_label,
  sort_order = EXCLUDED.sort_order,
  is_active = true,
  is_featured = true,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- Admin save item: allow agent_bribe
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_owners_shop_save_item(
  p_id bigint DEFAULT NULL,
  p_section_id bigint DEFAULT NULL,
  p_sku_code text DEFAULT NULL,
  p_title text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_price numeric DEFAULT NULL,
  p_prize_type text DEFAULT NULL,
  p_param_int int DEFAULT NULL,
  p_quantity_granted int DEFAULT 1,
  p_badge_label text DEFAULT NULL,
  p_sort_order int DEFAULT 100,
  p_is_active boolean DEFAULT true,
  p_is_featured boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint := p_id;
  v_sku text := lower(btrim(coalesce(p_sku_code, '')));
  v_ptype text := lower(btrim(coalesce(p_prize_type, '')));
  v_price numeric(14, 2);
  v_pint int := p_param_int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_section_id IS NULL OR v_sku = '' OR nullif(btrim(coalesce(p_title, '')), '') IS NULL THEN
    RAISE EXCEPTION 'section_id, sku_code and title required';
  END IF;
  IF v_ptype NOT IN ('medical_token', 'fee_discount', 'appeal_card', 'draft_token', 'agent_bribe') THEN
    RAISE EXCEPTION 'Invalid prize_type';
  END IF;

  v_price := round(coalesce(p_price, 0)::numeric, 2);
  IF v_price < 0 THEN
    RAISE EXCEPTION 'Price cannot be negative';
  END IF;

  IF v_ptype IN ('appeal_card', 'agent_bribe') THEN
    v_pint := NULL;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.owners_shop_items (
      section_id, sku_code, title, description, price, prize_type, param_int,
      quantity_granted, badge_label, sort_order, is_active, is_featured
    )
    VALUES (
      p_section_id, v_sku, btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''),
      v_price, v_ptype, v_pint,
      greatest(1, least(20, coalesce(p_quantity_granted, 1))),
      nullif(btrim(coalesce(p_badge_label, '')), ''),
      coalesce(p_sort_order, 100),
      coalesce(p_is_active, true),
      coalesce(p_is_featured, false)
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.owners_shop_items
    SET
      section_id = p_section_id,
      sku_code = v_sku,
      title = btrim(p_title),
      description = nullif(btrim(coalesce(p_description, '')), ''),
      price = v_price,
      prize_type = v_ptype,
      param_int = v_pint,
      quantity_granted = greatest(1, least(20, coalesce(p_quantity_granted, 1))),
      badge_label = nullif(btrim(coalesce(p_badge_label, '')), ''),
      sort_order = coalesce(p_sort_order, 100),
      is_active = coalesce(p_is_active, true),
      is_featured = coalesce(p_is_featured, false),
      updated_at = now()
    WHERE id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Item not found';
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Buy: agent_bribe → anonymous cheque ledger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owners_shop_buy(p_item_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_item public.owners_shop_items%ROWTYPE;
  v_bal numeric(14, 2);
  v_ledger_id bigint;
  v_inv_ids bigint[] := ARRAY[]::bigint[];
  v_inv_id bigint;
  v_i int;
  v_season_id bigint;
  v_entry_type text;
  v_desc text;
  v_payee text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'Item required';
  END IF;

  SELECT * INTO v_item
  FROM public.owners_shop_items
  WHERE id = p_item_id AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item not available';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.owners_shop_sections s
    WHERE s.id = v_item.section_id AND s.is_active = true
  ) THEN
    RAISE EXCEPTION 'Section not available';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked — shop purchases stock on your current club';
  END IF;

  PERFORM public.owner_wallet_ensure(v_uid);

  SELECT balance INTO v_bal
  FROM public.owner_wallets
  WHERE owner_id = v_uid
  FOR UPDATE;

  IF coalesce(v_bal, 0) < v_item.price THEN
    RAISE EXCEPTION 'Insufficient owner balance (need %, have %)',
      v_item.price, coalesce(v_bal, 0);
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_item.prize_type = 'agent_bribe' THEN
    v_payee := public.owner_wallet_fictitious_payee();
    v_entry_type := 'agent_bribe';
    v_desc := format('Cheque to %s', v_payee);
  ELSE
    v_entry_type := 'shop_purchase';
    v_desc := format('Owners Shop — %s → %s', v_item.title, v_club);
  END IF;

  v_ledger_id := public._post_owner_ledger_internal(
    v_uid,
    v_entry_type,
    -abs(v_item.price),
    v_desc,
    jsonb_build_object(
      'source', 'owners_shop_buy',
      'item_id', v_item.id,
      'sku_code', v_item.sku_code,
      'club_short_name', v_club,
      'prize_type', v_item.prize_type,
      'param_int', v_item.param_int,
      'quantity_granted', v_item.quantity_granted,
      'payee', v_payee,
      'disguised', (v_item.prize_type = 'agent_bribe')
    ),
    v_season_id
  );

  FOR v_i IN 1..v_item.quantity_granted LOOP
    v_inv_id := public.prize_grant_inventory_item(
      v_club,
      v_item.prize_type,
      v_item.param_int,
      'owners_shop',
      v_season_id,
      NULL,
      jsonb_build_object(
        'shop_item_id', v_item.id,
        'sku_code', v_item.sku_code,
        'owner_id', v_uid,
        'ledger_id', v_ledger_id
      )
    );
    v_inv_ids := array_append(v_inv_ids, v_inv_id);
  END LOOP;

  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = v_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'ledger_id', v_ledger_id,
    'inventory_ids', to_jsonb(v_inv_ids),
    'club_short_name', v_club,
    'balance', coalesce(v_bal, 0),
    'item_title', v_item.title,
    'quantity', v_item.quantity_granted,
    'disguised_payee', v_payee
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owners_shop_buy(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Playoff bribe: prefer brown-envelope stock; wallet cheque if none
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expiring_bribe_reveal_contract_offers(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_pid text := btrim(p_player_id);
  v_holder text;
  v_phase text := public.gpsl_expiring_market_phase(now());
  v_season text;
  v_season_id bigint;
  v_bal numeric;
  v_cost numeric := 50000;
  v_leaked boolean := false;
  v_offers jsonb := '[]'::jsonb;
  v_player_name text;
  v_club_name text;
  v_headline text;
  v_payee text;
  v_inv_id bigint;
  v_used_envelope boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_phase <> 'playoff' THEN
    RAISE EXCEPTION 'Agent bribes are only available in the Playoff month';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT
    public.player_contracted_club_key(p."Contracted_Team"),
    p."Name"
  INTO v_holder, v_player_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF v_holder IS NULL OR upper(btrim(v_holder)) <> upper(btrim(v_club)) THEN
    RAISE EXCEPTION 'Only the holding club can bribe the agent for this player';
  END IF;

  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  IF EXISTS (
    SELECT 1
    FROM public.contract_expiry_offer_bribes b
    WHERE b.player_id = v_pid
      AND b.owner_id = v_uid
      AND b.season_label = v_season
  ) THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club_short_name', b.bidder_club_short_name,
          'wage_offer', b.wage_offer
        )
        ORDER BY b.wage_offer DESC, b.bidder_club_short_name
      ),
      '[]'::jsonb
    )
    INTO v_offers
    FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_pid
      AND b.season_label = v_season;

    RETURN jsonb_build_object(
      'ok', true,
      'already_bribed', true,
      'leaked', false,
      'cost', 0,
      'offers', v_offers
    );
  END IF;

  -- Prefer Side door brown envelope (already paid as disguised cheque at shop)
  SELECT i.id INTO v_inv_id
  FROM public.club_prize_inventory i
  WHERE upper(btrim(i.club_short_name)) = upper(btrim(v_club))
    AND i.prize_type = 'agent_bribe'
    AND i.status = 'available'
  ORDER BY i.id
  LIMIT 1
  FOR UPDATE;

  IF v_inv_id IS NOT NULL THEN
    UPDATE public.club_prize_inventory
    SET status = 'consumed',
        consumed_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'consumed_for', 'expiring_bribe',
          'player_id', v_pid
        )
    WHERE id = v_inv_id;
    v_used_envelope := true;
    v_cost := 0;
  ELSE
    PERFORM public.owner_wallet_ensure(v_uid);
    SELECT balance INTO v_bal
    FROM public.owner_wallets
    WHERE owner_id = v_uid
    FOR UPDATE;
    IF coalesce(v_bal, 0) < 50000 THEN
      RAISE EXCEPTION
        'Need ₿50,000 owner wealth (or a Side door brown envelope) to bribe the agent (you have ₿%)',
        to_char(coalesce(v_bal, 0), 'FM999,999,999');
    END IF;

    v_payee := public.owner_wallet_fictitious_payee();
    PERFORM public._post_owner_ledger_internal(
      v_uid,
      'agent_bribe',
      -50000,
      format('Cheque to %s', v_payee),
      jsonb_build_object(
        'player_id', v_pid,
        'club', v_club,
        'payee', v_payee,
        'disguised', true,
        'source', 'expiring_bribe_direct'
      ),
      NULL,
      true
    );
    v_cost := 50000;
  END IF;

  v_leaked := (random() < 0.05);

  INSERT INTO public.contract_expiry_offer_bribes (
    player_id, owner_id, season_label, leaked
  )
  VALUES (v_pid, v_uid, v_season, v_leaked);

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'club_short_name', b.bidder_club_short_name,
        'wage_offer', b.wage_offer
      )
      ORDER BY b.wage_offer DESC, b.bidder_club_short_name
    ),
    '[]'::jsonb
  )
  INTO v_offers
  FROM public.contract_expiry_wage_bids b
  WHERE b.player_id = v_pid
    AND b.season_label = v_season;

  IF v_leaked THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;

    BEGIN
      v_club_name := public.club_display_name(v_club);
    EXCEPTION
      WHEN OTHERS THEN
        v_club_name := v_club;
    END;

    v_headline :=
      'LEAK: '
      || coalesce(v_club_name, v_club)
      || ' bribed an agent for contract intel on '
      || coalesce(v_player_name, 'a player');

    IF v_season_id IS NOT NULL THEN
      INSERT INTO public.gpsl_transfer_rumours (
        season_id, source, kind, club_short_name, club_name,
        player_id, player_name, headline, expires_at
      )
      VALUES (
        v_season_id, 'idle', 'rumour', v_club, v_club_name,
        v_pid, v_player_name, v_headline,
        now() + interval '48 hours'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'already_bribed', false,
    'leaked', v_leaked,
    'cost', v_cost,
    'used_envelope', v_used_envelope,
    'payee', v_payee,
    'offers', v_offers,
    'headline', CASE WHEN v_leaked THEN v_headline ELSE NULL END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.expiring_bribe_reveal_contract_offers(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
