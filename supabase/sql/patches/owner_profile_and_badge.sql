-- =============================================================================
-- Public owner profile (no email) + optional badge for in-match / profile symbol.
-- Safe to re-run.
-- =============================================================================

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS badge_path text,
  ADD COLUMN IF NOT EXISTS badge_updated_at timestamptz;

COMMENT ON COLUMN public.gpsl_owner_registry.badge_path IS
  'Storage path in owner-badges bucket (e.g. {owner_id}/badge.png). Public symbol only.';

-- Public read of safe registry fields (no email / notes)
DROP VIEW IF EXISTS public.gpsl_owner_profile_public;
CREATE VIEW public.gpsl_owner_profile_public
WITH (security_invoker = false)
AS
SELECT
  r.owner_id,
  public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
  public.competition_owner_display_name(r.owner_id) AS owner_name,
  r.status,
  r.last_club_short_name,
  c."Club" AS current_club_name,
  c."ShortName" AS current_club_short_name,
  r.last_nation_code,
  n.name AS nation_name,
  n.flag_emoji,
  r.badge_path,
  CASE
    WHEN r.badge_path IS NOT NULL AND btrim(r.badge_path) <> ''
    THEN 'owner-badges/' || btrim(r.badge_path)
    ELSE NULL
  END AS badge_storage_path,
  r.badge_updated_at
FROM public.gpsl_owner_registry r
LEFT JOIN public."Clubs" c ON c.owner_id = r.owner_id
LEFT JOIN public.international_nations n ON n.code = r.last_nation_code;

GRANT SELECT ON public.gpsl_owner_profile_public TO authenticated;
GRANT SELECT ON public.gpsl_owner_profile_public TO anon;

