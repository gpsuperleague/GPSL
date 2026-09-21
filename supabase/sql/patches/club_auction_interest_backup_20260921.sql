-- =============================================================================
-- Club interest / backup marks (waiting list) — 2026-09-21
--
-- Changes from club_auction_interest_20260918:
--   • Any club can be marked (owned or vacant), except FOREIGN
--   • Each waiting-list / invited owner: 1 primary interest + 1 backup
--   • mark_kind: 'interest' | 'backup'
--   • List returns per-club counts + owner tags for hover tooltips
--
-- Safe re-run. Apply after club_auction_interest_20260918.sql.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

ALTER TABLE public.club_auction_interests
  ADD COLUMN IF NOT EXISTS mark_kind text;

UPDATE public.club_auction_interests
SET mark_kind = 'interest'
WHERE mark_kind IS NULL;

ALTER TABLE public.club_auction_interests
  ALTER COLUMN mark_kind SET DEFAULT 'interest';

ALTER TABLE public.club_auction_interests
  ALTER COLUMN mark_kind SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'club_auction_interests_mark_kind_chk'
      AND conrelid = 'public.club_auction_interests'::regclass
  ) THEN
    ALTER TABLE public.club_auction_interests
      ADD CONSTRAINT club_auction_interests_mark_kind_chk
      CHECK (mark_kind IN ('interest', 'backup'));
  END IF;
END $$;

-- Keep at most one interest per owner (most recently updated)
WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY owner_id
      ORDER BY updated_at DESC NULLS LAST, id DESC
    ) AS rn
  FROM public.club_auction_interests
  WHERE mark_kind = 'interest'
)
DELETE FROM public.club_auction_interests i
USING ranked r
WHERE i.id = r.id
  AND r.rn > 1;

WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY owner_id
      ORDER BY updated_at DESC NULLS LAST, id DESC
    ) AS rn
  FROM public.club_auction_interests
  WHERE mark_kind = 'backup'
)
DELETE FROM public.club_auction_interests i
USING ranked r
WHERE i.id = r.id
  AND r.rn > 1;

DROP INDEX IF EXISTS public.club_auction_interests_one_interest_per_owner;
CREATE UNIQUE INDEX club_auction_interests_one_interest_per_owner
  ON public.club_auction_interests (owner_id)
  WHERE mark_kind = 'interest';

DROP INDEX IF EXISTS public.club_auction_interests_one_backup_per_owner;
CREATE UNIQUE INDEX club_auction_interests_one_backup_per_owner
  ON public.club_auction_interests (owner_id)
  WHERE mark_kind = 'backup';

COMMENT ON TABLE public.club_auction_interests IS
  'Waiting-list / invited owners: 1 primary interest + 1 backup club (any club except FOREIGN).';

COMMENT ON COLUMN public.club_auction_interests.mark_kind IS
  'interest = primary pick; backup = second choice.';

-- ---------------------------------------------------------------------------
-- Limits
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_auction_interest_max()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 1;
$$;

CREATE OR REPLACE FUNCTION public.club_auction_backup_max()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 1;
$$;

-- ---------------------------------------------------------------------------
-- Eligibility
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_auction_interest_can_mark()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_has_club boolean;
  v_status text;
  v_tag text;
  v_eligible boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  IF public.club_auction_interests_frozen_now() THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  IF v_has_club THEN
    RETURN false;
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = auth.uid();

  v_status := coalesce(v_status, '');
  v_eligible :=
    v_status = 'awaiting_club_auction'
    OR public.waiting_list_on_list_status(v_status);

  IF NOT v_eligible THEN
    RETURN false;
  END IF;

  v_tag := public.owner_registry_resolve_tag(auth.uid());
  IF v_tag IS NULL OR btrim(v_tag) = '' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

-- Waiting-list / invited / club owners can see who marked what
CREATE OR REPLACE FUNCTION public.club_auction_interest_can_view()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_has_club boolean;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  IF v_has_club THEN
    RETURN true;
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = auth.uid();

  v_status := coalesce(v_status, '');
  RETURN
    v_status = 'awaiting_club_auction'
    OR public.waiting_list_on_list_status(v_status);
