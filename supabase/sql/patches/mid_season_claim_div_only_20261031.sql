-- Mid-season claim list: only vacant clubs already in a current-season division.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.waiting_list_vacant_clubs_for_claim()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_mode text := public.gpsl_owner_intake_mode();
  v_status text;
  v_has_club boolean := false;
  v_season_id bigint;
  v_season_label text;
  v_can_claim boolean := false;
  v_reason text := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'mode', v_mode);
  END IF;

  SELECT r.status INTO v_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c.owner_id = v_uid
      AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
  ) INTO v_has_club;

  IF v_has_club THEN
    v_reason := 'already_has_club';
  ELSIF v_status IS NULL OR v_status = 'archived' THEN
    v_reason := 'not_on_registry';
  ELSIF v_status = 'awaiting_club_auction' THEN
    v_reason := 'auction_invite_active';
  ELSIF NOT public.waiting_list_on_list_status(v_status) THEN
    v_reason := 'not_on_waiting_list';
  ELSIF v_mode IS DISTINCT FROM 'mid_season' THEN
    v_reason := 'pre_season_use_auction';
  ELSE
    v_can_claim := true;
  END IF;

  SELECT s.id, s.label
  INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'mode', v_mode,
    'can_claim', v_can_claim,
    'reason', v_reason,
    'registry_status', v_status,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'clubs', CASE
      WHEN v_mode IS DISTINCT FROM 'mid_season' OR v_season_id IS NULL THEN '[]'::jsonb
      ELSE coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'short_name', q.short_name,
            'club_name', q.club_name,
            'division', q.division,
            'division_label', q.division_label
          )
          ORDER BY q.div_rank, q.club_name
        )
        FROM (
          SELECT
            c."ShortName" AS short_name,
            coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
            ccs.division,
            CASE
              WHEN to_regprocedure('public.gpsl_discord_division_label(text)') IS NOT NULL
                THEN public.gpsl_discord_division_label(ccs.division)
              ELSE ccs.division
            END AS division_label,
            CASE lower(ccs.division)
              WHEN 'superleague' THEN 1
              WHEN 'championship_a' THEN 2
              WHEN 'championship_b' THEN 3
              ELSE 4
            END AS div_rank
          FROM public.competition_club_seasons ccs
          JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
          WHERE ccs.season_id = v_season_id
            AND c.owner_id IS NULL
            AND upper(c."ShortName") <> 'FOREIGN'
            AND coalesce(c.is_archived, false) = false
        ) q
      ), '[]'::jsonb)
    END
  );
END;
$function$;

-- Claim must also refuse clubs not in a current-season division
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
  v_in_division boolean := false;
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

  SELECT EXISTS (
    SELECT 1
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND upper(ccs.club_short_name) = v_short
  ) INTO v_in_division;

  IF NOT v_in_division THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_in_division',
      'detail', 'Only vacant clubs already in a league division can be claimed mid-season.'
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

  UPDATE public."Clubs"
  SET owner_id = NULL, owner = NULL
  WHERE owner_id = v_uid
    AND "ShortName" <> v_club;

  UPDATE public."Clubs"
  SET owner_id = v_uid
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
    'handpick_intake', true,
    'redirect', 'handpick_squad.html?club=' || v_club,
    'handpick', v_handpick
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
