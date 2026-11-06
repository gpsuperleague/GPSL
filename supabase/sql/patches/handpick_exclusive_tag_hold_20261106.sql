-- =============================================================================
-- Handpick tags are exclusive across clubs in intake
-- =============================================================================
-- While a club has a player (or manager) tagged, no other handpick club can
-- tag them. Untagging releases the hold, including taking them off that club's
-- still-pending wishlist so an approval cannot sign someone they unchecked.
-- Run once in the Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.handpick_player_held_by_other(
  p_player_id text,
  p_club text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.club_handpick_basket b
    JOIN public."Clubs" c
      ON upper(c."ShortName") = upper(b.club_short_name)
    WHERE b.player_id = btrim(coalesce(p_player_id, ''))
      AND upper(b.club_short_name) <> upper(btrim(coalesce(p_club, '')))
      AND coalesce(c.handpick_intake, false)
  );
$$;

CREATE OR REPLACE FUNCTION public.handpick_manager_held_by_other(
  p_manager_id bigint,
  p_club text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.club_handpick_manager hm
    JOIN public."Clubs" c
      ON upper(c."ShortName") = upper(hm.club_short_name)
    WHERE hm.manager_id = p_manager_id
      AND upper(hm.club_short_name) <> upper(btrim(coalesce(p_club, '')))
      AND coalesce(c.handpick_intake, false)
  );
$$;

COMMENT ON FUNCTION public.handpick_player_held_by_other(text, text) IS
  'True when another club still in handpick intake has this player tagged.';

COMMENT ON FUNCTION public.handpick_manager_held_by_other(bigint, text) IS
  'True when another club still in handpick intake has this manager tagged.';

-- Drop holds left by clubs no longer in intake, then keep the earliest tag
-- when two intake clubs already tagged the same player or manager.
DELETE FROM public.club_handpick_basket b
WHERE NOT EXISTS (
  SELECT 1 FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(b.club_short_name)
    AND coalesce(c.handpick_intake, false)
);

DELETE FROM public.club_handpick_basket b
WHERE b.ctid IN (
  SELECT ctid FROM (
    SELECT
      bb.ctid,
      row_number() OVER (
        PARTITION BY bb.player_id
        ORDER BY bb.added_at, bb.club_short_name
      ) AS rn
    FROM public.club_handpick_basket bb
  ) d
  WHERE d.rn > 1
);

DELETE FROM public.club_handpick_manager hm
WHERE NOT EXISTS (
  SELECT 1 FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(hm.club_short_name)
    AND coalesce(c.handpick_intake, false)
);

DELETE FROM public.club_handpick_manager hm
WHERE hm.ctid IN (
  SELECT ctid FROM (
    SELECT
      mm.ctid,
      row_number() OVER (
        PARTITION BY mm.manager_id
        ORDER BY mm.added_at, mm.club_short_name
      ) AS rn
    FROM public.club_handpick_manager mm
  ) d
  WHERE d.rn > 1
);

CREATE UNIQUE INDEX IF NOT EXISTS club_handpick_basket_one_holder_idx
  ON public.club_handpick_basket (player_id);

CREATE UNIQUE INDEX IF NOT EXISTS club_handpick_manager_one_holder_idx
  ON public.club_handpick_manager (manager_id);

