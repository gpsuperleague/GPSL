-- =============================================================================
-- Club preference marks: Season 1 confirmed only
-- =============================================================================
-- Only owners with season1_invite_response = 'accepted' may mark interest/backup
-- on club_database / club auction preference UI.
-- Viewing marks is unchanged (waiting list / club owners / auction invitees).
--
-- Run once in Supabase SQL Editor (after club_auction_interest_allow_club_owners).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_auction_interest_is_season1_confirmed(
  p_owner_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = p_owner_id
      AND lower(coalesce(r.season1_invite_response, '')) = 'accepted'
  );
$$;

CREATE OR REPLACE FUNCTION public.club_auction_interest_can_mark()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
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

  -- Season 1 confirmed only
  IF NOT public.club_auction_interest_is_season1_confirmed(auth.uid()) THEN
    RETURN false;
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = auth.uid();

  v_status := coalesce(v_status, '');
  IF v_status = 'archived' THEN
    RETURN false;
  END IF;

  -- Still need to be a real owner context (club / waiting / auction invite)
  v_eligible :=
    EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid())
    OR v_status = 'awaiting_club_auction'
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

-- Friendlier errors on set
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
    IF NOT public.club_auction_interest_is_season1_confirmed(v_owner_id) THEN
      RAISE EXCEPTION 'Only Season 1 confirmed owners can mark club preferences';
    END IF;
    RAISE EXCEPTION 'You need an owner tag to mark preferred clubs';
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

  IF NOT public.club_auction_interest_can_mark() THEN
    IF NOT public.club_auction_interest_is_season1_confirmed(v_owner_id) THEN
      RAISE EXCEPTION 'Only Season 1 confirmed owners can change club preferences';
    END IF;
    RAISE EXCEPTION 'You cannot change club preference marks';
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

-- Same list shape as club_auction_interest_backup + season1_confirmed flag
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
  v_s1 boolean;
  v_my_interest jsonb;
  v_my_backup jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  BEGIN
    SELECT nullif(btrim(coalesce(gs.club_auction_discord_chat_url, '')), '')
    INTO v_url
    FROM public.global_settings gs
    WHERE gs.id = 1;
  EXCEPTION WHEN undefined_column THEN
    v_url := NULL;
  END;

  v_frozen := public.club_auction_interests_frozen_now();
  v_can_mark := public.club_auction_interest_can_mark();
  v_can_view := public.club_auction_interest_can_view();
  v_s1 := public.club_auction_interest_is_season1_confirmed(auth.uid());

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
    'season1_confirmed', coalesce(v_s1, false),
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

GRANT EXECUTE ON FUNCTION public.club_auction_interest_is_season1_confirmed(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_can_mark() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_set(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_clear(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_list() TO authenticated;

-- ---------------------------------------------------------------------------
-- Cleanup: drop marks from owners who are not Season 1 confirmed
-- Safe to re-run. Preview first with the SELECT below if desired.
-- ---------------------------------------------------------------------------
-- Preview (optional):
-- SELECT i.owner_id,
--        public.owner_registry_resolve_tag(i.owner_id) AS owner_tag,
--        i.club_short_name,
--        i.mark_kind,
--        r.season1_invite_response
-- FROM public.club_auction_interests i
-- LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = i.owner_id
-- WHERE NOT public.club_auction_interest_is_season1_confirmed(i.owner_id)
-- ORDER BY owner_tag, i.club_short_name;

DELETE FROM public.club_auction_interests i
WHERE NOT public.club_auction_interest_is_season1_confirmed(i.owner_id);

NOTIFY pgrst, 'reload schema';
