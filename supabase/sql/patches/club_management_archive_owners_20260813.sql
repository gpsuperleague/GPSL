-- =============================================================================
-- Club Management: soft-archive / create clubs + owners roster for club history
--
-- Archived clubs keep ShortName and all history FKs; they are hidden from
-- normal pickers but remain readable for history pages.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS archived_note text;

CREATE INDEX IF NOT EXISTS clubs_is_archived_idx
  ON public."Clubs" (is_archived)
  WHERE is_archived = true;

COMMENT ON COLUMN public."Clubs".is_archived IS
  'Soft-archive: club retained with full history; excluded from active league pickers.';

-- ---------------------------------------------------------------------------
-- Admin: create club
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_club_create(
  p_short_name text,
  p_club_name text,
  p_stadium text DEFAULT NULL,
  p_capacity integer DEFAULT 30000,
  p_nation text DEFAULT NULL,
  p_continent text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(p_short_name));
  v_name text := btrim(p_club_name);
  v_stadium text := nullif(btrim(coalesce(p_stadium, '')), '');
  v_nation text := nullif(btrim(coalesce(p_nation, '')), '');
  v_continent text := nullif(lower(btrim(coalesce(p_continent, ''))), '');
  v_cap int := coalesce(p_capacity, 30000);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_short IS NULL OR v_short = '' OR v_short = 'FOREIGN' THEN
    RAISE EXCEPTION 'ShortName is required (cannot be FOREIGN)';
  END IF;

  IF v_short !~ '^[A-Z0-9]{2,12}$' THEN
    RAISE EXCEPTION 'ShortName must be 2–12 letters/digits (A–Z, 0–9)';
  END IF;

  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'Club name is required';
  END IF;

  IF v_cap < 1000 OR v_cap > 200000 THEN
    RAISE EXCEPTION 'Capacity must be between 1,000 and 200,000';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_short) THEN
    RAISE EXCEPTION 'Club ShortName % already exists', v_short;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE lower(btrim(c."Club")) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'Club name % already exists', v_name;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'continent'
  ) THEN
    EXECUTE format(
      'INSERT INTO public."Clubs" (
         "ShortName", "Club", "Stadium", "Capacity", "Nation", continent, is_archived
       ) VALUES ($1, $2, $3, $4, $5, $6, false)'
    )
    USING
      v_short,
      v_name,
      coalesce(v_stadium, v_name || ' Stadium'),
      v_cap,
      coalesce(v_nation, 'Unknown'),
      v_continent;
  ELSE
    INSERT INTO public."Clubs" (
      "ShortName", "Club", "Stadium", "Capacity", "Nation", is_archived
    )
    VALUES (
      v_short,
      v_name,
      coalesce(v_stadium, v_name || ' Stadium'),
      v_cap,
      coalesce(v_nation, 'Unknown'),
      false
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'short_name', v_short,
    'club_name', v_name,
    'hint', 'Add badge/stadium/kit images under images/ keyed by ShortName, then assign an owner or leave vacant for auction.'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin: archive / unarchive (soft)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_club_archive(
  p_short_name text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(p_short_name));
  v_name text;
  v_owner uuid;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_short IS NULL OR v_short = '' OR v_short = 'FOREIGN' THEN
    RAISE EXCEPTION 'Valid club ShortName required';
  END IF;

  SELECT c."Club", c.owner_id
  INTO v_name, v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club % not found', v_short;
  END IF;

  -- Vacate owner (history rows keep owner_id on ranking archives)
  IF v_owner IS NOT NULL THEN
    PERFORM public.admin_club_vacate(v_short);
  END IF;

  UPDATE public."Clubs"
  SET is_archived = true,
      archived_at = now(),
      archived_note = nullif(btrim(coalesce(p_note, '')), ''),
      owner_id = NULL,
      owner = NULL
  WHERE "ShortName" = v_short;

  RETURN jsonb_build_object(
    'ok', true,
    'short_name', v_short,
    'club_name', v_name,
    'archived', true,
    'owner_vacated', v_owner IS NOT NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_unarchive(p_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(p_short_name));
  v_name text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT c."Club" INTO v_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club % not found', v_short;
  END IF;

  UPDATE public."Clubs"
  SET is_archived = false,
      archived_at = NULL,
      archived_note = NULL
  WHERE "ShortName" = v_short;

  RETURN jsonb_build_object(
    'ok', true,
    'short_name', v_short,
    'club_name', v_name,
    'archived', false
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_clubs_list(p_include_archived boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(to_jsonb(x) ORDER BY x.is_archived, x.club_name)
      FROM (
        SELECT
          c."ShortName" AS short_name,
          c."Club" AS club_name,
          c."Stadium" AS stadium,
          c."Capacity" AS capacity,
          c."Nation" AS nation,
          c.owner_id,
          c.owner AS owner_tag,
          coalesce(c.is_archived, false) AS is_archived,
          c.archived_at,
          c.archived_note
        FROM public."Clubs" c
        WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
          AND (
            coalesce(p_include_archived, true)
            OR coalesce(c.is_archived, false) = false
          )
      ) x
    ),
    '[]'::jsonb
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_create(text, text, text, integer, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_archive(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_unarchive(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clubs_list(boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Club owners roster (tenure + trophies while in charge)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_club_owners_roster(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_current uuid;
  v_rows jsonb;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'owners', '[]'::jsonb);
  END IF;

  SELECT c.owner_id INTO v_current
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  WITH season_rows AS (
    SELECT
      r.owner_id,
      r.season_id,
      r.season_label,
      r.season_total,
      h.division,
      h.final_position,
      h.pts AS league_pts,
      h.won,
      h.drawn,
      h.lost
    FROM public.competition_owner_season_ranking r
    LEFT JOIN public.competition_club_season_history_public h
      ON h.season_id = r.season_id
     AND h.club_short_name = r.club_short_name
    WHERE r.club_short_name = v_club
      AND r.owner_id IS NOT NULL
  ),
  by_owner AS (
    SELECT
      s.owner_id,
      count(*)::int AS seasons_count,
      min(s.season_id) AS first_season_id,
      max(s.season_id) AS last_season_id,
      (array_agg(s.season_label ORDER BY s.season_id ASC))[1] AS first_season_label,
      (array_agg(s.season_label ORDER BY s.season_id DESC))[1] AS last_season_label,
      coalesce(sum(s.season_total), 0) AS ranking_points,
      coalesce(sum(s.won), 0)::int AS won,
      coalesce(sum(s.drawn), 0)::int AS drawn,
      coalesce(sum(s.lost), 0)::int AS lost,
      coalesce(jsonb_agg(
        jsonb_build_object(
          'season_id', s.season_id,
          'season_label', s.season_label,
          'division', s.division,
          'final_position', s.final_position,
          'league_pts', s.league_pts,
          'ranking_points', s.season_total
        )
        ORDER BY s.season_id DESC
      ), '[]'::jsonb) AS seasons
    FROM season_rows s
    GROUP BY s.owner_id
  ),
  trophies AS (
    SELECT
      r.owner_id,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'season_id', h.season_id,
            'season_label', h.season_label,
            'honour_type', h.honour_type,
            'honour_label', h.honour_label,
            'division', h.division,
            'cup_code', h.cup_code
          )
          ORDER BY h.season_id DESC, h.honour_label
        ),
        '[]'::jsonb
      ) AS trophies,
      count(*)::int AS trophy_count
    FROM public.competition_club_honours_public h
    JOIN public.competition_owner_season_ranking r
      ON r.season_id = h.season_id
     AND r.club_short_name = h.club_short_name
    WHERE h.club_short_name = v_club
      AND r.owner_id IS NOT NULL
    GROUP BY r.owner_id
  ),
  combined AS (
    SELECT
      b.owner_id,
      coalesce(
        nullif(btrim(public.owner_registry_resolve_tag(b.owner_id)), ''),
        nullif(btrim(public.competition_owner_display_name(b.owner_id)), ''),
        left(b.owner_id::text, 8)
      ) AS owner_tag,
      public.competition_owner_display_name(b.owner_id) AS owner_name,
      b.seasons_count,
      b.first_season_id,
      b.last_season_id,
      b.first_season_label,
      b.last_season_label,
      b.ranking_points,
      b.won,
      b.drawn,
      b.lost,
      b.seasons,
      coalesce(t.trophies, '[]'::jsonb) AS trophies,
      coalesce(t.trophy_count, 0) AS trophy_count,
      (v_current IS NOT NULL AND b.owner_id = v_current) AS is_current
    FROM by_owner b
    LEFT JOIN trophies t ON t.owner_id = b.owner_id
  ),
  with_current AS (
    SELECT * FROM combined
    UNION ALL
    SELECT
      v_current,
      coalesce(
        nullif(btrim(c.owner), ''),
        nullif(btrim(public.owner_registry_resolve_tag(v_current)), ''),
        nullif(btrim(public.competition_owner_display_name(v_current)), ''),
        'Current owner'
      ),
      public.competition_owner_display_name(v_current),
      0,
      NULL::bigint,
      NULL::bigint,
      NULL::text,
      NULL::text,
      0::numeric,
      0,
      0,
      0,
      '[]'::jsonb,
      '[]'::jsonb,
      0,
      true
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club
      AND v_current IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM by_owner b WHERE b.owner_id = v_current)
  )
  SELECT coalesce(
    jsonb_agg(
      to_jsonb(w)
      ORDER BY w.is_current DESC, w.last_season_id DESC NULLS LAST, w.trophy_count DESC
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM with_current w;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'owners', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_owners_roster(text)
  TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