-- Ensure registry row exists for active club owners (badge / profile)
CREATE OR REPLACE FUNCTION public.owner_registry_ensure_self()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_tag text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  SELECT c."ShortName", nullif(btrim(c.owner), '')
  INTO v_club, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  LIMIT 1;

  INSERT INTO public.gpsl_owner_registry (
    owner_id, status, owner_tag, last_club_short_name, status_changed_at
  )
  VALUES (
    v_uid,
    CASE WHEN v_club IS NOT NULL THEN 'active' ELSE 'on_break' END,
    v_tag,
    v_club,
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE SET
    status = CASE
      WHEN v_club IS NOT NULL THEN 'active'
      ELSE public.gpsl_owner_registry.status
    END,
    owner_tag = coalesce(
      EXCLUDED.owner_tag,
      public.gpsl_owner_registry.owner_tag
    ),
    last_club_short_name = coalesce(
      EXCLUDED.last_club_short_name,
      public.gpsl_owner_registry.last_club_short_name
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_registry_set_badge_path(p_path text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_path text := nullif(btrim(p_path), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  PERFORM public.owner_registry_ensure_self();

  IF v_path IS NOT NULL AND split_part(v_path, '/', 1) <> v_uid::text THEN
    RAISE EXCEPTION 'Badge path must be under your owner folder';
  END IF;

  UPDATE public.gpsl_owner_registry
  SET badge_path = v_path,
      badge_updated_at = CASE WHEN v_path IS NULL THEN NULL ELSE now() END
  WHERE owner_id = v_uid;

  RETURN jsonb_build_object('ok', true, 'badge_path', v_path);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_ensure_self() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_registry_set_badge_path(text) TO authenticated;

-- Storage: owner badges (public read, owner writes own folder)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'owner-badges',
  'owner-badges',
  true,
  1048576,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE
SET public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS owner_badges_public_read ON storage.objects;
CREATE POLICY owner_badges_public_read ON storage.objects
  FOR SELECT TO authenticated, anon
  USING (bucket_id = 'owner-badges');

DROP POLICY IF EXISTS owner_badges_self_insert ON storage.objects;
CREATE POLICY owner_badges_self_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'owner-badges'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS owner_badges_self_update ON storage.objects;
CREATE POLICY owner_badges_self_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'owner-badges'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'owner-badges'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS owner_badges_self_delete ON storage.objects;
CREATE POLICY owner_badges_self_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'owner-badges'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------------
-- Career bundle (safe public fields only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_profile_bundle(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := p_owner_id;
  v_profile jsonb;
  v_seasons jsonb;
  v_totals jsonb;
  v_transfers jsonb;
  v_high_paid jsonb;
  v_high_recv jsonb;
  v_trophies jsonb;
  v_awards jsonb;
  v_clubs text[];
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_owner');
  END IF;

  -- Ensure active owners appear even before registry insert
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_owner_registry r WHERE r.owner_id = v_owner)
     AND EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner)
  THEN
    INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name)
    SELECT
      c.owner_id,
      'active',
      nullif(btrim(c.owner), ''),
      c."ShortName"
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner
    ON CONFLICT (owner_id) DO NOTHING;
  END IF;

  SELECT jsonb_build_object(
    'owner_id', p.owner_id,
    'owner_tag', p.owner_tag,
    'owner_name', p.owner_name,
    'status', p.status,
    'current_club_short_name', p.current_club_short_name,
    'current_club_name', p.current_club_name,
    'nation_code', p.last_nation_code,
    'nation_name', p.nation_name,
    'flag_emoji', p.flag_emoji,
    'badge_path', p.badge_path,
    'is_self', (auth.uid() IS NOT NULL AND auth.uid() = p.owner_id)
  )
  INTO v_profile
  FROM public.gpsl_owner_profile_public p
  WHERE p.owner_id = v_owner;

  IF v_profile IS NULL THEN
    -- Fallback: ranking history only
    SELECT jsonb_build_object(
      'owner_id', v_owner,
      'owner_tag', public.owner_registry_resolve_tag(v_owner),
      'owner_name', public.competition_owner_display_name(v_owner),
      'status', NULL,
      'current_club_short_name', c."ShortName",
      'current_club_name', c."Club",
      'nation_code', ion.nation_code,
      'nation_name', n.name,
      'flag_emoji', n.flag_emoji,
      'badge_path', NULL,
      'is_self', (auth.uid() IS NOT NULL AND auth.uid() = v_owner)
    )
    INTO v_profile
    FROM (SELECT v_owner AS owner_id) o
    LEFT JOIN public."Clubs" c ON c.owner_id = v_owner
    LEFT JOIN public.international_owner_nations ion
      ON ion.club_short_name = c."ShortName" AND ion.is_active = true
    LEFT JOIN public.international_nations n ON n.code = ion.nation_code;
  END IF;

  SELECT array_agg(DISTINCT r.club_short_name)
  INTO v_clubs
  FROM public.competition_owner_season_ranking r
  WHERE r.owner_id = v_owner;

  IF v_clubs IS NULL THEN
    SELECT array_agg(c."ShortName")
    INTO v_clubs
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.season_id DESC), '[]'::jsonb)
  INTO v_seasons
  FROM (
    SELECT
      h.season_id,
      h.season_label,
      h.club_short_name,
      h.club_name,
      h.division,
      h.final_position,
      h.mp,
      h.won,
      h.drawn,
      h.lost,
      h.gf,
      h.ga,
      h.gd,
      h.pts,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(100.0 * h.won::numeric / h.mp::numeric, 1)
        ELSE NULL
      END AS win_pct
    FROM public.competition_club_season_history_public h
    JOIN public.competition_owner_season_ranking r
      ON r.season_id = h.season_id
     AND r.club_short_name = h.club_short_name
     AND r.owner_id = v_owner
  ) s;

  SELECT jsonb_build_object(
    'seasons', coalesce(count(*), 0),
    'mp', coalesce(sum(mp), 0),
    'won', coalesce(sum(won), 0),
    'drawn', coalesce(sum(drawn), 0),
    'lost', coalesce(sum(lost), 0),
    'gf', coalesce(sum(gf), 0),
    'ga', coalesce(sum(ga), 0),
    'gd', coalesce(sum(gd), 0),
    'pts', coalesce(sum(pts), 0),
    'win_pct', CASE
      WHEN coalesce(sum(mp), 0) > 0
      THEN round(100.0 * sum(won)::numeric / sum(mp)::numeric, 1)
      ELSE NULL
    END
  )
  INTO v_totals
  FROM (
    SELECT h.mp, h.won, h.drawn, h.lost, h.gf, h.ga, h.gd, h.pts
    FROM public.competition_club_season_history_public h
    JOIN public.competition_owner_season_ranking r
      ON r.season_id = h.season_id
     AND r.club_short_name = h.club_short_name
     AND r.owner_id = v_owner
  ) x;

  SELECT jsonb_build_object(
    'spent', coalesce(sum(CASE WHEN th.buyer_club_id = ANY (v_clubs) THEN coalesce(th.fee, 0) + coalesce(th.agent_fee, 0) ELSE 0 END), 0),
    'received', coalesce(sum(CASE WHEN th.seller_club_id = ANY (v_clubs) THEN coalesce(th.fee, 0) ELSE 0 END), 0)
  )
  INTO v_transfers
  FROM public."Transfer_History" th
  WHERE v_clubs IS NOT NULL
    AND (th.buyer_club_id = ANY (v_clubs) OR th.seller_club_id = ANY (v_clubs));

  SELECT jsonb_build_object(
    'fee', th.fee,
    'agent_fee', th.agent_fee,
    'player_id', th.player_id,
    'player_name', p."Name",
    'club_short_name', th.buyer_club_id,
    'seller_club_id', th.seller_club_id,
    'transfer_time', th.transfer_time,
    'season_label', public.transfer_history_season_label(th.transfer_time)
  )
  INTO v_high_paid
  FROM public."Transfer_History" th
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id::text
  WHERE v_clubs IS NOT NULL
    AND th.buyer_club_id = ANY (v_clubs)
    AND coalesce(th.fee, 0) > 0
  ORDER BY th.fee DESC, th.transfer_time DESC NULLS LAST
  LIMIT 1;

  SELECT jsonb_build_object(
    'fee', th.fee,
    'player_id', th.player_id,
    'player_name', p."Name",
    'club_short_name', th.seller_club_id,
    'buyer_club_id', th.buyer_club_id,
    'foreign_buyer_name', th.foreign_buyer_name,
    'transfer_time', th.transfer_time,
    'season_label', public.transfer_history_season_label(th.transfer_time)
  )
  INTO v_high_recv
  FROM public."Transfer_History" th
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id::text
  WHERE v_clubs IS NOT NULL
    AND th.seller_club_id = ANY (v_clubs)
    AND coalesce(th.fee, 0) > 0
  ORDER BY th.fee DESC, th.transfer_time DESC NULLS LAST
  LIMIT 1;

  SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.season_id DESC, h.honour_label), '[]'::jsonb)
  INTO v_trophies
  FROM public.competition_club_honours_public h
  JOIN public.competition_owner_season_ranking r
    ON r.season_id = h.season_id
   AND r.club_short_name = h.club_short_name
   AND r.owner_id = v_owner;

  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.season_id DESC, a.award_type), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  JOIN public.competition_owner_season_ranking r
    ON r.season_id = a.season_id
   AND r.club_short_name = a.club_short_name
   AND r.owner_id = v_owner
  WHERE a.award_type IN (
    'ballon_dor',
    'golden_boot',
    'golden_playmaker',
    'golden_glove',
    'season_potm',
    'championship_player_of_season',
    'team_of_season'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'profile', v_profile,
    'career_totals', v_totals,
    'seasons', v_seasons,
    'transfers', v_transfers,
    'highest_fee_paid', v_high_paid,
    'highest_fee_received', v_high_recv,
    'trophies', v_trophies,
    'awards', v_awards
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO anon;

NOTIFY pgrst, 'reload schema';
