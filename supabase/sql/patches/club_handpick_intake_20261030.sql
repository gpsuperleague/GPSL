-- =============================================================================
-- Mid-season handpick intake (new owner club rebuild)
--
-- Separates from takeover inherit:
--   Handpick ON  → squad → FA (no transfer fees to this club), clear manager
--                  (no MV payout), set cash to default starting balance via ONE
--                  Central Bank adjustment. Other clubs' ledgers untouched.
--   Owner builds wishlist (players + optional manager) → admin approves at MV
--                  via existing admin_sign_free_agents_at_mv / manager_assign.
--   Handpick OFF → flag clear only (does not restore released squad).
--
-- UI: Season owner board Actions · handpick_squad.html
-- Safe re-run. Does NOT alter takeover / assign / vacate paths.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Clubs flag
-- ---------------------------------------------------------------------------

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS handpick_intake boolean NOT NULL DEFAULT false;

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS handpick_started_at timestamptz;

COMMENT ON COLUMN public."Clubs".handpick_intake IS
  'True while mid-season rebuild handpick is open for this club. Not used by takeover inherit.';
COMMENT ON COLUMN public."Clubs".handpick_started_at IS
  'When handpick_intake was last turned on (club reset applied).';

-- ---------------------------------------------------------------------------
-- Wishlist submissions
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.club_handpick_submissions (
  id bigserial PRIMARY KEY,
  club_short_name text NOT NULL,
  owner_id uuid,
  player_ids text[] NOT NULL DEFAULT '{}'::text[],
  manager_id bigint,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'withdrawn')),
  note text,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  reviewed_by uuid,
  review_note text,
  sign_result jsonb,
  CONSTRAINT club_handpick_submissions_club_fk
    FOREIGN KEY (club_short_name) REFERENCES public."Clubs" ("ShortName")
    ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS club_handpick_submissions_club_status_idx
  ON public.club_handpick_submissions (club_short_name, status, submitted_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS club_handpick_submissions_one_pending_per_club
  ON public.club_handpick_submissions (club_short_name)
  WHERE status = 'pending';

ALTER TABLE public.club_handpick_submissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_handpick_submissions_admin_all ON public.club_handpick_submissions;
CREATE POLICY club_handpick_submissions_admin_all
  ON public.club_handpick_submissions
  FOR ALL
  TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS club_handpick_submissions_owner_select ON public.club_handpick_submissions;
CREATE POLICY club_handpick_submissions_owner_select
  ON public.club_handpick_submissions
  FOR SELECT
  TO authenticated
  USING (
    owner_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE c."ShortName" = club_handpick_submissions.club_short_name
        AND c.owner_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.handpick_target_balance()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT greatest(
    coalesce(
      CASE
        WHEN to_regprocedure('public.club_auction_default_starting_balance()') IS NOT NULL
          THEN public.club_auction_default_starting_balance()
        ELSE NULL
      END,
      650000000::numeric
    ),
    0
  );
$$;

COMMENT ON FUNCTION public.handpick_target_balance() IS
  'Cash pot for mid-season handpick rebuild (default club starting balance).';

CREATE OR REPLACE FUNCTION public.handpick_caller_may_access_club(p_club text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_owner uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND public.is_gpsl_admin() THEN
    RETURN true;
  END IF;
  IF v_club = '' OR auth.uid() IS NULL THEN
    RETURN false;
  END IF;
  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club
  LIMIT 1;
  RETURN v_owner IS NOT NULL AND v_owner = auth.uid();
END;
$function$;

-- ---------------------------------------------------------------------------
-- Enable / disable (Season board toggle)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_club_handpick_set(
  p_club_short_name text,
  p_enabled boolean,
  p_confirm_reset boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $function$
DECLARE
  v_club_in text := upper(btrim(coalesce(p_club_short_name, '')));
  v_club text;
  v_name text;
  v_was boolean := false;
  v_mgr_id bigint;
  v_pid text;
  v_released int := 0;
  v_listings_closed int := 0;
  v_bal numeric := 0;
  v_target numeric := public.handpick_target_balance();
  v_delta numeric := 0;
  v_ledger_id bigint;
  v_mgr_result jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club_in = '' OR v_club_in = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  SELECT c."ShortName", c."Club", coalesce(c.handpick_intake, false)
  INTO v_club, v_name, v_was
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club_in
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found', 'club', v_club_in);
  END IF;

  -- Disable: clear flag + reject pending wishlists. Squad/cash unchanged.
  IF NOT coalesce(p_enabled, false) THEN
    UPDATE public."Clubs"
    SET handpick_intake = false
    WHERE "ShortName" = v_club;

    UPDATE public.club_handpick_submissions
    SET status = 'rejected',
        reviewed_at = now(),
        reviewed_by = auth.uid(),
        review_note = coalesce(review_note, 'Handpick turned off')
    WHERE club_short_name = v_club
      AND status = 'pending';

    RETURN jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_name', v_name,
      'handpick_intake', false,
      'was_handpick', v_was,
      'action', 'disabled'
    );
  END IF;

  -- Enable no-op if already on (do not re-wipe squad/cash).
  IF v_was THEN
    RETURN jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_name', v_name,
      'handpick_intake', true,
      'already_on', true,
      'action', 'noop'
    );
  END IF;

  IF NOT coalesce(p_confirm_reset, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'confirm_required',
      'club', v_club,
      'club_name', v_name,
      'detail', 'Confirm reset: release squad to FA, clear manager, set cash to rebuild pot.'
    );
  END IF;

  -- Close active/review listings for players currently at this club
  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.status IN ('Active', 'Review')
    AND EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = l.player_id::text
        AND upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
    );
  GET DIAGNOSTICS v_listings_closed = ROW_COUNT;

  -- Release squad → FA with NO compensation and NO transfer history.
  -- Other clubs keep every past deal / ledger line intact.
  FOR v_pid IN
    SELECT p."Konami_ID"::text
    FROM public."Players" p
    WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
  LOOP
    IF to_regprocedure('public.player_release_from_club(text)') IS NOT NULL THEN
      PERFORM public.player_release_from_club(v_pid);
    ELSE
      UPDATE public."Players"
      SET "Contracted_Team" = NULL,
          "Season_Signed" = NULL,
          contract_seasons_remaining = NULL,
          contract_wage = NULL
      WHERE "Konami_ID"::text = v_pid;
    END IF;
    v_released := v_released + 1;
  END LOOP;

  -- Clear manager with zero payout (do not credit club MV).
  SELECT m.id INTO v_mgr_id
  FROM public."Managers" m
  WHERE upper(nullif(btrim(m.contracted_club::text), '')) = v_club
  LIMIT 1;

  IF v_mgr_id IS NULL THEN
    SELECT c.manager_id INTO v_mgr_id
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;
  END IF;

  IF v_mgr_id IS NOT NULL THEN
    BEGIN
      v_mgr_result := public.manager_release_from_club(
        v_mgr_id,
        NULL,              -- no payout club
        0,                 -- zero payout
        'adjustment',
        format('Handpick intake — manager cleared (%s)', v_club),
        jsonb_build_object(
          'source', 'handpick_intake_reset',
          'club', v_club,
          'no_payout', true
        )
      );
    EXCEPTION WHEN OTHERS THEN
      -- Fallback: force clear without ledger
      UPDATE public."Managers"
      SET contracted_club = NULL,
          contract_seasons_remaining = 0,
          weekly_wage = 0,
          updated_at = now()
      WHERE id = v_mgr_id;
      UPDATE public."Clubs"
      SET manager_id = NULL,
          manager_rating = NULL
      WHERE "ShortName" = v_club;
      v_mgr_result := jsonb_build_object(
        'ok', true, 'fallback', true, 'manager_id', v_mgr_id, 'error', SQLERRM
      );
    END;
  END IF;

  -- Ensure finances row, then ONE CB adjustment to target (never reverse deals).
  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE upper(f.club_name) = v_club
  ) THEN
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_club, 0);
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_bal
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club
  FOR UPDATE;

  v_delta := v_target - coalesce(v_bal, 0);

  IF v_delta <> 0 THEN
    -- Use catalogue type 'adjustment' (always allowed) + metadata source tag.
    -- Never reverse other clubs' transfer/loan lines.
    v_ledger_id := public.post_club_ledger(
      v_club,
      'adjustment',
      v_delta,
      format(
        'Mid-season handpick rebuild budget → %s (was %s)',
        to_char(v_target, 'FM999,999,999,990'),
        to_char(coalesce(v_bal, 0), 'FM999,999,999,990')
      ),
      jsonb_build_object(
        'source', 'handpick_intake_reset',
        'kind', 'mid_season_handpick_rebuild',
        'club', v_club,
        'balance_before', v_bal,
        'target_balance', v_target,
        'delta', v_delta
      ),
      NULL,
      NULL,
      true,   -- Central Bank leg
      true
    );
  END IF;

  UPDATE public."Clubs"
  SET handpick_intake = true,
      handpick_started_at = now(),
      manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = v_club;

  -- Drop any stale pending wishlist from a prior attempt
  UPDATE public.club_handpick_submissions
  SET status = 'withdrawn',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = 'Superseded by handpick reset'
  WHERE club_short_name = v_club
    AND status = 'pending';

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'club_name', v_name,
    'handpick_intake', true,
    'action', 'enabled',
    'players_released', v_released,
    'listings_closed', v_listings_closed,
    'manager_release', v_mgr_result,
    'balance_before', v_bal,
    'target_balance', v_target,
    'balance_delta', v_delta,
    'ledger_id', v_ledger_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_club_handpick_set(text, boolean, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_club_handpick_set(text, boolean, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_handpick_intake_map()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_object_agg(c."ShortName", true)
    FROM public."Clubs" c
    WHERE coalesce(c.handpick_intake, false)
  ), '{}'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_handpick_intake_map() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_handpick_intake_map() TO authenticated;

-- ---------------------------------------------------------------------------
-- Context / search (owner of handpick club OR admin)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.handpick_club_context(p_club_short_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_my text;
  v_ctx jsonb;
  v_pending jsonb;
  v_handpick boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    IF public.is_gpsl_admin() THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'club_required');
    END IF;
    v_my := public.my_club_shortname();
    v_club := upper(btrim(coalesce(v_my, '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RAISE EXCEPTION 'Not allowed for this club';
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  -- Reuse admin build context shape when available (admin path).
  IF public.is_gpsl_admin()
     AND to_regprocedure('public.admin_sign_fa_club_build_context(text)') IS NOT NULL THEN
    v_ctx := public.admin_sign_fa_club_build_context(v_club);
  ELSE
    -- Owner-safe slim context
    SELECT jsonb_build_object(
      'ok', true,
      'club', v_club,
      'club_nation', c."Nation",
      'balance', coalesce(f.balance, 0),
      'income_tax_pct', coalesce((SELECT g.gov_income_tax_pct FROM public.global_settings g LIMIT 1), 0),
      'manager', (
        SELECT to_jsonb(m)
        FROM (
          SELECT mgr.id AS manager_id, mgr.name AS manager_name,
                 mgr.rating AS manager_rating, mgr.market_value AS manager_market_value
          FROM public."Managers" mgr
          WHERE upper(nullif(btrim(mgr.contracted_club::text), '')) = v_club
          LIMIT 1
        ) m
      ),
      'players', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'player_name', p."Name",
          'position', p."Position",
          'rating', p."Rating",
          'market_value', coalesce(
            nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          )
        ) ORDER BY p."Name")
        FROM public."Players" p
        WHERE upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club
      ), '[]'::jsonb),
      'min_squad_size', 24,
      'max_squad_size', 28,
      'target_squad_size', 24,
      'min_home_grown', 8,
      'min_under_21', 5,
      'min_goalkeepers', 1
    )
    INTO v_ctx
    FROM public."Clubs" c
    LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = v_club
    WHERE upper(c."ShortName") = v_club;
  END IF;

  SELECT to_jsonb(s) INTO v_pending
  FROM public.club_handpick_submissions s
  WHERE s.club_short_name = v_club
    AND s.status = 'pending'
  ORDER BY s.submitted_at DESC
  LIMIT 1;

  RETURN coalesce(v_ctx, jsonb_build_object('ok', false))
    || jsonb_build_object(
      'handpick_intake', v_handpick,
      'target_balance', public.handpick_target_balance(),
      'pending_submission', v_pending,
      'is_admin', public.is_gpsl_admin()
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_club_context(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_club_context(text) TO authenticated;

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

  -- Prefer the richer 4-arg admin search when present.
  IF to_regprocedure('public.admin_search_free_agents_for_sign(text,int,text,text)') IS NOT NULL THEN
    -- Temporarily allow by calling as security definer after gate above —
    -- admin_search still checks is_gpsl_admin, so duplicate search here.
    NULL;
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
      ORDER BY p."Rating" DESC NULLS LAST, p."Name"
      LIMIT greatest(1, least(coalesce(p_limit, 30), 80))
    ) r
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_search_free_agents(text, int, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_search_free_agents(text, int, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.handpick_search_managers(
  p_query text DEFAULT NULL,
  p_limit int DEFAULT 20
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
  v_club text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.is_gpsl_admin() THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
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
        m.nation AS nation
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

REVOKE ALL ON FUNCTION public.handpick_search_managers(text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_search_managers(text, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- Submit / list / approve / reject
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

  SELECT c.owner_id, coalesce(c.handpick_intake, false)
  INTO v_owner, v_handpick
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

  -- Dedupe + keep order
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

  RETURN jsonb_build_object(
    'ok', true,
    'submission_id', v_id,
    'club', v_club,
    'player_count', coalesce(array_length(v_clean, 1), 0),
    'manager_id', p_manager_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_submit_wishlist(text, text[], bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_submit_wishlist(text, text[], bigint, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.handpick_list_submissions(
  p_status text DEFAULT 'pending',
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text := lower(btrim(coalesce(p_status, 'pending')));
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.is_gpsl_admin() THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
    IF v_club = '' THEN
      RETURN '[]'::jsonb;
    END IF;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(to_jsonb(r) ORDER BY r.submitted_at DESC)
    FROM (
      SELECT
        s.id,
        s.club_short_name,
        c."Club" AS club_name,
        s.owner_id,
        r.owner_tag,
        s.player_ids,
        s.manager_id,
        m.name AS manager_name,
        m.rating AS manager_rating,
        coalesce(m.market_value, 0)::numeric AS manager_market_value,
        s.status,
        s.note,
        s.submitted_at,
        s.reviewed_at,
        s.review_note,
        s.sign_result,
        (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
            'player_id', p."Konami_ID"::text,
            'player_name', p."Name",
            'position', p."Position",
            'rating', p."Rating",
            'market_value', coalesce(
              nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
              0
            ),
            'is_fa', nullif(btrim(p."Contracted_Team"::text), '') IS NULL
          ) ORDER BY p."Name"), '[]'::jsonb)
          FROM public."Players" p
          WHERE p."Konami_ID"::text = ANY (s.player_ids)
        ) AS players
      FROM public.club_handpick_submissions s
      LEFT JOIN public."Clubs" c ON c."ShortName" = s.club_short_name
      LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = s.owner_id
      LEFT JOIN public."Managers" m ON m.id = s.manager_id
      WHERE (v_status = 'all' OR s.status = v_status)
        AND (v_club = '' OR s.club_short_name = v_club)
        AND (
          public.is_gpsl_admin()
          OR s.owner_id = auth.uid()
          OR c.owner_id = auth.uid()
        )
      ORDER BY s.submitted_at DESC
      LIMIT 100
    ) r
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_list_submissions(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_list_submissions(text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_handpick_reject_submission(
  p_submission_id bigint,
  p_review_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.club_handpick_submissions%ROWTYPE;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row
  FROM public.club_handpick_submissions
  WHERE id = p_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_row.status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_row.status);
  END IF;

  UPDATE public.club_handpick_submissions
  SET status = 'rejected',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = nullif(btrim(p_review_note), '')
  WHERE id = p_submission_id;

  RETURN jsonb_build_object(
    'ok', true,
    'submission_id', p_submission_id,
    'club', v_row.club_short_name,
    'status', 'rejected'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_handpick_reject_submission(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_handpick_reject_submission(bigint, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_handpick_approve_submission(
  p_submission_id bigint,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_row public.club_handpick_submissions%ROWTYPE;
  v_handpick boolean;
  v_sign jsonb;
  v_mgr jsonb;
  v_fee numeric;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row
  FROM public.club_handpick_submissions
  WHERE id = p_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_row.status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_row.status);
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE c."ShortName" = v_row.club_short_name;

  IF NOT coalesce(v_handpick, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_in_handpick');
  END IF;

  IF coalesce(array_length(v_row.player_ids, 1), 0) > 0 THEN
    IF to_regprocedure('public.admin_sign_free_agents_at_mv(text,text[],boolean)') IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sign_rpc_missing');
    END IF;
    v_sign := public.admin_sign_free_agents_at_mv(
      v_row.club_short_name,
      v_row.player_ids,
      coalesce(p_dry_run, true)
    );
    IF NOT coalesce((v_sign->>'ok')::boolean, false) THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'sign_failed',
        'sign_result', v_sign
      );
    END IF;
  ELSE
    v_sign := jsonb_build_object('ok', true, 'signed_count', 0, 'skipped_count', 0);
  END IF;

  IF v_row.manager_id IS NOT NULL THEN
    IF coalesce(p_dry_run, true) THEN
      SELECT coalesce(m.market_value, 0)::numeric INTO v_fee
      FROM public."Managers" m WHERE m.id = v_row.manager_id;
      v_mgr := jsonb_build_object(
        'ok', true,
        'dry_run', true,
        'manager_id', v_row.manager_id,
        'est_fee', coalesce(v_fee, 0)
      );
    ELSE
      BEGIN
        v_mgr := public.manager_assign_to_club(
          v_row.manager_id,
          v_row.club_short_name,
          2::smallint,
          NULL::numeric,
          true,
          jsonb_build_object('source', 'handpick_approve', 'submission_id', p_submission_id)
        );
      EXCEPTION WHEN OTHERS THEN
        v_mgr := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;
  END IF;

  IF NOT coalesce(p_dry_run, true) THEN
    UPDATE public.club_handpick_submissions
    SET status = 'approved',
        reviewed_at = now(),
        reviewed_by = auth.uid(),
        sign_result = jsonb_build_object('players', v_sign, 'manager', v_mgr)
    WHERE id = p_submission_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', coalesce(p_dry_run, true),
    'submission_id', p_submission_id,
    'club', v_row.club_short_name,
    'players', v_sign,
    'manager', v_mgr,
    'status', CASE WHEN coalesce(p_dry_run, true) THEN 'pending' ELSE 'approved' END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_handpick_approve_submission(bigint, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_handpick_approve_submission(bigint, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.admin_club_handpick_set(text,boolean,boolean)') IS NOT NULL AS set_rpc,
  to_regprocedure('public.handpick_submit_wishlist(text,text[],bigint,text)') IS NOT NULL AS submit_rpc,
  to_regprocedure('public.admin_handpick_approve_submission(bigint,boolean)') IS NOT NULL AS approve_rpc,
  to_regclass('public.club_handpick_submissions') IS NOT NULL AS submissions_table;
