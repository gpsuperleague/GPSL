-- =============================================================================
-- Between-season club identity swap.
-- Refuses while a season is in setup, pre-season, or active.
-- Allowed when no season is current, or the current one is complete / summer break.
-- Does not rename club codes (Clubs_pkey is never written).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_franchise_identity_swap(
  p_left text,
  p_right text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_left text := upper(btrim(coalesce(p_left, '')));
  v_right text := upper(btrim(coalesce(p_right, '')));
  v_temp text := 'ZZ9';
  v_season_status text;
  v_keep text[] := ARRAY[
    'ShortName', 'Club', 'Stadium', 'Capacity', 'base_capacity', 'Nation', 'continent',
    'is_archived', 'archived_at', 'archived_note'
  ];
  v_src text;
  v_dst text;
  v_ord integer;
  r record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT lower(coalesce(s.status, ''))
  INTO v_season_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF coalesce(v_season_status, '') NOT IN ('', 'complete', 'summer_break') THEN
    RAISE EXCEPTION
      'Club identity swap is only available between seasons, after this season is closed and before the next one starts. Current season is %.',
      v_season_status;
  END IF;

  IF v_left = '' OR v_right = '' OR v_left = v_right THEN
    RAISE EXCEPTION 'Pick two different club codes';
  END IF;

  IF v_left IN ('FOREIGN', v_temp) OR v_right IN ('FOREIGN', v_temp) THEN
    RAISE EXCEPTION 'That club code cannot be swapped';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" WHERE "ShortName" = v_temp) THEN
    RAISE EXCEPTION 'Temporary code % is already a club. Rename that row first.', v_temp;
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  PERFORM 1 FROM public."Clubs" WHERE "ShortName" = v_left FOR UPDATE;
  PERFORM 1 FROM public."Clubs" WHERE "ShortName" = v_right FOR UPDATE;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" WHERE "ShortName" = v_left) THEN
    RAISE EXCEPTION 'Club % not found', v_left;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" WHERE "ShortName" = v_right) THEN
    RAISE EXCEPTION 'Club % not found', v_right;
  END IF;

  CREATE TEMP TABLE _club_snap ON COMMIT DROP AS
  SELECT c."ShortName", to_jsonb(c) AS j
  FROM public."Clubs" c
  WHERE c."ShortName" IN (v_left, v_right);

  CREATE TEMP TABLE _club_fks ON COMMIT DROP AS
  SELECT con.conrelid::regclass::text AS tbl,
         att.attname AS col,
         con.conname AS conname,
         pg_get_constraintdef(con.oid) AS def
  FROM pg_constraint con
  JOIN pg_class refcl ON refcl.oid = con.confrelid
  JOIN pg_namespace refns ON refns.oid = refcl.relnamespace
  JOIN pg_attribute refatt ON refatt.attrelid = con.confrelid AND refatt.attnum = con.confkey[1]
  JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
  WHERE con.contype = 'f'
    AND refns.nspname = 'public'
    AND refcl.relname = 'Clubs'
    AND refatt.attname = 'ShortName';

  FOR r IN SELECT DISTINCT tbl, conname FROM _club_fks LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
  END LOOP;

  CREATE TEMP TABLE _hops (
    ord int PRIMARY KEY,
    src text NOT NULL,
    dst text NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _hops (ord, src, dst) VALUES (1, v_left, v_temp);
  INSERT INTO _hops (ord, src, dst) VALUES (2, v_right, v_left);
  INSERT INTO _hops (ord, src, dst) VALUES (3, v_temp, v_right);

  BEGIN
    ALTER TABLE public."Players" DISABLE TRIGGER USER;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  FOR v_ord, v_src, v_dst IN
    SELECT h.ord, h.src, h.dst FROM _hops h ORDER BY h.ord
  LOOP
    FOR r IN
      SELECT tbl, col
      FROM _club_fks
      WHERE tbl NOT IN ('"Clubs"', 'public."Clubs"', 'Clubs')
        AND tbl NOT ILIKE '%stadium_expansion_orders%'
        AND tbl NOT ILIKE '%stadium_expansion_quotes%'
    LOOP
      EXECUTE format('UPDATE %s SET %I = $1 WHERE %I = $2', r.tbl, r.col, r.col)
        USING v_dst, v_src;
    END LOOP;

    FOR r IN
      SELECT * FROM (VALUES
        ('public."Players"',                       'Contracted_Team'),
        ('public."Club_Finances"',                 'club_name'),
        ('public."Transfer_History"',              'seller_club_id'),
        ('public."Transfer_History"',              'buyer_club_id'),
        ('public."Player_Transfer_Listings"',      'seller_club_id'),
        ('public."Player_Transfer_Listings"',      'current_highest_bidder'),
        ('public."Player_Transfer_Bids"',          'bidder_club_id'),
        ('public."Player_Transfer_Bids"',          'seller_club_id'),
        ('public.club_squad_player_designations',  'club_short_name'),
        ('public.competition_cup_first_round_byes','club_short_name'),
        ('public.competition_fixtures',            'cup_pen_winner_club_short_name'),
        ('public.competition_result_submissions',  'pen_winner_club_short_name'),
        ('public.special_auctions',                'winning_club_id'),
        ('public.special_auction_bids',            'club_id'),
        ('public.draft_auction_favourites',        'club_id'),
        ('public.contract_expiry_wage_bids',       'bidder_club_short_name'),
        ('public.club_auction_max_bids',           'club_short_name'),
        ('public.gpsl_owner_registry',             'last_club_short_name')
      ) AS t(tbl, col)
    LOOP
      IF EXISTS (
        SELECT 1 FROM _club_fks f
        WHERE f.tbl = r.tbl AND f.col = r.col
      ) THEN
        CONTINUE;
      END IF;
      BEGIN
        EXECUTE format('UPDATE %s SET %I = $1 WHERE %I = $2', r.tbl, r.col, r.col)
          USING v_dst, v_src;
      EXCEPTION
        WHEN undefined_table OR undefined_column THEN NULL;
      END;
    END LOOP;
  END LOOP;

  BEGIN
    ALTER TABLE public."Players" ENABLE TRIGGER USER;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    ALTER TABLE public."Clubs" DISABLE TRIGGER USER;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  FOR r IN
    SELECT c.column_name, c.is_nullable
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'Clubs'
      AND c.is_generated = 'NEVER'
      AND NOT (c.column_name = ANY (v_keep))
  LOOP
    IF r.is_nullable = 'YES' AND EXISTS (
      SELECT 1
      FROM pg_index i
      JOIN pg_attribute a
        ON a.attrelid = i.indrelid
       AND a.attnum = ANY (i.indkey)
      WHERE i.indrelid = 'public."Clubs"'::regclass
        AND i.indisunique
        AND a.attname = r.column_name
        AND i.indnkeyatts = 1
    ) THEN
      EXECUTE format(
        'UPDATE public."Clubs" SET %I = NULL WHERE "ShortName" IN ($1, $2)',
        r.column_name
      )
      USING v_left, v_right;
    END IF;

    EXECUTE format(
      'UPDATE public."Clubs" c
       SET %I = rec.%I
       FROM _club_snap s
       CROSS JOIN LATERAL jsonb_populate_record(NULL::public."Clubs", s.j) AS rec
       WHERE c."ShortName" IN ($1, $2)
         AND s."ShortName" = CASE c."ShortName" WHEN $1 THEN $2 ELSE $1 END',
      r.column_name,
      r.column_name
    )
    USING v_left, v_right;
  END LOOP;

  BEGIN
    ALTER TABLE public."Clubs" ENABLE TRIGGER USER;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  FOR r IN SELECT DISTINCT tbl, conname, def FROM _club_fks LOOP
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', r.tbl, r.conname, r.def);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'left', v_left,
    'right', v_right,
    'season_status', coalesce(nullif(v_season_status, ''), 'between_seasons'),
    'left_name', (SELECT j->>'Club' FROM _club_snap WHERE "ShortName" = v_left),
    'right_name', (SELECT j->>'Club' FROM _club_snap WHERE "ShortName" = v_right),
    'left_stadium', (SELECT j->>'Stadium' FROM _club_snap WHERE "ShortName" = v_left),
    'right_stadium', (SELECT j->>'Stadium' FROM _club_snap WHERE "ShortName" = v_right)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_franchise_identity_swap(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_franchise_identity_swap(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