END;
$function$;

-- ---------------------------------------------------------------------------
-- List
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_auction_interest_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_url text;
  v_frozen boolean;
  v_can_mark boolean;
  v_can_view boolean;
  v_my_interest jsonb;
  v_my_backup jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT nullif(btrim(coalesce(gs.club_auction_discord_chat_url, '')), '')
  INTO v_url
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_frozen := public.club_auction_interests_frozen_now();
  v_can_mark := public.club_auction_interest_can_mark();
  v_can_view := public.club_auction_interest_can_view();

  SELECT jsonb_build_object(
    'club_short_name', i.club_short_name,
    'club_name', c."Club",
    'note', nullif(btrim(coalesce(i.note, '')), ''),
    'mark_kind', i.mark_kind,
    'updated_at', i.updated_at
  )
  INTO v_my_interest
  FROM public.club_auction_interests i
  JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
  WHERE i.owner_id = auth.uid()
    AND i.mark_kind = 'interest'
    AND c."ShortName" <> 'FOREIGN'
  LIMIT 1;

  SELECT jsonb_build_object(
    'club_short_name', i.club_short_name,
    'club_name', c."Club",
    'note', nullif(btrim(coalesce(i.note, '')), ''),
    'mark_kind', i.mark_kind,
    'updated_at', i.updated_at
  )
  INTO v_my_backup
  FROM public.club_auction_interests i
  JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
  WHERE i.owner_id = auth.uid()
    AND i.mark_kind = 'backup'
    AND c."ShortName" <> 'FOREIGN'
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'frozen', v_frozen,
    'can_mark', v_can_mark,
    'can_view', v_can_view,
    'max_interests', public.club_auction_interest_max(),
    'max_backups', public.club_auction_backup_max(),
    'my_interest_count', CASE WHEN v_my_interest IS NULL THEN 0 ELSE 1 END,
    'my_backup_count', CASE WHEN v_my_backup IS NULL THEN 0 ELSE 1 END,
    'discord_chat_url', v_url,
    'mine_interest', v_my_interest,
    'mine_backup', v_my_backup,
    'mine', coalesce((
      SELECT jsonb_agg(x ORDER BY (x->>'mark_kind') DESC)
      FROM (
        SELECT v_my_interest AS x WHERE v_my_interest IS NOT NULL
        UNION ALL
        SELECT v_my_backup AS x WHERE v_my_backup IS NOT NULL
      ) s
    ), '[]'::jsonb),
    'interests', CASE
      WHEN NOT v_can_view THEN '[]'::jsonb
      ELSE coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'club_short_name', x.club_short_name,
            'club_name', x.club_name,
            'interest_count', x.interest_count,
            'backup_count', x.backup_count,
            'interest_owners', x.interest_owners,
            'backup_owners', x.backup_owners,
            'owners', x.interest_owners
          )
          ORDER BY x.club_short_name
        )
        FROM (
          SELECT
            i.club_short_name,
            c."Club" AS club_name,
            count(*) FILTER (WHERE i.mark_kind = 'interest')::int AS interest_count,
            count(*) FILTER (WHERE i.mark_kind = 'backup')::int AS backup_count,
            coalesce((
              SELECT jsonb_agg(
                jsonb_build_object(
                  'owner_id', i2.owner_id,
                  'owner_tag', coalesce(
                    nullif(btrim(public.owner_registry_resolve_tag(i2.owner_id)), ''),
                    '—'
                  ),
                  'note', nullif(btrim(coalesce(i2.note, '')), ''),
                  'is_me', i2.owner_id = auth.uid(),
                  'mark_kind', i2.mark_kind,
                  'updated_at', i2.updated_at
                )
                ORDER BY i2.updated_at ASC, i2.id ASC
              )
              FROM public.club_auction_interests i2
              WHERE i2.club_short_name = i.club_short_name
                AND i2.mark_kind = 'interest'
            ), '[]'::jsonb) AS interest_owners,
            coalesce((
              SELECT jsonb_agg(
                jsonb_build_object(
                  'owner_id', i2.owner_id,
                  'owner_tag', coalesce(
                    nullif(btrim(public.owner_registry_resolve_tag(i2.owner_id)), ''),
                    '—'
                  ),
                  'note', nullif(btrim(coalesce(i2.note, '')), ''),
                  'is_me', i2.owner_id = auth.uid(),
                  'mark_kind', i2.mark_kind,
                  'updated_at', i2.updated_at
                )
                ORDER BY i2.updated_at ASC, i2.id ASC
              )
              FROM public.club_auction_interests i2
              WHERE i2.club_short_name = i.club_short_name
                AND i2.mark_kind = 'backup'
            ), '[]'::jsonb) AS backup_owners
          FROM public.club_auction_interests i
          JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
          WHERE c."ShortName" <> 'FOREIGN'
          GROUP BY i.club_short_name, c."Club"
        ) x
      ), '[]'::jsonb)
    END
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Set: replace previous mark of same kind; any club except FOREIGN
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.club_auction_interest_set(text, text);
DROP FUNCTION IF EXISTS public.club_auction_interest_set(text, text, text);

