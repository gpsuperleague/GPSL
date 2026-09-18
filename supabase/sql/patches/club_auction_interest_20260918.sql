-- =============================================================================
-- Club auction pre-interest marks + Discord auction chat link
--
-- Waiting / invited owners can mark up to 3 vacant clubs they want, with an
-- optional note. Everyone can see who is interested so owners can negotiate
-- before bidding. Marks freeze when club auction bidding opens.
--
-- Also adds global_settings.club_auction_discord_chat_url (admin-set).
--
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS club_auction_discord_chat_url text;

COMMENT ON COLUMN public.global_settings.club_auction_discord_chat_url IS
  'Invite / channel URL for the Discord club auction chat (shown on club auction page).';

CREATE TABLE IF NOT EXISTS public.club_auction_interests (
  id bigserial PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT club_auction_interests_owner_club_uidx UNIQUE (owner_id, club_short_name),
  CONSTRAINT club_auction_interests_note_len_chk
    CHECK (note IS NULL OR char_length(note) <= 280)
);

CREATE INDEX IF NOT EXISTS club_auction_interests_club_idx
  ON public.club_auction_interests (club_short_name);

CREATE INDEX IF NOT EXISTS club_auction_interests_owner_idx
  ON public.club_auction_interests (owner_id);

COMMENT ON TABLE public.club_auction_interests IS
  'Pre-auction club interest marks from owners without a club (max 3 per owner).';

ALTER TABLE public.club_auction_interests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_auction_interests_select ON public.club_auction_interests;
CREATE POLICY club_auction_interests_select ON public.club_auction_interests
  FOR SELECT TO authenticated
  USING (true);

-- Mutations go through SECURITY DEFINER RPCs only
DROP POLICY IF EXISTS club_auction_interests_insert ON public.club_auction_interests;
DROP POLICY IF EXISTS club_auction_interests_update ON public.club_auction_interests;
DROP POLICY IF EXISTS club_auction_interests_delete ON public.club_auction_interests;

GRANT SELECT ON public.club_auction_interests TO authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_auction_interest_max()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 3;
$$;

CREATE OR REPLACE FUNCTION public.club_auction_interests_frozen_now()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_auction_bidding_open_now();
$$;

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