-- Ids currently tagged by some other intake club (for GPDB / MGDB checkboxes).
CREATE OR REPLACE FUNCTION public.handpick_other_holds(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' OR NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'player_ids', '[]'::jsonb,
      'manager_ids', '[]'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'player_ids', coalesce((
      SELECT jsonb_agg(b.player_id ORDER BY b.player_id)
      FROM public.club_handpick_basket b
      JOIN public."Clubs" c
        ON upper(c."ShortName") = upper(b.club_short_name)
      WHERE upper(b.club_short_name) <> v_club
        AND coalesce(c.handpick_intake, false)
    ), '[]'::jsonb),
    'manager_ids', coalesce((
      SELECT jsonb_agg(hm.manager_id ORDER BY hm.manager_id)
      FROM public.club_handpick_manager hm
      JOIN public."Clubs" c
        ON upper(c."ShortName") = upper(hm.club_short_name)
      WHERE upper(hm.club_short_name) <> v_club
        AND coalesce(c.handpick_intake, false)
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.handpick_player_held_by_other(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_manager_held_by_other(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_other_holds(text) TO authenticated;

-- Basket toggle: refuse a player another intake club already tagged.
-- Untag also drops them from this club's pending wishlist.
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

  PERFORM pg_advisory_xact_lock(hashtext('handpick-player'), hashtext(v_pid));

  SELECT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE upper(b.club_short_name) = v_club AND b.player_id = v_pid
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.club_handpick_basket
    WHERE upper(club_short_name) = v_club AND player_id = v_pid;

    UPDATE public.club_handpick_submissions
    SET player_ids = array_remove(player_ids, v_pid)
    WHERE upper(club_short_name) = v_club
      AND status = 'pending'
      AND v_pid = ANY (player_ids);

    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'player_id', v_pid,
      'star_tagged', public.handpick_basket_star_count(v_club),
      'star_tag_cap', v_cap
    );
  END IF;

  IF public.handpick_player_held_by_other(v_pid, v_club) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'held_by_other',
      'detail', 'Another club doing handpick already has this player tagged. They become free again if that club untags them.'
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

  BEGIN
    INSERT INTO public.club_handpick_basket (club_short_name, player_id, added_by)
    VALUES (v_club, v_pid, auth.uid())
    ON CONFLICT (club_short_name, player_id) DO NOTHING;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'held_by_other',
      'detail', 'Another club doing handpick already has this player tagged. They become free again if that club untags them.'
    );
  END;

  IF NOT EXISTS (
    SELECT 1 FROM public.club_handpick_basket b
    WHERE upper(b.club_short_name) = v_club AND b.player_id = v_pid
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'held_by_other',
      'detail', 'Another club doing handpick already has this player tagged. They become free again if that club untags them.'
    );
  END IF;

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

  PERFORM pg_advisory_xact_lock(hashtext('handpick-manager'), hashtext(v_mid::text));

  IF NOT p_tagged THEN
    DELETE FROM public.club_handpick_manager
    WHERE upper(club_short_name) = v_club
      AND manager_id = v_mid;

    UPDATE public.club_handpick_submissions
    SET manager_id = NULL
    WHERE upper(club_short_name) = v_club
      AND status = 'pending'
      AND manager_id = v_mid;

    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'manager_id', v_mid
    );
  END IF;

  IF public.handpick_manager_held_by_other(v_mid, v_club) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'held_by_other',
      'detail', 'Another club doing handpick already has this manager tagged. They become free again if that club untags them.'
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

  BEGIN
    INSERT INTO public.club_handpick_manager (club_short_name, manager_id, added_by)
    VALUES (v_club, v_mid, auth.uid())
    ON CONFLICT (club_short_name) DO UPDATE
      SET manager_id = excluded.manager_id,
          added_by = excluded.added_by,
          added_at = now();
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'held_by_other',
      'detail', 'Another club doing handpick already has this manager tagged. They become free again if that club untags them.'
    );
  END;

  UPDATE public.club_handpick_submissions
  SET manager_id = v_mid
  WHERE upper(club_short_name) = v_club
    AND status = 'pending'
    AND manager_id IS NOT NULL;

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

-- Search shows a hold flag so the Add / Select button can stay disabled.
CREATE OR REPLACE FUNCTION public.handpick_search_free_agents(
  p_query text DEFAULT NULL,
  p_limit int DEFAULT 30,
  p_nation text DEFAULT NULL,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' AND NOT public.is_gpsl_admin() THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_club
      AND coalesce(c.handpick_intake, false)
  ) AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Club is not in handpick intake';
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
        CASE
          WHEN p."Age" IS NULL OR btrim(p."Age"::text) = '' THEN NULL
          ELSE round(btrim(p."Age"::text)::numeric)::int
        END AS age,
        coalesce(
          nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
          0
        ) AS market_value,
        coalesce(
          nullif(regexp_replace(coalesce(p.contract_wage::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
          0
        ) AS contract_wage,
        coalesce(p.pesdb_unavailable, false) AS legacy,
        public.handpick_player_held_by_other(p."Konami_ID"::text, v_club) AS held_by_other
      FROM public."Players" p
      WHERE nullif(btrim(p."Contracted_Team"::text), '') IS NULL
        AND coalesce(p.pesdb_unavailable, false) = false
        AND (
          nullif(btrim(coalesce(p_nation, '')), '') IS NULL
          OR lower(btrim(p."Nation"::text)) = lower(btrim(p_nation))
        )
        AND (
          length(btrim(coalesce(p_query, ''))) < 2
          OR lower(p."Name") LIKE '%' || lower(btrim(p_query)) || '%'
          OR p."Konami_ID"::text = btrim(p_query)
        )
        AND (
          to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NULL
          OR NOT public.gpdb_player_is_season_excluded(p."Konami_ID"::text)
        )
        AND (
          to_regprocedure('public.player_foreign_contract_locked(text)') IS NULL
          OR NOT public.player_foreign_contract_locked(p."Konami_ID"::text)
        )
      ORDER BY p."Rating" DESC NULLS LAST, p."Name"
      LIMIT greatest(1, least(coalesce(p_limit, 30), 80))
    ) r
  ), '[]'::jsonb);
END;
$function$;

DROP FUNCTION IF EXISTS public.handpick_search_managers(text, int);

CREATE OR REPLACE FUNCTION public.handpick_search_managers(
  p_query text DEFAULT NULL,
  p_limit int DEFAULT 20,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := lower(btrim(coalesce(p_query, '')));
  v_lim int := greatest(1, least(coalesce(p_limit, 20), 50));
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.is_gpsl_admin() THEN
    IF v_club = '' OR NOT EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE upper(c."ShortName") = v_club
        AND coalesce(c.handpick_intake, false)
        AND c.owner_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'Handpick intake required';
    END IF;
  END IF;

  IF length(v_q) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(r) ORDER BY r.rating DESC NULLS LAST, r.manager_name)
    FROM (
      SELECT
        m.id AS manager_id,
        m.name AS manager_name,
        m.rating AS rating,
        coalesce(m.market_value, 0)::numeric AS market_value,
        m.nation AS nation,
        public.handpick_manager_held_by_other(m.id, v_club) AS held_by_other
      FROM public."Managers" m
      WHERE nullif(btrim(coalesce(m.contracted_club, '')), '') IS NULL
        AND (
          lower(m.name) LIKE '%' || v_q || '%'
          OR m.id::text = btrim(p_query)
        )
      ORDER BY m.rating DESC NULLS LAST, m.name
      LIMIT v_lim
    ) r
  ), '[]'::jsonb);
