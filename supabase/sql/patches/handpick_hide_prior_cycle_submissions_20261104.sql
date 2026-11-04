-- =============================================================================
-- Handpick: after squad reset / new intake cycle, hide prior wishlists
--
-- Owner (and admin owner-preview) was still showing the previous approved
-- submission even when Players were released and handpick_started_at bumped.
-- List RPC now only returns submissions from the current intake cycle.
-- Also: clear basket/manager when intake cycle restarts; clear tags on detach.
-- =============================================================================

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
          -- Current intake only (prior approved wishlists survive for audit,
          -- but must not appear after a handpick reset / new cycle).
          c.handpick_started_at IS NULL
          OR s.submitted_at >= c.handpick_started_at
        )
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

-- When a new handpick cycle starts, clear soft tags (basket / manager wishlist).
CREATE OR REPLACE FUNCTION public.trg_clubs_handpick_cycle_clear()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.handpick_started_at IS NOT NULL
     AND NEW.handpick_started_at IS DISTINCT FROM OLD.handpick_started_at THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = upper(btrim(NEW."ShortName"));
    DELETE FROM public.club_handpick_manager
    WHERE club_short_name = upper(btrim(NEW."ShortName"));

    -- Pending wishlists from the previous cycle are already withdrawn by
    -- admin_club_handpick_set; also mark prior approved rows as superseded so
    -- status reflects "not the live squad" after a reset.
    UPDATE public.club_handpick_submissions
    SET status = 'withdrawn',
        reviewed_at = coalesce(reviewed_at, now()),
        review_note = CASE
          WHEN coalesce(review_note, '') = '' THEN 'Superseded by handpick reset'
          WHEN review_note ILIKE '%superseded by handpick reset%' THEN review_note
          ELSE review_note || ' · Superseded by handpick reset'
        END
    WHERE club_short_name = upper(btrim(NEW."ShortName"))
      AND status IN ('pending', 'approved')
      AND submitted_at < NEW.handpick_started_at;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_clubs_handpick_cycle_clear ON public."Clubs";
CREATE TRIGGER trg_clubs_handpick_cycle_clear
  AFTER UPDATE OF handpick_started_at ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clubs_handpick_cycle_clear();

-- One-shot: supersede LIV (and any other club) approved wishlists from a prior cycle.
UPDATE public.club_handpick_submissions s
SET status = 'withdrawn',
    reviewed_at = coalesce(s.reviewed_at, now()),
    review_note = CASE
      WHEN coalesce(s.review_note, '') = '' THEN 'Superseded by handpick reset'
      WHEN s.review_note ILIKE '%superseded by handpick reset%' THEN s.review_note
      ELSE s.review_note || ' · Superseded by handpick reset'
    END
FROM public."Clubs" c
WHERE c."ShortName" = s.club_short_name
  AND c.handpick_started_at IS NOT NULL
  AND s.status IN ('pending', 'approved')
  AND s.submitted_at < c.handpick_started_at;

-- Owner detach/archive: drop soft handpick tags so vacant clubs start empty.
CREATE OR REPLACE FUNCTION public.admin_owner_detach_core(
  p_owner_id uuid,
  p_status text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_tag text;
  v_nation text;
  v_email text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_status NOT IN ('on_break', 'archived') THEN
    RAISE EXCEPTION 'Invalid detach status %', p_status;
  END IF;

  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_club, v_club_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = p_owner_id
  LIMIT 1;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Owner is not linked to any club';
  END IF;

  SELECT ion.nation_code INTO v_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club
    AND ion.is_active = true
  LIMIT 1;

  IF v_tag IS NULL THEN
    SELECT coalesce(nullif(btrim(r.owner_tag), ''), v_club)
    INTO v_tag
    FROM public.competition_owner_season_ranking r
    WHERE r.owner_id = p_owner_id
    ORDER BY r.season_id DESC
    LIMIT 1;
  END IF;

  SELECT u.email INTO v_email
  FROM auth.users u
  WHERE u.id = p_owner_id;

  UPDATE public."Clubs"
  SET owner_id = NULL,
      owner = NULL
  WHERE owner_id = p_owner_id;

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE club_short_name = v_club
    AND is_active = true;

  DELETE FROM public.club_handpick_basket
  WHERE club_short_name = v_club;
  DELETE FROM public.club_handpick_manager
  WHERE club_short_name = v_club;

  UPDATE public.club_handpick_submissions
  SET status = 'withdrawn',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_note = coalesce(nullif(btrim(review_note), ''), 'Owner left — handpick cleared')
  WHERE club_short_name = v_club
    AND status = 'pending';

  INSERT INTO public.gpsl_owner_registry (
    owner_id,
    status,
    owner_tag,
    last_club_short_name,
    last_nation_code,
    status_note,
    status_changed_at
  )
  VALUES (
    p_owner_id,
    p_status,
    v_tag,
    v_club,
    v_nation,
    nullif(btrim(p_note), ''),
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET status = excluded.status,
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = excluded.last_club_short_name,
      last_nation_code = excluded.last_nation_code,
      status_note = coalesce(excluded.status_note, gpsl_owner_registry.status_note),
      status_changed_at = now();

  RETURN jsonb_build_object(
    'owner_id', p_owner_id,
    'email', v_email,
    'status', p_status,
    'club_short_name', v_club,
    'club_name', v_club_name,
    'owner_tag', v_tag,
    'nation_code', v_nation
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_owner_detach_core(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_detach_core(uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify LIV owner-view list is empty for current cycle
SELECT
  c."ShortName",
  c.handpick_intake,
  c.handpick_started_at,
  (
    SELECT count(*) FROM public.club_handpick_submissions s
    WHERE s.club_short_name = 'LIV'
      AND (c.handpick_started_at IS NULL OR s.submitted_at >= c.handpick_started_at)
  ) AS current_cycle_subs,
  (
    SELECT count(*) FROM public.club_handpick_submissions s
    WHERE s.club_short_name = 'LIV' AND s.status = 'approved'
  ) AS approved_left
FROM public."Clubs" c
WHERE c."ShortName" = 'LIV';