-- ---------------------------------------------------------------------------
-- List interests (grouped by club) + discord URL + freeze flag
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
  v_my_count int := 0;
  v_can_mark boolean;
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

  SELECT count(*)::int INTO v_my_count
  FROM public.club_auction_interests i
  JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
  WHERE i.owner_id = auth.uid()
    AND c.owner_id IS NULL
    AND c."ShortName" <> 'FOREIGN';

  RETURN jsonb_build_object(
    'ok', true,
    'frozen', v_frozen,
    'can_mark', v_can_mark,
    'max_interests', public.club_auction_interest_max(),
    'my_interest_count', coalesce(v_my_count, 0),
    'discord_chat_url', v_url,
    'interests', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'club_short_name', x.club_short_name,
          'club_name', x.club_name,
          'owners', x.owners
        )
        ORDER BY x.club_short_name
      )
      FROM (
        SELECT
          i.club_short_name,
          c."Club" AS club_name,
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
                'updated_at', i2.updated_at
              )
              ORDER BY i2.updated_at ASC, i2.id ASC
            )
            FROM public.club_auction_interests i2
            WHERE i2.club_short_name = i.club_short_name
          ), '[]'::jsonb) AS owners
        FROM public.club_auction_interests i
        JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
        WHERE c.owner_id IS NULL
          AND c."ShortName" <> 'FOREIGN'
        GROUP BY i.club_short_name, c."Club"
      ) x
    ), '[]'::jsonb),
    'mine', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'club_short_name', i.club_short_name,
          'club_name', c."Club",
          'note', nullif(btrim(coalesce(i.note, '')), ''),
          'updated_at', i.updated_at
        )
        ORDER BY i.updated_at ASC
      )
      FROM public.club_auction_interests i
      JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
      WHERE i.owner_id = auth.uid()
        AND c.owner_id IS NULL
        AND c."ShortName" <> 'FOREIGN'
    ), '[]'::jsonb)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Set / update interest
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_auction_interest_set(
  p_club_short_name text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_note text;
  v_exists boolean;
  v_count int;
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

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club short name is required';
  END IF;

  IF upper(v_club) = 'FOREIGN' THEN
    RAISE EXCEPTION 'Invalid club';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club
      AND c.owner_id IS NULL
  ) THEN
    RAISE EXCEPTION 'Club is not vacant';
  END IF;

  v_note := nullif(btrim(coalesce(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 280 THEN
    RAISE EXCEPTION 'Note must be 280 characters or fewer';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.club_auction_interests i
    WHERE i.owner_id = v_owner_id
      AND i.club_short_name = v_club
  ) INTO v_exists;

  IF NOT v_exists THEN
    SELECT count(*)::int INTO v_count
    FROM public.club_auction_interests i
    JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
    WHERE i.owner_id = v_owner_id
      AND c.owner_id IS NULL
      AND c."ShortName" <> 'FOREIGN';

    IF coalesce(v_count, 0) >= public.club_auction_interest_max() THEN
      RAISE EXCEPTION 'You can mark interest in at most % clubs',
        public.club_auction_interest_max();
    END IF;

    INSERT INTO public.club_auction_interests (owner_id, club_short_name, note)
    VALUES (v_owner_id, v_club, v_note);
  ELSE
    UPDATE public.club_auction_interests
    SET note = v_note,
        updated_at = now()
    WHERE owner_id = v_owner_id
      AND club_short_name = v_club;
  END IF;

  RETURN public.club_auction_interest_list();
END;
$function$;

-- ---------------------------------------------------------------------------
-- Clear one interest
-- ---------------------------------------------------------------------------

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

  -- Owners may clear their own marks even if they somehow lost can_mark,
  -- as long as bidding is not open.
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

-- ---------------------------------------------------------------------------
-- Admin: Discord chat URL + clear all interests
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_set_club_auction_discord_chat_url(
  p_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_url text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_url := nullif(btrim(coalesce(p_url, '')), '');
  IF v_url IS NOT NULL THEN
    IF v_url !~* '^https?://'
       OR (
         position('discord.com/' in lower(v_url)) = 0
         AND position('discord.gg/' in lower(v_url)) = 0
       ) THEN
      RAISE EXCEPTION 'URL must be an https Discord invite or channel link';
    END IF;
  END IF;

  UPDATE public.global_settings
  SET club_auction_discord_chat_url = v_url,
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object('ok', true, 'discord_chat_url', v_url);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_auction_clear_interests()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_deleted int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.club_auction_interests;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'deleted', coalesce(v_deleted, 0));
END;
$function$;

-- Extend club_auction_get_state with discord URL + freeze (keep schedule fields)
CREATE OR REPLACE FUNCTION public.club_auction_get_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs public.global_settings%rowtype;
  v_start timestamptz;
  v_finish timestamptz;
BEGIN
  SELECT * INTO v_gs FROM public.global_settings WHERE id = 1;

  -- Prefer per-type club schedule when present (draft_schedules_per_type.sql)
  v_start := coalesce(v_gs.club_auction_start_time, v_gs.draft_auction_start_time);
  v_finish := coalesce(
    v_gs.club_auction_random_finish_time,
    v_gs.draft_random_finish_time
  );

  RETURN jsonb_build_object(
    'enabled', coalesce(v_gs.club_auction_enabled, false),
    'bidding_open', public.club_auction_bidding_open_now(),
    'start_time', v_start,
    'finish_time',
      CASE
        WHEN v_finish IS NOT NULL AND now() >= v_finish THEN v_finish
        ELSE NULL
      END,
    'bid_increment', public.club_auction_bid_increment(),
    'active_listings',
      (SELECT count(*)::int
       FROM public."Club_Auction_Listings" l
       WHERE l.status = 'Active'),
    'discord_chat_url',
      nullif(btrim(coalesce(v_gs.club_auction_discord_chat_url, '')), ''),
    'interests_frozen', public.club_auction_interests_frozen_now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_auction_interest_list() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_set(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_clear(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_club_auction_discord_chat_url(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_club_auction_clear_interests() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interest_can_mark() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_auction_interests_frozen_now() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.club_auction_interest_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_set(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_clear(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_club_auction_discord_chat_url(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_auction_clear_interests() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interest_can_mark() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_interests_frozen_now() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_get_state() TO authenticated;

NOTIFY pgrst, 'reload schema';