END;
$function$;

-- Submit refuses anyone another intake club currently has tagged.
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
    IF public.handpick_player_held_by_other(v_pid, v_club) THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'held_by_other',
        'player_id', v_pid,
        'detail', 'Another club doing handpick already has one of these players tagged. Remove them and try again.'
      );
    END IF;
    IF NOT (v_pid = ANY (v_clean)) THEN
      v_clean := array_append(v_clean, v_pid);
    END IF;
  END LOOP;

  IF p_manager_id IS NOT NULL AND public.handpick_manager_held_by_other(p_manager_id, v_club) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'held_by_other',
      'detail', 'Another club doing handpick already has this manager tagged.'
    );
  END IF;

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
  WHERE upper(club_short_name) = v_club
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

-- Clearing the basket releases every player hold and drops them from a pending wishlist.
CREATE OR REPLACE FUNCTION public.handpick_basket_clear(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_ids text[];
  v_n int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  SELECT coalesce(array_agg(b.player_id), ARRAY[]::text[])
  INTO v_ids
  FROM public.club_handpick_basket b
  WHERE upper(b.club_short_name) = v_club;

  DELETE FROM public.club_handpick_basket
  WHERE upper(club_short_name) = v_club;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF coalesce(array_length(v_ids, 1), 0) > 0 THEN
    UPDATE public.club_handpick_submissions
    SET player_ids = (
      SELECT coalesce(array_agg(pid), ARRAY[]::text[])
      FROM unnest(player_ids) AS pid
      WHERE NOT (pid = ANY (v_ids))
    )
    WHERE upper(club_short_name) = v_club
      AND status = 'pending';
  END IF;

  RETURN jsonb_build_object('ok', true, 'club', v_club, 'cleared', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.handpick_basket_clear(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_basket_toggle(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_manager_set(bigint, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_search_free_agents(text, int, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_search_managers(text, int, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.handpick_submit_wishlist(text, text[], bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
