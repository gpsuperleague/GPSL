-- =============================================================================
-- Mid-season / waiting-list claim: copy Discord tag into Clubs.owner
--
-- Symptom: new owners linked via owner_id but tables/fixtures show no tag under
--          the club name (UI reads Clubs.owner only via clubs_lookup.js).
-- Cause: waiting_list_claim_vacant_club set owner_id and left owner NULL.
--
-- Safe re-run. Apply in Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.waiting_list_claim_vacant_club(
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '120s'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_mode text := public.gpsl_owner_intake_mode();
  v_short text := upper(btrim(coalesce(p_club_short_name, '')));
  v_status text;
  v_club text;
  v_club_name text;
  v_owner_id uuid;
  v_handpick jsonb;
  v_gate jsonb;
  v_season_id bigint;
  v_div text;
  v_tag text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_mode IS DISTINCT FROM 'mid_season' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'pre_season_use_auction',
      'mode', v_mode,
      'detail', 'Club self-pick is only available mid-season. Stay on the waiting list for the club auction.'
    );
  END IF;

  IF v_short = '' OR v_short = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_club');
  END IF;

  v_gate := public.waiting_list_vacant_clubs_for_claim();
  IF NOT coalesce((v_gate->>'can_claim')::boolean, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', coalesce(v_gate->>'reason', 'cannot_claim'),
      'mode', v_mode
    );
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  SELECT lower(btrim(ccs.division)) INTO v_div
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = v_season_id
    AND upper(ccs.club_short_name) = v_short
  LIMIT 1;

  IF v_div IS NULL OR v_div NOT IN ('superleague', 'championship_a', 'championship_b') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_in_active_division',
      'detail', 'Only vacant clubs in Super League / Championship A / Championship B can be claimed.'
    );
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid
  FOR UPDATE;

  SELECT c."ShortName", c."Club", c.owner_id
  INTO v_club, v_club_name, v_owner_id
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_short
  FOR UPDATE;

  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  IF v_owner_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_taken', 'club', v_club);
  END IF;

  IF coalesce((
    SELECT c.is_archived FROM public."Clubs" c WHERE c."ShortName" = v_club
  ), false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_archived');
  END IF;

  -- Display tag for tables/fixtures (Clubs.owner). Prefer registry Discord tag.
  v_tag := coalesce(
    (
      SELECT nullif(btrim(r.owner_tag), '')
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = v_uid
    ),
    (
      SELECT nullif(split_part(u.email::text, '@', 1), '')
      FROM auth.users u
      WHERE u.id = v_uid
    )
  );

  UPDATE public."Clubs"
  SET owner_id = NULL, owner = NULL
  WHERE owner_id = v_uid
    AND "ShortName" <> v_club;

  UPDATE public."Clubs"
  SET owner_id = v_uid,
      owner = v_tag
  WHERE "ShortName" = v_club
    AND owner_id IS NULL;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'assign_race_lost', 'club', v_club);
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, last_club_short_name, status_changed_at)
  VALUES (v_uid, 'active', v_club, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      last_club_short_name = v_club,
      status_note = NULL,
      waiting_list_tier = NULL,
      waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false,
      returned_to_list_at = NULL,
      absence_note = NULL,
      status_changed_at = now();

  IF to_regprocedure('public.waiting_list_leave_list(uuid)') IS NOT NULL THEN
    PERFORM public.waiting_list_leave_list(v_uid);
  END IF;

  PERFORM set_config('gpsl.handpick_claim', 'on', true);
  v_handpick := public.admin_club_handpick_set(v_club, true, true);

  IF coalesce((v_handpick->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'handpick_failed',
      'club', v_club,
      'club_name', v_club_name,
      'assigned', true,
      'handpick', v_handpick
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'mode', 'mid_season',
    'club', v_club,
    'club_name', v_club_name,
    'division', v_div,
    'owner_tag', v_tag,
    'handpick_intake', true,
    'redirect', 'handpick_squad.html?club=' || v_club,
    'handpick', v_handpick
  );
END;
$function$;

-- Backfill: linked clubs with empty Clubs.owner (tables show nothing today)
UPDATE public."Clubs" c
SET owner = t.tag
FROM (
  SELECT
    c2."ShortName" AS short,
    coalesce(
      nullif(btrim(r.owner_tag), ''),
      nullif(split_part(u.email::text, '@', 1), '')
    ) AS tag
  FROM public."Clubs" c2
  JOIN public.gpsl_owner_registry r ON r.owner_id = c2.owner_id
  LEFT JOIN auth.users u ON u.id = c2.owner_id
  WHERE c2.owner_id IS NOT NULL
    AND coalesce(c2.is_archived, false) = false
    AND c2."ShortName" IS DISTINCT FROM 'FOREIGN'
    AND nullif(btrim(c2.owner), '') IS NULL
) t
WHERE c."ShortName" = t.short
  AND t.tag IS NOT NULL;

-- Also sync when registry has a real tag and Clubs.owner is blank-ish or still the email local-part only
UPDATE public."Clubs" c
SET owner = nullif(btrim(r.owner_tag), '')
FROM public.gpsl_owner_registry r
WHERE c.owner_id = r.owner_id
  AND coalesce(c.is_archived, false) = false
  AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
  AND nullif(btrim(r.owner_tag), '') IS NOT NULL
  AND (
    nullif(btrim(c.owner), '') IS NULL
    OR lower(btrim(c.owner)) = lower(split_part(
         (SELECT u.email::text FROM auth.users u WHERE u.id = c.owner_id),
         '@', 1
       ))
  );

NOTIFY pgrst, 'reload schema';

-- Spot-check clubs still missing a display tag
SELECT c."ShortName", c."Club", c.owner_id, c.owner, r.owner_tag
FROM public."Clubs" c
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
WHERE c.owner_id IS NOT NULL
  AND coalesce(c.is_archived, false) = false
  AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
  AND nullif(btrim(c.owner), '') IS NULL
ORDER BY c."Club";