CREATE OR REPLACE FUNCTION public.club_auction_interest_set(
  p_club_short_name text,
  p_note text DEFAULT NULL,
  p_mark_kind text DEFAULT 'interest'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_note text;
  v_kind text;
  v_owner_id uuid := auth.uid();
BEGIN
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.club_auction_interest_can_mark() THEN
    IF public.club_auction_interests_frozen_now() THEN
      RAISE EXCEPTION 'Club interests are frozen while bidding is open';
    END IF;
    RAISE EXCEPTION 'Only waiting / invited owners with an owner tag can mark club interest';
  END IF;

  v_kind := lower(nullif(btrim(coalesce(p_mark_kind, 'interest')), ''));
  IF v_kind IS NULL OR v_kind NOT IN ('interest', 'backup') THEN
    RAISE EXCEPTION 'mark_kind must be interest or backup';
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club short name is required';
  END IF;

  IF upper(v_club) = 'FOREIGN' THEN
    RAISE EXCEPTION 'Invalid club';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club
  ) THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  v_note := nullif(btrim(coalesce(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    RAISE EXCEPTION 'Note must be 280 characters or fewer';
  END IF;

  DELETE FROM public.club_auction_interests
  WHERE owner_id = v_owner_id
    AND mark_kind = v_kind
    AND club_short_name IS DISTINCT FROM v_club;

  DELETE FROM public.club_auction_interests
  WHERE owner_id = v_owner_id
    AND club_short_name = v_club
    AND mark_kind IS DISTINCT FROM v_kind;

  INSERT INTO public.club_auction_interests (owner_id, club_short_name, note, mark_kind)
  VALUES (v_owner_id, v_club, v_note, v_kind)
  ON CONFLICT (owner_id, club_short_name) DO UPDATE
  SET note = excluded.note,
      mark_kind = excluded.mark_kind,
      updated_at = now();

  RETURN public.club_auction_interest_list();
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_interest_clear(
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_owner_id uuid := auth.uid();
BEGIN
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF public.club_auction_interests_frozen_now() THEN
    RAISE EXCEPTION 'Club interests are frozen while bidding is open';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner_id
  ) THEN
    RAISE EXCEPTION 'Owners with a club cannot change auction interests';
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club short name is required';
  END IF;

  DELETE FROM public.club_auction_interests
  WHERE owner_id = v_owner_id
    AND club_short_name = v_club;

  RETURN public.club_auction_interest_list();
END;
$function$;

REVOKE ALL ON FUNCTION public.club_auction_interest_list() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_set(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_clear(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_can_mark() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_can_view() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_backup_max() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_max() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.club_auction_interest_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_set(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_clear(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_can_mark() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_can_view() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_backup_max() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_max() TO authenticated;

NOTIFY pgrst, 'reload schema';
